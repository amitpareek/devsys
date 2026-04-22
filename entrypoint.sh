#!/usr/bin/env bash
# devsys entrypoint — seeds the volume on first boot, then brings up
# tailscale (auto-joins with TS_AUTHKEY if not already connected) and redis.
# Runs tailscaled in the foreground as PID 1 so Docker's lifecycle tracks it.
set -euo pipefail

USERNAME="${USERNAME:-dev}"
HOME_DIR="/home/${USERNAME}"
SKEL_DIR="/etc/skel/devsys"
SEED_MARK="${HOME_DIR}/.devsys-seeded"

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] FATAL: $*" >&2; exit 1; }

# ---- 0. Required env -------------------------------------------------------
[ -n "${HOSTNAME:-}"   ] || die "HOSTNAME env var is required (e.g. -e HOSTNAME=my-box)"
[ -n "${TS_AUTHKEY:-}" ] || die "TS_AUTHKEY env var is required (tskey-auth-...)"

# ---- 1. Seed /home/dev on first boot --------------------------------------
# If the volume is empty or has never been seeded, copy the baked-in home
# (runtimes, AI CLIs, zsh config, work/ dir, vault/ dir, etc.) into place.
if [ ! -e "$SEED_MARK" ]; then
  log "first boot — seeding ${HOME_DIR} from ${SKEL_DIR}"
  # -a preserves ownership/perms; --ignore-existing so user files on the
  # volume (if any) win over skel defaults.
  rsync -a --ignore-existing "${SKEL_DIR}/" "${HOME_DIR}/"
  chown -R "${USERNAME}:${USERNAME}" "${HOME_DIR}"
  touch "${SEED_MARK}"
  chown "${USERNAME}:${USERNAME}" "${SEED_MARK}"
fi

# Persistent state dirs on the volume
TS_STATE_DIR="${HOME_DIR}/.local/state/tailscale"
REDIS_DIR="${HOME_DIR}/.local/state/redis"
mkdir -p "$TS_STATE_DIR" "$REDIS_DIR" /var/run/tailscale
chown -R "${USERNAME}:${USERNAME}" "${HOME_DIR}/.local" 2>/dev/null || true

# ---- 2. Redis (background, bound to loopback) -----------------------------
if command -v redis-server >/dev/null 2>&1; then
  if ! pgrep -x redis-server >/dev/null 2>&1; then
    log "starting redis-server (127.0.0.1:6379, dir=${REDIS_DIR})"
    chown redis:redis "$REDIS_DIR" 2>/dev/null || true
    redis-server \
      --bind 127.0.0.1 \
      --port 6379 \
      --daemonize yes \
      --dir "$REDIS_DIR" \
      --logfile "" \
      --save "3600 1 300 100 60 10000" || log "redis failed to start (continuing)"
  fi
fi

# ---- 3. Resolve + apply hostname ------------------------------------------
# Single source of truth: the HOSTNAME env var (falls back to whatever docker
# set via --hostname, else the container ID). We apply it to the kernel so
# `hostname` inside the shell matches, and re-use it for tailscale.
HOST="${HOSTNAME:-$(hostname)}"
if [ -n "${HOSTNAME:-}" ] && [ "$(hostname)" != "$HOSTNAME" ]; then
  hostname "$HOSTNAME" 2>/dev/null || true
  echo "$HOSTNAME" > /etc/hostname 2>/dev/null || true
fi
log "hostname: ${HOST}"

# ---- 4. Bring up tailscale -------------------------------------------------
# Strategy: background tailscaled, wait for socket, then `tailscale up` if
# we aren't already connected.  TS_AUTHKEY makes it headless; without one,
# we fall back to printing a login URL.

/usr/sbin/tailscaled \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket=/var/run/tailscale/tailscaled.sock \
  --tun=userspace-networking \
  >/var/log/tailscaled.log 2>&1 &
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
# Trap so signals cleanly stop tailscaled.
trap 'log "stopping..."; kill -TERM "$TAILSCALED_PID" 2>/dev/null || true; wait "$TAILSCALED_PID" 2>/dev/null || true; exit 0' TERM INT

log "ready — use 'tailscale ssh ${USERNAME}@${HOST}' or 'docker exec -it <c> zsh'"
wait "$TAILSCALED_PID"
