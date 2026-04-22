#!/usr/bin/env bash
# devsys entrypoint — gets tailscale up FAST (in parallel with the seed
# rsync), so the machine is reachable within ~10–30 s on first boot
# instead of waiting for the ~1.9 GB home snapshot to copy.
set -euo pipefail

HOME_DIR="/root"
SKEL_DIR="/etc/skel/devsys"
SEED_MARK="${HOME_DIR}/.devsys-seeded"

log() { echo "[entrypoint] $*"; }
die() { echo "[entrypoint] FATAL: $*" >&2; exit 1; }

# ---- 0. Required env -------------------------------------------------------
[ -n "${HOSTNAME:-}"   ] || die "HOSTNAME env var is required (e.g. -e HOSTNAME=my-box)"
[ -n "${TS_AUTHKEY:-}" ] || die "TS_AUTHKEY env var is required (tskey-auth-...)"

# ---- 1. Ensure state dirs exist BEFORE tailscaled / redis -----------------
# These aren't in the skel snapshot (they're created fresh per-deploy),
# so we don't need to wait for the rsync.
TS_STATE_DIR="${HOME_DIR}/.local/state/tailscale"
REDIS_DIR="${HOME_DIR}/.local/state/redis"
mkdir -p "$TS_STATE_DIR" "$REDIS_DIR" /var/run/tailscale

# ---- 2. Kick the seed / top-up off in the background ---------------------
# Runs in parallel with tailscale bring-up and redis. --ignore-existing
# means user files on the volume always win. On first boot this is a
# full ~1.9 GB copy and takes a few minutes on shared CPUs; on later
# boots it's just a metadata walk and finishes in seconds. Tools that
# haven't been seeded yet will surface as "command not found" until the
# background job finishes — watch for the "seed complete" log line.
(
  if [ ! -e "$SEED_MARK" ]; then
    log "seed: first boot — copying ${SKEL_DIR} -> ${HOME_DIR} (this can take a few minutes)"
  else
    log "seed: topping up ${HOME_DIR} from ${SKEL_DIR} (new files only)"
  fi
  if rsync -a --ignore-existing "${SKEL_DIR}/" "${HOME_DIR}/"; then
    [ -e "$SEED_MARK" ] || touch "${SEED_MARK}"
    log "seed: complete — all tools are available now"
  else
    log "seed: rsync FAILED (continuing — some tools may be missing)"
  fi
) &
SEED_PID=$!

# ---- 3. Redis (background, bound to loopback) -----------------------------
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

# ---- 4. Apply hostname ----------------------------------------------------
HOST="$HOSTNAME"
if [ "$(hostname)" != "$HOSTNAME" ]; then
  hostname "$HOSTNAME" 2>/dev/null || true
  echo "$HOSTNAME" > /etc/hostname 2>/dev/null || true
fi
log "hostname: ${HOST}"

# ---- 5. Bring up tailscale -------------------------------------------------
# Starts alongside the seed so we're reachable within seconds.
# Tailscaled's output goes to the entrypoint's stdout/stderr so
# 'docker logs' / 'fly logs' captures it.
/usr/sbin/tailscaled \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket=/var/run/tailscale/tailscaled.sock \
  --tun=userspace-networking \
  --verbose=1 &
TAILSCALED_PID=$!

# Wait for socket (max ~10 s).
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

log "ready — tailnet reachable as 'tailscale ssh root@${HOST}'. Seed PID: ${SEED_PID}"

# ---- 6. Hand off: tailscaled is the long-running process ------------------
trap 'log "stopping..."; kill -TERM "$TAILSCALED_PID" "$SEED_PID" 2>/dev/null || true; wait 2>/dev/null || true; exit 0' TERM INT

wait "$TAILSCALED_PID"
