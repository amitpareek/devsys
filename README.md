# devsys — all-inclusive Ubuntu dev container on Tailscale

One image. Every dev tool baked in. Joins your tailnet on boot. One volume
holds all persistent state.

**Image:** `ghcr.io/amitpareek/devsys:latest` (linux/amd64 + linux/arm64)

## Required environment variables

Every deployment (local Docker, Compose, Fly.io, any VPS) needs exactly
these two. The container refuses to start without them.

| Env var | What it is | How to get it |
|---|---|---|
| `HOSTNAME` | System hostname **and** tailnet hostname (they're always the same). | Pick any DNS-safe name, e.g. `my-devbox`. |
| `TS_AUTHKEY` | Tailscale auth key so the container can headlessly join your tailnet on first boot. | Generate at https://login.tailscale.com/admin/settings/keys — mark **Reusable** so restarts don't need a new key. |

The only other thing you need is a **persistent volume** mounted at
`/home/dev` inside the container (everything — tailscale state, shell
history, AI auth, redis data, your `~/work`/`~/vault` — lives there).

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

Every tool listed below is pre-installed in the image. No first-boot
`setup.sh`, no picking and choosing — everything is available the moment
you shell in.

### Runtimes (managed by `mise`)
| Tool | Binary | Source |
|---|---|---|
| Node.js LTS | `node`, `npm`, `npx` | mise → official Node builds |
| Python 3.12 | `python3`, `pip3` | mise → python-build-standalone |
| Bun | `bun`, `bunx` | `bun.sh/install` |
| pnpm | `pnpm` | `npm install -g pnpm` |

### CLIs
| Tool | Binary | Notes |
|---|---|---|
| GitHub CLI | `gh` | apt `cli.github.com` |
| Fly.io | `flyctl`, `fly` | `fly.io/install.sh` → `/opt/fly` |
| Neon | `neonctl` | npm global |
| Claude Code | `claude` | npm `@anthropic-ai/claude-code`, aliased to `claude --dangerously-skip-permissions` |
| Gemini CLI | `gemini` | npm `@google/gemini-cli` |
| Codex CLI | `codex` | npm `@openai/codex` |
| opencode | `opencode` | npm `opencode-ai` |
| obsidian-headless | `ob` | npm `obsidian-headless` — Obsidian's official headless Sync client |
| PostgreSQL client | `psql`, `pg_dump`, `pg_restore`, `pg_isready` | apt `postgresql-client` |

### Services (auto-start on container boot)
| Service | Port | Data dir |
|---|---|---|
| Redis | `127.0.0.1:6379` | `~/.local/state/redis` |
| Tailscale (`tailscaled`) | — (userspace-networking) | `~/.local/state/tailscale` |

### Shell & modern CLI bundle
| Category | Binaries |
|---|---|
| Shell | `zsh`, `bash` |
| Prompt | `starship` |
| Modern unix | `eza` (`ls`, `ll`, `tree` aliases), `bat` (`cat` alias), `fd`, `rg` (ripgrep), `fzf` |
| Monitoring | `htop`, `ncdu` |
| Misc | `jq`, `direnv`, `tmux`, `lazygit` (alias `lg`), `glow` |
| Net / dev | `git`, `curl`, `wget`, `sudo`, `openssh-client`, `iputils-ping`, `dnsutils`, `net-tools`, `rsync`, `unzip`, `build-essential`, `pkg-config` |

### Tailnet
- `tailscale`, `tailscaled` — `--ssh` enabled on first boot, userspace-networking (no `NET_ADMIN` capability needed).

All npm-installed CLIs live at `~/.npm-global/bin/`, which is on PATH by
default. mise shims are in `~/.local/share/mise/shims/`.

## Obsidian (headless)

`obsidian-headless` (binary: `ob`) is the official CLI client for Obsidian
Sync. It works without a GUI/display server, unlike the desktop CLI that
ships in the Obsidian installer.

Typical sync flow:
```bash
ob login                          # paste Obsidian Sync credentials
ob sync-list-remote               # show vaults on your account
ob sync-setup --help              # see how to point a local path at a remote vault
ob sync --help                    # run a sync (one-shot or continuous)
ob sync-status                    # check sync state of a local vault
```

Publish flow (for Obsidian Publish):
```bash
ob publish-list-sites
ob publish-setup --help
ob publish
```

All subcommands: `login`, `logout`, `sync-list-remote`, `sync-list-local`,
`sync-create-remote`, `sync-setup`, `sync-config`, `sync-status`,
`sync-unlink`, `sync`, `publish-list-sites`, `publish-create-site`,
`publish-setup`, `publish`, `publish-config`, `publish-site-options`,
`publish-unlink`. Run `ob <cmd> --help` for options on any of them.

Requires an Obsidian Sync subscription — sync is a paid add-on, not part
of the free tier.

## Persistence

One volume at `/home/dev` holds everything: shell history, tailscale state,
AI tool auth, redis data, npm/pnpm/bun caches, your `~/work` files.

On every boot the entrypoint tops up this volume from a snapshot baked
into the image at `/etc/skel/devsys` using `rsync --ignore-existing`.
First boot performs the full ~1.9 GB copy; subsequent boots are near-
instant and add only new files from a freshly-pulled image. Files you
edit on the volume are never overwritten.

Nuking the volume resets the box:
```bash
docker stop "$HOST" && docker rm "$HOST"
docker volume rm devsys-home
```

## Cloud deployments

The whole model is "pull image, set two env vars, mount one volume". Works
on any Docker-capable host — Fly.io machines, Railway, a plain VPS, OrbStack
locally, etc. No build, no config files.

Templates:
- **Compose** (local / VPS): [docker-compose.example.yml](./docker-compose.example.yml)
- **Fly.io** (one always-on machine + volume, tailnet-only access): [fly.toml](./fly.toml)

**Fastest Fly path** — the interactive script handles app / volume /
secret / deploy in one go:
```bash
./flysetup.sh
```
It asks for app name, region, volume size, and your `TS_AUTHKEY`, patches
fly.toml, and runs `fly apps create`, `fly volumes create`, `fly secrets
set`, `fly deploy` in sequence. Safe to re-run — each step checks for
existing state.

Manual path: edit the `app` + `HOSTNAME` fields in [fly.toml](./fly.toml),
`fly volumes create devsys_home --size 10`, `fly secrets set
TS_AUTHKEY=...`, then `fly deploy`. The Machine never publishes a port —
all access is through `tailscale ssh`.

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
- Fly.io deployment: see [fly.toml](./fly.toml) for a one-machine
  always-on setup reachable only over your tailnet.
