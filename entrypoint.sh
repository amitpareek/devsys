#!/usr/bin/env bash
# devsys entrypoint — tops up /root from the baked snapshot on every boot,
# then brings up redis and tailscale. Runs tailscaled as PID 1 so Docker
# tracks its lifecycle.
set -euo pipefail

HOME_DIR="/root"
SKEL_DIR="/etc/skel/devsys"
SEED_MARK="${HOME_DIR}/.devsys-seeded"

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] FATAL: $*" >&2; exit 1; }

# ---- 0. Required env -------------------------------------------------------
[ -n "${HOSTNAME:-}"   ] || die "HOSTNAME env var is required (e.g. -e HOSTNAME=my-box)"
[ -n "${TS_AUTHKEY:-}" ] || die "TS_AUTHKEY env var is required (tskey-auth-...)"

# ---- 1. Top up /root from the baked-in snapshot ---------------------------
# Runs every boot. --ignore-existing means files you've edited on the
# volume always win; new tools added in a future image release show up
# automatically. First boot is logged separately because it's the
# expensive one (full ~1.9 GB copy); subsequent boots are near-instant.
if [ ! -e "$SEED_MARK" ]; then
  log "first boot — seeding ${HOME_DIR} from ${SKEL_DIR}"
else
  log "topping up ${HOME_DIR} from ${SKEL_DIR} (new files only)"
fi
rsync -a --ignore-existing "${SKEL_DIR}/" "${HOME_DIR}/"
[ -e "$SEED_MARK" ] || touch "${SEED_MARK}"

# Persistent state dirs on the volume
TS_STATE_DIR="${HOME_DIR}/.local/state/tailscale"
REDIS_DIR="${HOME_DIR}/.local/state/redis"
mkdir -p "$TS_STATE_DIR" "$REDIS_DIR" /var/run/tailscale

# ---- 2. Redis (background, bound to loopback) -----------------------------
if command -v redis-server >/dev/null 2>&1; then
  if ! pgrep -x redis-server >/dev/null 2>&1; then
    log "starting redis-server (127.0.0.1:6379, dir=${REDIS_DIR})"
    redis-server \
      --bind 127.0.0.1 \
      --port 6379 \
      --daemonize yes \
      --dir "$REDIS_DIR" \
      --logfile "" \
      --save "3600 1 300 100 60 10000" || log "redis failed to start (continuing)"
  fi
fi

# ---- 3. Apply hostname ----------------------------------------------------
# HOSTNAME env is the source of truth. Apply to the kernel so `hostname`
# matches and re-use for tailscale.
HOST="$HOSTNAME"
if [ "$(hostname)" != "$HOSTNAME" ]; then
  hostname "$HOSTNAME" 2>/dev/null || true
  echo "$HOSTNAME" > /etc/hostname 2>/dev/null || true
fi
log "hostname: ${HOST}"

# ---- 4. Bring up tailscale -------------------------------------------------
# Tailscaled's stdout/stderr goes to the entrypoint's stdout/stderr so
# 'docker logs' / 'fly logs' captures it. Previously redirected to a
# file, which hid failures from the operator.
/usr/sbin/tailscaled \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket=/var/run/tailscale/tailscaled.sock \
  --tun=userspace-networking \
  --verbose=1 &
TAILSCALED_PID=$!

# Wait for socket (max ~10s)
for _ in $(seq 1 50); do
  [ -S /var/run/tailscale/tailscaled.sock ] && break
  sleep 0.2
done

if tailscale status --peers=false >/dev/null 2>&1; then
  log "tailscale already authenticated — updating hostname/ssh"
  tailscale set --hostname="${HOST}" --ssh=true || true
else
  log "running 'tailscale up' with TS_AUTHKEY"
  tailscale up \
    --authkey="${TS_AUTHKEY}" \
    --hostname="${HOST}" \
    --ssh=true \
    --accept-dns=true \
    --accept-routes=true || die "tailscale up failed"
fi

# ---- 5. Hand off: keep tailscaled as the long-running process -------------
trap 'log "stopping..."; kill -TERM "$TAILSCALED_PID" 2>/dev/null || true; wait "$TAILSCALED_PID" 2>/dev/null || true; exit 0' TERM INT

log "ready — use 'tailscale ssh root@${HOST}' or 'docker exec -it <c> zsh'"
wait "$TAILSCALED_PID"
