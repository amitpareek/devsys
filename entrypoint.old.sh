#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------------------------------
# devsys-base entrypoint
#
# Starts tailscaled so the daemon is available when setup.sh runs
# 'tailscale up' later. If the container has been set up before (sentinel
# exists) and tailscale state is present, tailscaled picks up the session
# automatically — no re-auth needed.
#
# Access the container for the first time via OrbStack UI or docker exec,
# then run: setup.sh
# ----------------------------------------------------------------------------

mkdir -p /var/lib/tailscale /var/run/tailscale

# If a previous run installed redis and it's selected in state, start it.
# We keep this check minimal; setup.sh is the source of truth for "what's
# installed". The intent here is: don't require a manual redis-server call
# after every container restart.
STATE=/var/lib/devsys-setup/state.json
if command -v redis-server >/dev/null 2>&1 \
   && [ -f "$STATE" ] \
   && grep -q '"redis": *true' "$STATE" 2>/dev/null; then
  echo "[entrypoint] starting redis-server (from state)..."
  mkdir -p /var/lib/redis /var/log/redis
  chown redis:redis /var/lib/redis /var/log/redis 2>/dev/null || true
  redis-server \
    --bind 127.0.0.1 \
    --port 6379 \
    --daemonize yes \
    --dir /var/lib/redis \
    --logfile /var/log/redis/redis.log \
    --save "3600 1 300 100 60 10000" || echo "[entrypoint] redis failed to start"
fi

# Start tailscaled in foreground as PID 1 so Docker's lifecycle is
# tied to it and signals route cleanly. setup.sh runs `tailscale up`
# against this daemon via the Unix socket.
echo "[entrypoint] starting tailscaled (foreground, PID 1)..."
exec /usr/sbin/tailscaled \
  --state=/var/lib/tailscale/tailscaled.state \
  --socket=/var/run/tailscale/tailscaled.sock \
  --tun=userspace-networking
