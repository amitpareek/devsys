# devsys — all-inclusive Ubuntu dev container on Tailscale

One image. Every dev tool baked in. Joins your tailnet on boot. One volume
holds all persistent state.

**Image:** `ghcr.io/amitpareek/devsys:latest` (linux/amd64 + linux/arm64)

## Quick start

### 1. Get a Tailscale auth key

https://login.tailscale.com/admin/settings/keys → **Generate auth key** →
mark **Reusable** (so container restarts don't need a new key) → copy the
`tskey-auth-…` string.

If you want to tag the node (recommended for shared tailnets), attach a tag
to the auth key when generating — e.g. `tag:devsys`.

### 2. Configure the tailnet policy

Edit https://login.tailscale.com/admin/acls/file.

**Without tags** — simplest, node is owned by you:
```json
"ssh": [
  {
    "action": "accept",
    "src":    ["autogroup:member"],
    "dst":    ["autogroup:self"],
    "users":  ["autogroup:nonroot", "root"]
  }
]
```

**With tags** — required if your auth key applies a tag (tagged nodes
have no user-owner, so `autogroup:self` never matches):
```json
"tagOwners": {
  "tag:devsys": ["autogroup:admin"]
},
"ssh": [
  {
    "action": "accept",
    "src":    ["autogroup:member"],
    "dst":    ["tag:devsys"],
    "users":  ["autogroup:nonroot", "root"]
  }
]
```

Save the policy. A JSON error elsewhere in the file silently reverts the
save — watch for the green "Saved" banner.

### 3. Run the container

```bash
export TS_AUTHKEY=tskey-auth-xxxxxxxx
export HOST=my-devbox                # whatever you want on the tailnet

docker run -d --restart=unless-stopped \
  --name "$HOST" \
  -e HOSTNAME="$HOST" \
  -e TS_AUTHKEY="$TS_AUTHKEY" \
  -v devsys-home:/home/dev \
  ghcr.io/amitpareek/devsys:latest
```

Container refuses to start if either env var is missing.

### 4. Shell in

```bash
docker exec -it "$HOST" zsh          # always works, lands in ~/work
tailscale ssh dev@"$HOST"            # from any tailnet device, once joined
```

### Optional — Obsidian vault

Bind-mount a host vault at `~/vault` inside the container:
```bash
docker run ... -v ~/Documents/MyVault:/home/dev/vault ...
```

## What's included

**Runtimes** Node LTS + Python 3.12 (via mise), Bun, pnpm
**CLIs** gh, flyctl, neonctl, Claude Code, Gemini CLI, Codex CLI, opencode
**Services** Redis (auto-starts on 127.0.0.1:6379)
**Shell** zsh, starship, direnv, tmux, lazygit (`lg`), eza, bat, fd, rg, fzf, htop, ncdu, jq
**Tailnet** tailscale + tailscaled (userspace-networking, `--ssh` enabled)

The Claude alias has `--dangerously-skip-permissions` baked in since the
container is isolated from the host.

## Persistence

One volume at `/home/dev` holds everything: shell history, tailscale state,
AI tool auth, redis data, npm/pnpm/bun caches, your `~/work` files.

On first boot the entrypoint seeds this volume from a snapshot baked into
the image at `/etc/skel/devsys`. Subsequent boots see the sentinel file
`~/.devsys-seeded` and skip the seed.

Nuking the volume resets the box:
```bash
docker stop "$HOST" && docker rm "$HOST"
docker volume rm devsys-home
```

## Cloud deployments

The whole model is "pull image, set two env vars, mount one volume". Works
on any Docker-capable host — Fly.io machines, Railway, a plain VPS, OrbStack
locally, etc. No build, no config files.

Compose template: [docker-compose.example.yml](./docker-compose.example.yml).

## Building / publishing

`.github/workflows/docker.yml` builds multi-arch (amd64 + arm64) and pushes
to `ghcr.io/amitpareek/devsys` on every push to `main` and on `v*` tags.

Local build for your host arch:
```bash
docker build -t devsys:local .
```

## Troubleshooting

**`tailnet policy does not permit you to SSH to this node`** — the tailnet
ACL doesn't have an SSH rule matching this node. See step 2 above. Tag
mismatch is the usual cause.

**`FATAL: HOSTNAME env var is required`** — you didn't pass `-e HOSTNAME=...`.

**`FATAL: TS_AUTHKEY env var is required`** — you didn't pass
`-e TS_AUTHKEY=...`. Key must be valid and not expired.

**Container exits after `tailscale up failed`** — check the key isn't
consumed (single-use keys can only be used once) or revoked.

**`tailscale status` shows the node as `tagged-devices`** — your auth key
applies a tag but `tagOwners` doesn't declare it, or your SSH rule still
uses `autogroup:self`. See "With tags" above.

## Notes

- **MagicDNS**: enable at https://login.tailscale.com/admin/dns so bare
  `my-devbox` resolves without the full `.tailXXXX.ts.net` suffix.
- **Mac sleep**: a container on your Mac is unreachable while the Mac
  sleeps. Disable: `sudo pmset -a sleep 0 disablesleep 1`.
- **Redis isolation**: per-container, bound to 127.0.0.1 — not visible on
  the tailnet.
- Legacy files kept for reference: [Dockerfile.old](./Dockerfile.old),
  [entrypoint.old.sh](./entrypoint.old.sh), [setup.sh](./setup.sh),
  [build.sh](./build.sh), [customer-a.docker-compose.yml](./customer-a.docker-compose.yml),
  [customer-b.docker-compose.yml](./customer-b.docker-compose.yml).
