# devsys — reusable Ubuntu dev containers on Tailscale

**Model:** one generic base image (`devsys-base`) shared across customers.
Per-customer containers clone from the same image; first-boot setup configures
them interactively.

## Architecture

```
~/dev-setup/
  base/
    Dockerfile              # builds devsys-base:latest
    entrypoint.sh           # starts tailscaled (and redis if selected)
    setup.sh                # interactive first-boot installer (baked in)
    build.sh                # local build + optional Docker Hub push
  customer-a/
    docker-compose.yml      # uses devsys-base, mounts bsvault + volumes
    work/                   # projects (bind-mount → ~/work in container)
    bsvault/                # Obsidian vault (bind-mount → ~/vault)
  customer-b/
    docker-compose.yml      # mounts personal vault
    work/
    personal/               # Obsidian vault
  README.md
```

## One-time: build the base image

```bash
cd ~/dev-setup/base
./build.sh                  # tags devsys-base:latest locally
```

Optional — publish to Docker Hub for use on other machines:
```bash
docker login
./build.sh push yourusername    # multi-arch, pushes to Docker Hub
```

If you push, edit each `customer-*/docker-compose.yml` and change
`image: devsys-base:latest` to `image: yourusername/devsys-base:latest`.

## Per-container: start and run setup

For each customer (`customer-a` or `customer-b`):

```bash
cd ~/dev-setup/customer-a
mkdir -p work bsvault        # or: work personal (for customer-b)
docker compose up -d
```

The container starts and waits. It has no tailnet presence yet.

### First access: OrbStack UI

1. Open OrbStack
2. Find `customer-a-dev` in the Containers list
3. Right-click → **Open Terminal** → choose `zsh`
4. You're in as user `dev`. Run:

```bash
setup.sh
```

The script will ask for:
1. **Tailnet hostname** (default: container name, e.g. `customer-a`)
2. **Which tools to install** — numbered checklist; enter numbers, `all`, or `none`

It will run `tailscale up` and print a login URL — open it in your browser
to approve the container on your tailnet.

After setup completes, `exit` the shell.

### Subsequent access: Tailscale SSH

```bash
tailscale ssh dev@customer-a
tailscale ssh dev@customer-b
```

You're in. No SSH keys to manage; auth flows through your tailnet identity.

## Re-running setup.sh

The script is idempotent by design:

```bash
setup.sh                    # verify + repair: skips what's already working
setup.sh --reconfigure      # re-prompt for hostname + tool selection
```

You can also SSH in later and run `setup.sh` to **add** tools you skipped
originally — use `--reconfigure`, pick the superset, and only the new ones
will actually install.

## What gets installed (the checklist)

Grouped in the prompt:

**Runtimes** — Node.js LTS, Python 3.12, Bun, pnpm
**CLIs** — gh, flyctl, neonctl, Claude Code, Gemini CLI, Codex CLI, opencode
**Services** — Redis (auto-starts on boot if selected)
**Shell & utilities** — modern CLI bundle (ripgrep, fd, bat, fzf, eza, htop,
ncdu, jq), starship, direnv, tmux, lazygit
**Knowledge / notes** — obsidian-export, glow

## Obsidian — how the Mac + container integration works

Vaults live on the **Mac** (so Obsidian GUI on macOS edits them normally) and
are bind-mounted into their respective container at `~/vault`.

- **Customer A** container sees `bsvault` (from `~/dev-setup/customer-a/bsvault/`)
- **Customer B** container sees `personal` (from `~/dev-setup/customer-b/personal/`)

On the Mac, in Obsidian:
- "Open folder as vault" → `~/dev-setup/customer-a/bsvault`
- Do the same for `~/dev-setup/customer-b/personal`

Inside the containers, CLI tools (obsidian-export, glow, rg, bat) operate on
the same files — so you can search, export, or view notes from either side.

## Directory defaults (no drift)

The setup script sets these explicitly so re-runs don't change anything:

| Tool   | Location                          |
|--------|-----------------------------------|
| npm    | `~/.npm-global` (via NPM_CONFIG_PREFIX) |
| pnpm   | `~/.local/share/pnpm` (PNPM_HOME) |
| Bun    | `~/.bun` (BUN_INSTALL)            |
| mise   | `~/.local/share/mise` (MISE_DATA_DIR) |
| flyctl | `~/.fly`, symlinked into `~/.local/bin` |

All of these paths are on volumes, so they survive container rebuilds.

## Daily operations

| Task | Command |
|------|---------|
| SSH in | `tailscale ssh dev@customer-a` |
| Shell via OrbStack | right-click container → Open Terminal |
| Add more tools | `setup.sh --reconfigure` (inside container) |
| Restart container | `cd customer-a && docker compose restart` |
| Rebuild container | `cd customer-a && docker compose up -d --force-recreate` |
| Update base image | `cd base && ./build.sh` then rebuild containers |
| Container logs | `docker logs -f customer-a-dev` |
| Stop | `cd customer-a && docker compose down` |
| Nuke container + volumes | `cd customer-a && docker compose down -v` (loses tailscale session, history, AI auth, redis data) |

## Adding a third customer

```bash
cd ~/dev-setup
cp -r customer-a customer-c
# Edit customer-c/docker-compose.yml:
#   container_name: customer-c-dev
#   hostname: customer-c
#   ./<vault>:/home/dev/vault   (pick a vault name)
#   rename all `customer-a-*` volumes to `customer-c-*`
cd customer-c
mkdir -p work
docker compose up -d
# Open via OrbStack UI, run setup.sh, enter hostname 'customer-c'
```

## Notes

- **Tailscale ACL**: make sure your tailnet policy includes an `ssh` rule
  allowing user `dev` (or `autogroup:nonroot`). See:
  https://login.tailscale.com/admin/acls
- **Mac sleep**: containers unreachable while Mac sleeps.
  Disable: `sudo pmset -a sleep 0 disablesleep 1`
- **`--dangerously-skip-permissions` on claude**: aliased in zshrc.
  Removes prompts before file edits / bash. Scope is contained to
  `~/work` inside the container. Remove the alias to re-enable prompts.
- **Redis isolation**: per-container, bound to 127.0.0.1. Customer A's Redis
  is not visible to Customer B or to the tailnet.
- **MagicDNS**: enable at https://login.tailscale.com/admin/dns so bare
  `customer-a` resolves. Until then use full `customer-a.tailXXXX.ts.net`.
