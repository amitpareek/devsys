# devsys — all-inclusive Ubuntu dev container on Tailscale

One image. Every dev tool baked in. Joins your tailnet on boot. One volume
holds all persistent state.

**Image:** `ghcr.io/amitpareek/devsys:latest` (linux/amd64 + linux/arm64)

## Quick install

```bash
export TS_AUTHKEY=tskey-auth-xxxxxxxx   # https://login.tailscale.com/admin/settings/keys (mark Reusable)
export HOST=my-devbox                   # any DNS-safe name; becomes the tailnet hostname
export WORK=~/Work                      # host folder to share into ~/work (edit in your IDE, run in the box)

docker run -d --restart=unless-stopped \
  --name "$HOST" \
  -e HOSTNAME="$HOST" \
  -e TS_AUTHKEY="$TS_AUTHKEY" \
  -v devsys-home:/root \
  -v "$WORK":/root/work \
  ghcr.io/amitpareek/devsys:latest

docker exec -it "$HOST" zsh             # shell in — lands in ~/work
```

First boot also needs a one-time tailnet ACL tweak so SSH works — see [Quick start → step 2](#2-configure-the-tailnet-policy).

### Instant global access

Once the container is up on your tailnet, from any tailnet device:

```bash
ssh root@<hostname>     # e.g. ssh root@my-devbox — drops straight into ~/work
```

Same hostname works in **Cursor** or **VS Code** — `Remote-SSH: Connect to Host…` → `root@<hostname>` opens the full IDE against the container (extensions, terminal, debugger, everything).

No keys, no port forwards, no VPN dance. **Only works from devices on your tailnet** — the box never exposes a public port. Disable key expiry for the node at https://login.tailscale.com/admin/machines (⋯ → "Disable key expiry") so it doesn't fall off the tailnet every 180 days.

> **Tip — skip expiry entirely with a tag.** A tagged auth key (or tagged machine) never expires. **Prefer tagging the key** when you generate it (e.g. `tag:devsys`) so every container that boots with that key inherits the tag and non-expiring status. If tailnet SSH breaks after adding a tag, the ACL likely doesn't declare the tag owner or still uses `autogroup:self` — see the **With tags** block in [Quick start → step 2](#2-configure-the-tailnet-policy).

---

**Contents:** [Required env](#required-environment-variables) · [Quick start](#quick-start) · [What's included](#whats-included) · [Obsidian](#obsidian-notes) · [.NET SDK](#optional--net-sdk) · [Persistence](#persistence) · [Cloud deployments](#cloud-deployments) · [Building](#building--publishing) · [Upgrading](#upgrading-from-an-older-image) · [Troubleshooting](#troubleshooting) · [Notes](#notes)

---

## Required environment variables

Every deployment (local Docker, Compose, Fly.io, any VPS) needs exactly
these two. The container refuses to start without them.

| Env var | What it is | How to get it |
|---|---|---|
| `HOSTNAME` | System hostname **and** tailnet hostname (they're always the same). | Pick any DNS-safe name, e.g. `my-devbox`. |
| `TS_AUTHKEY` | Tailscale auth key so the container can headlessly join your tailnet on first boot. | Generate at https://login.tailscale.com/admin/settings/keys — mark **Reusable** so restarts don't need a new key. |

The only other thing you need is a **persistent volume** mounted at
`/root` inside the container (everything — tailscale state, shell
history, AI auth, redis data, your `~/work` — lives there).

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
    "users":  ["root"]
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
    "users":  ["root"]
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
  -v devsys-home:/root \
  ghcr.io/amitpareek/devsys:latest
```

Container refuses to start if either env var is missing.

### 4. Shell in

```bash
docker exec -it "$HOST" zsh          # always works, lands in ~/work
tailscale ssh root@"$HOST"           # from any tailnet device, once joined
fly ssh console -a <fly-app>         # on Fly — opens a root shell in ~/work
```

All three drop you into the same environment: root shell, zsh with
starship/aliases, cwd = `~/work`. There's only one user (root) inside
the container, so the different access paths don't drift.

### Optional — bind-mount a project for IDE editing

Mount any host folder inside `~/work` so a Mac IDE can edit it while
the container runs it:
```bash
docker run ... -v ~/Work/myproject:/root/work/myproject ...
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
| Claude Code | `claude` | npm `@anthropic-ai/claude-code`. Pre-configured `~/.claude/settings.json` with exhaustive allow-list (no `--dangerously-skip-permissions` — that flag refuses as root). |
| Gemini CLI | `gemini` | npm `@google/gemini-cli`. Aliased to `gemini --yolo` (auto-approve all) + `~/.gemini/settings.json` sets `auto_edit` fallback. |
| Codex CLI | `codex` | npm `@openai/codex`. Aliased to `codex --dangerously-bypass-approvals-and-sandbox` + `~/.codex/config.toml` sets `approval_policy=never` + `sandbox_mode=danger-full-access`. |
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
| Net / dev | `git`, `curl`, `wget`, `openssh-client`, `iputils-ping`, `dnsutils`, `net-tools`, `rsync`, `unzip`, `build-essential`, `pkg-config` |

### Tailnet
- `tailscale`, `tailscaled` — `--ssh` enabled on first boot, userspace-networking (no `NET_ADMIN` capability needed).

All npm-installed CLIs live at `~/.npm-global/bin/`, which is on PATH by
default. mise shims are in `~/.local/share/mise/shims/`.

## Obsidian notes

The `ob` binary (from `obsidian-headless`) is pre-installed. Use it if
you want to sync notes with Obsidian Sync (paid add-on), or just `git
clone` a notes repo into `~/work` and manage it however you like — the
container doesn't care where your notes live.

Docs: https://github.com/obsidianmd/obsidian-headless  ·  `ob --help`

## Optional — .NET SDK

Not baked into the image (saves ~700 MB for everyone who doesn't need
it). When you want it, run this **inside the container** (as root).
Installs to `~/.dotnet`, works on amd64 + arm64.

```bash
# LTS (.NET 8 — support through Nov 2026)
curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel LTS

# or latest stable (.NET 9)
curl -fsSL https://dot.net/v1/dotnet-install.sh | bash -s -- --channel STS

# expose dotnet on PATH permanently
cat >> ~/.zshenv <<'EOF'
export DOTNET_ROOT="$HOME/.dotnet"
path=("$DOTNET_ROOT" "$DOTNET_ROOT/tools" $path)
EOF
exec zsh          # reload

dotnet --info     # verify
```

Optional EF Core CLI:
```bash
dotnet tool install -g dotnet-ef
```

Install both LTS and STS side-by-side by running the install script twice
with different `--channel` values — they share `~/.dotnet`.

Everything lives under `~/.dotnet`, which is on the persistent volume, so
the install survives container restarts / image updates.

## Persistence

One volume at `/root` holds everything: shell history, tailscale state,
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

For **Fly.io**, see [fly.toml](./fly.toml) and the flysetup section
below. For **local Docker / OrbStack**, drop the snippet below into a
`compose.yml` next to your project.

### Local Docker / OrbStack — compose.yml

Create `compose.yml` (already gitignored in this repo so your auth key
won't leak), edit the three lines marked `← CHANGE`, then
`docker compose up -d`:

```yaml
name: devsys                                             # compose project — groups the containers below

services:

  # ── First container ───────────────────────────────────────────────
  box-a:
    image: ghcr.io/amitpareek/devsys:latest
    container_name: &host_a box-a                        # ← CHANGE: tailnet name
    hostname: *host_a
    environment:
      HOSTNAME: *host_a
      TS_AUTHKEY: ${TS_AUTHKEY:?set TS_AUTHKEY on the command line}
    volumes:
      - box-a-home:/root                                 # ← CHANGE (optional): /abs/host/path to bind-mount instead
      - /Users/you/projects:/root/work                   # ← CHANGE: host projects folder visible at ~/work
    restart: unless-stopped

  # ── Second container (uncomment to enable) ────────────────────────
  # box-b:
  #   image: ghcr.io/amitpareek/devsys:latest
  #   container_name: &host_b box-b
  #   hostname: *host_b
  #   environment:
  #     HOSTNAME: *host_b
  #     TS_AUTHKEY: ${TS_AUTHKEY}          # same key is fine (reusable)
  #   volumes:
  #     - box-b-home:/root
  #     - /Users/you/other-projects:/root/work
  #   restart: unless-stopped

volumes:
  box-a-home:
  # box-b-home:
```

- `name: devsys` is the **compose project name** — a label that groups
  the containers so `docker compose ps`, OrbStack UI, and similar tools
  show them together under "devsys".
- Each service key (`box-a`, `box-b`) is how you refer to a specific
  container with compose subcommands (`docker compose logs -f box-a`).
  Pick whatever names match your use (`beehive`, `cksys`, `devbox`, …).
- The `&host_a` / `*host_a` anchor ties `container_name`, docker
  `hostname`, and the `HOSTNAME` env var together — edit the name once.
- The second volume line bind-mounts a host projects folder into
  `~/work` so your Mac IDE and the container share the same files.
  Drop that line if you don't want host-side visibility; everything
  still lives on the named volume.

The compose file references `${TS_AUTHKEY}` (and `${TS_AUTHKEY_CKSYS}`
for the second container) — the auth key isn't stored in the file.
Export it once in your shell, then every `docker compose` command just
works:

```bash
# one-time per shell (or add to ~/.zshrc / ~/.bashrc).
# The same reusable key works for every container — generate one at
# https://login.tailscale.com/admin/settings/keys and mark it Reusable.
export TS_AUTHKEY=tskey-auth-xxxxxxxx

# start / update
docker compose up -d                               # create + start (or no-op if unchanged)
docker compose pull                                # fetch the latest image from ghcr
docker compose up -d --force-recreate              # recreate with the newly pulled image
docker compose pull && docker compose up -d --force-recreate   # update in one go

# observe
docker compose ps                                  # what's running under project 'devsys'
docker compose logs -f box-a                       # follow entrypoint output for one service
docker exec -it box-a zsh                          # shell in (lands in /root/work)
tailscale ssh root@box-a                           # once tailnet is joined

# stop
docker compose stop                                # stop, keep volumes + state
docker compose down                                # stop + remove containers, keep volumes
docker compose down -v                             # ALSO wipe volumes (destroys the box)
```

**Fastest Fly path** — the interactive script handles app / volume /
secret / deploy in one go:
```bash
./flysetup.sh
```
It asks for app name, region, volume size, and your `TS_AUTHKEY`, patches
fly.toml, and runs `fly apps create`, `fly volumes create`, `fly secrets
set`, `fly deploy` in sequence. Safe to re-run — each step checks for
existing state.

Manual path: edit the `app` + `HOSTNAME` + mount `source` fields in
[fly.toml](./fly.toml), `fly volumes create <vol-name> --size 10`,
`fly secrets set TS_AUTHKEY=...`, then `fly deploy --ha=false --now`.
The Machine never publishes a port — all access is through `tailscale ssh`
(or `fly ssh console` as a break-glass, which also lands as root in
`~/work`).

## Building / publishing

`.github/workflows/docker.yml` builds multi-arch (amd64 + arm64) and pushes
to `ghcr.io/amitpareek/devsys` on every push to `main` and on `v*` tags.

Local build for your host arch:
```bash
docker build -t devsys:local .
```

## Upgrading from an older image

The container now runs as **root**, not `dev` (simpler for headless
tailnet-only dev boxes — `fly ssh console`, `tailscale ssh`, and
`docker exec` all land in the same place). If you previously mounted a
volume at `/home/dev`, either:

1. Fresh start — nuke the volume, re-run, first boot seeds `/root` from
   the baked snapshot: `docker volume rm devsys-home` (or on Fly,
   `fly volumes destroy`).
2. Migrate — rename the volume mount destination to `/root`. Your files
   under `~/work`, `~/.claude`, etc. are preserved because the paths
   inside the volume are relative (`work/...`, not `/home/dev/work/...`).
   Update your compose / fly.toml / `docker run -v` to point at `/root`.

The Tailscale ACL must include `"users": ["root"]` (not just
`autogroup:nonroot`) since the only user is root — see step 2 of Quick
start.

## Troubleshooting

**`tailnet policy does not permit you to SSH to this node`** — the tailnet
ACL doesn't have an SSH rule matching this node. See step 2 above. Tag
mismatch or `autogroup:nonroot` without `root` in `users` is the usual
cause (we now run as root, so `users` must include `"root"`).

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
