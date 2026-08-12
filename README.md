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

**Contents:** [Required env](#required-environment-variables) · [Quick start](#quick-start) · [What's included](#whats-included) · [Obsidian](#obsidian-notes) · [.NET SDK](#optional--net-sdk) · [Persistence](#persistence) · [Cloud deployments](#cloud-deployments) · [Building](#building--publishing) · [Upgrading](#upgrading-from-an-older-image) · [Troubleshooting](#troubleshooting) · [Notes](#notes) · [Changelog](./CHANGES.md)

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

#### Taildrive (optional — share files over the tailnet)

The container automatically shares `~/work` over Tailscale's built-in
WebDAV server (`100.100.100.100:8080`) as a [Taildrive](https://tailscale.com/kb/1369/taildrive)
share named `work`. The sharing command runs on every boot from
`entrypoint.sh`, so **no per-box setup is needed** — but Taildrive is
gated by two `nodeAttrs` in the tailnet policy that you must add **once**
for the whole tailnet:

```json
"nodeAttrs": [
  {
    "target": ["autogroup:member", "tag:devsys"],
    "attr":   ["drive:share", "drive:access"]
  }
]
```

- `drive:share` lets the box expose `~/work`; `drive:access` lets other
  tailnet devices mount it.
- Include `tag:devsys` in `target` **only if your auth key is tagged** —
  tagged nodes are not in `autogroup:member`, so without it the box can't
  share. (`autogroup:member` alone is enough for an untagged box.)
- Until these attrs are present the share command is a harmless no-op; the
  boot log shows `taildrive: could not share ...`.

The `nodeAttrs` only *enable* Taildrive — they grant **read-only** access.
To get **read-write**, add a `grants` block too (without it, mounted shares
are read-only):

```json
"grants": [
  {
    "src": ["autogroup:member"],
    "dst": ["tag:devsys"],
    "app": {
      "tailscale.com/cap/drive": [
        { "shares": ["*"], "access": "rw" }
      ]
    }
  }
]
```

- `access` is `"rw"` (read-write) or `"ro"` (read-only); no grant = read-only.
- Narrow `src` (e.g. `["autogroup:admin"]`) to limit who can write.

Customize what's shared with the `TS_DRIVE_SHARES` env var
(`"name:path,name:path"`; empty string disables sharing entirely),
e.g. `-e TS_DRIVE_SHARES="work:/root/work,notes:/root/work/vault"`.

Mount a share from any tailnet device (Linux example, via `davfs2`):

```bash
mount -t davfs http://100.100.100.100:8080/<tailnet>/<hostname>/work /mnt/work
```

On macOS/Windows use the Tailscale app's drive UI; `rclone` also works
(add `--inplace` on client versions ≤ 1.64.2).

> **iOS caveat:** the Tailscale iOS app surfaces shares in the Files app
> for reading, but write support is incomplete — some operations (e.g.
> creating directories) fail with "the feature is not supported" even
> with an `rw` grant ([tailscale#14499](https://github.com/tailscale/tailscale/issues/14499),
> open). Writes from macOS/Linux clients work fully; for iOS writes, a
> third-party WebDAV client pointed at `100.100.100.100:8080` is a
> possible workaround.

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
| Claude Code | `claude` | npm `@anthropic-ai/claude-code`. `~/.claude/settings.json` uses `bypassPermissions` + `IS_SANDBOX=1` — the container-sandbox escape hatch that makes Claude skip its root guard. Zero prompts. |
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
| Editors | `micro` (the default `$EDITOR` — ctrl+s / ctrl+q, mouse, syntax highlighting, multi-cursor), `nano`, `vim`. Set `EDITOR` yourself (e.g. `docker run -e EDITOR=vim`) and that wins. |
| Modern unix | `eza` (`ls`, `ll`, `tree` aliases), `bat` (`cat` alias), `fd`, `rg` (ripgrep), `fzf` |
| Monitoring | `htop`, `ncdu` |
| Misc | `jq`, `direnv`, `tmux`, `lazygit` (alias `lg`), `glow` |
| Net / dev | `git`, `curl`, `wget`, `openssh-client`, `iputils-ping`, `dnsutils`, `net-tools`, `rsync`, `unzip`, `build-essential`, `pkg-config` |

### Tailnet
- `tailscale`, `tailscaled` — `--ssh` enabled on first boot, userspace-networking (no `NET_ADMIN` capability needed).

All npm-installed CLIs live at `~/.npm-global/bin/`, which is on PATH by
default. mise shims are in `~/.local/share/mise/shims/`.

## Installing the tool set on a plain VM

For boxes that aren't the container — a Debian 12/13 VM, a VPS, a CI
runner. [`install-tools.sh`](./install-tools.sh) installs the same set,
grouped, with an arrow-key picker.

```bash
curl -fsSL https://raw.githubusercontent.com/amitpareek/devsys/main/install-tools.sh -o /tmp/devsys-install.sh && sudo bash /tmp/devsys-install.sh
```

Download-then-run rather than `curl | bash`: piping consumes stdin so
the picker couldn't read your keys, and `sudo bash <(curl ...)` can't
reopen the process-substitution fd.

```
  devsys tool groups  select what to install (system-wide)

  ❯ [x] tailscale  tailscale + tailscaled via the official installer
    [x] base       apt essentials — curl, wget, git, zsh, vim, unzip, rsync…
    [x] build      compiler toolchain — build-essential, pkg-config, system…
    [x] editors    nano + micro (ctrl+s/ctrl+q, mouse, syntax highlighting)…
    [x] cli        modern CLI kit — ripgrep, fd, bat, fzf, eza, htop, ncdu,…
    [x] shell      zsh setup — starship prompt, direnv, tmux (mouse on), z …
    [x] mise       mise version manager (shared runtime store in /opt/mise)
    [x] node       JS/TS — node@lts, npm, pnpm, bun
    [x] python     Python 3.12 via mise (separate from the system python3)
    [ ] dotnet     .NET SDK (LTS channel) + runtime deps; dotnet on PATH
    [ ] docker     Docker CE engine + CLI, buildx and compose v2 plugins
    [ ] cloud      gh (GitHub), flyctl (Fly.io), neonctl (Neon)
    [ ] ai         AI coding CLIs — claude, gemini, codex, opencode
    [ ] ai-yolo    auto-approve configs for the AI CLIs — DANGEROUS outside…
    [ ] data       redis-server, postgresql-client (psql)
    [ ] notes      obsidian-headless (ob)
    [x] auth       devsys-auth — move tool logins between your machines as…

  ↑↓ move  space toggle  a all  n none  d defaults  ⏎ install  q quit
```

Run it with `sudo` **from your own account, not as root**. `$SUDO_USER`
decides whose logins get checked, who is offered the `docker` group, and
who owns per-user config. As bare root, all of that targets root instead.

Non-interactive forms:

```bash
sudo ./install-tools.sh --list            # groups, contents and status
sudo ./install-tools.sh node dotnet       # named groups; deps resolved
sudo ./install-tools.sh all               # everything except ai-yolo
sudo ./install-tools.sh --dry-run all     # print commands, change nothing
sudo ./install-tools.sh --check-logins    # just probe tool auth
sudo ./install-tools.sh --cleanup         # size + last-use, flag unused
sudo ./install-tools.sh --remove docker   # explicit uninstall
```

### Re-running: the picker is desired state

Run it again and the picker opens reflecting what's already on the box —
every group probed and labelled `installed`, `partial` or `—`, with
anything present pre-checked:

```
  ❯ [x] tailscale  installed   tailscale + tailscaled via the official inst…
    [x] base       installed   apt essentials — curl, wget, git, zsh, vim, …
    [x] node       partial     JS/TS — node@lts, npm, pnpm, bun
    [ ] dotnet     —           .NET SDK (LTS channel) + runtime deps; dotne…

  ↑↓ move  space toggle  a all  n none  d defaults  c current  ⏎ apply  q quit
```

Checked means "should be on this box". So:

- **checked + missing/partial** → installs or repairs it
- **checked + installed** → nothing to do
- **unchecked + installed** → **uninstalls it**, after you type `remove`

Removals cascade to dependents — dropping `mise` takes `node` with it —
and run in reverse install order. Two guard rails: `base` can never be
removed (it provides curl and ca-certificates, so removing it would break
the running script), and user **data** is never touched, so
`/var/lib/docker`, `/var/lib/redis` and `/var/lib/tailscale` survive and
are yours to delete deliberately.

Naming groups on the command line only ever installs —
`install-tools.sh node` never means "remove everything else". Use
`--remove <group>...` for a scriptable uninstall.

### Finding what you no longer use

```bash
sudo ./install-tools.sh --cleanup
```

```
    GROUP       STATUS          SIZE  LAST USED   IN SHELL HISTORY
    -------------------------------------------------------------------
    mise        installed     196 MB  today       yes (2)
    node        installed     124 MB  today       yes (2)
    dotnet      installed     712 MB  38d ago     no  unused?
    -------------------------------------------------------------------
    total                     1.0 GB
```

Groups with no shell-history hits and 14+ days idle get flagged, and it
offers the picker so you can uncheck them.

Read the last-used column as an estimate, not a fact: it comes from
binary atime, `relatime` only advances that about once a day, and a
`noatime` mount disables it entirely — which is detected and reported
rather than shown as "never used".

### Shell integration is automatic

Both **zsh and bash** get mise, direnv, starship, fzf keybindings and the
aliases, wired system-wide via `/etc/devsys/rc.zsh` and
`/etc/devsys/rc.bash`. Completions for gh, mise, flyctl, starship,
docker, tailscale and bun are generated into
`/usr/local/share/zsh/site-functions` and `/etc/bash_completion.d` for
whatever is installed — nothing to paste into your own rc file.

### System-wide, so every user gets the tools

Installs go to `/usr/local/bin`, `/opt` and `/etc` — not one user's
`$HOME` — so any account on the VM resolves them. Requires root.

| What | Where |
|---|---|
| Binaries, symlinks | `/usr/local/bin` |
| Shared runtime store (mise) | `/opt/mise` + `/etc/mise/config.toml` |
| bun, flyctl | `/opt/bun`, `/opt/fly` |
| .NET SDK | `/usr/share/dotnet` |
| Generated env / zsh config | `/etc/devsys/{env.sh,rc.zsh,yolo.zsh}` |
| Shell hooks | `/etc/profile.d/devsys.sh`, `/etc/zsh/zshenv`, `/etc/zsh/zshrc` |

Logins stay per-user. The auth check targets `$SUDO_USER`, not root.

### Tailscale first, then hand the VM over

`tailscale` is deliberately the first group. It installs, enables
`tailscaled` at boot (so the box rejoins the tailnet after a restart),
and joins with a fixed flag set:

```bash
tailscale up --hostname=<vm name> --ssh=true --accept-dns=true --accept-routes=true
```

The hostname comes from the machine's own hostname, sanitised to a DNS
label (lowercased, non-alphanumerics to hyphens); override with
`TS_HOSTNAME`. A node that's already joined gets `tailscale set` with the
same flags rather than a blocking re-`up`.

It runs with `--timeout`, then reports the backend state — a bare
`tailscale up` blocks forever when your tailnet requires manual device
approval, without saying so. If you see `NeedsMachineAuth`, approve the
node on the admin console's Machines page; `tailscaled` already holds the
credentials and connects on its own, with no need to re-authenticate.

Then it **pauses**:

```
── Tailscale is done — this box is now reachable.
    still to install: base build editors cli shell mise node python auth
    you can hand the VM over now and let the developer finish.

    Continue installing the rest now? [y/N]
```

Answer `n` and it prints the exact command to resume, so whoever picks
up the box can finish the install themselves.

### Provisioning a VM from scratch — cloud-init

[`cloud-config.yaml`](./cloud-config.yaml) is cloud-init user-data that
takes a blank Debian 12/13 VM to a ready dev box unattended. Paste it as
"user data" when creating the VM — it works anywhere cloud-init runs
(Hetzner, DigitalOcean, Vultr, AWS, GCP, Azure, Proxmox, multipass,
libvirt).

Edit four things before using it:

| # | What | Why |
|---|---|---|
| 1 | `hostname:` | also becomes the tailnet machine name |
| 2 | `users[0].name` | the developer who gets the box |
| 3 | `ssh_authorized_keys` | their public key |
| 4 | `TS_AUTHKEY` | optional — see below |

It sets the hostname, creates the developer with passwordless sudo and
their SSH key, installs the chosen groups system-wide, and switches their
shell to zsh. Progress lands in `/var/log/devsys-bootstrap.log`, and
`/var/lib/devsys-bootstrap.done` marks completion.

Settings live in `/etc/devsys/bootstrap.conf`:

```sh
TS_AUTHKEY=""                # empty = install Tailscale, don't join
DEVSYS_USER="dev"            # who per-user config belongs to
DEVSYS_GROUPS="tailscale base build editors cli shell mise node python auth"
DEVSYS_REF="main"            # pin to a tag/commit for reproducible rebuilds
```

Quote any value containing spaces — the file is sourced by a shell, so an
unquoted `DEVSYS_GROUPS` would have its extra words run as a command.

**On `TS_AUTHKEY`:** leave it empty and the VM installs Tailscale but
waits for you to run `sudo tailscale up`. Fill it in and the VM joins
itself with the usual flags. Be deliberate about that choice — user-data
is readable from the instance metadata service by anything running on the
box, and many providers keep it retrievable for the instance's whole
life. If you use one, prefer a short-lived, tagged, single-use key and
treat it as burned once the VM boots. The bootstrap blanks it from
`/etc/devsys/bootstrap.conf` afterwards, which removes it from disk but
not from metadata.

The install runs with `--no-login-check`, because OAuth flows need a
browser and a human. Once the developer is in:

```bash
install-tools.sh --check-logins
```

Two environment variables make this work, and are useful on their own:
`DEVSYS_USER` tells the installer which account owns the box (cloud-init
runs as root with no `$SUDO_USER`, so without it every per-user action
would target root), and `TS_AUTHKEY` triggers the unattended join.

### Sharing logins across machines — `devsys-auth`

Logging into gh, fly, claude, gemini, codex and the rest on five VMs by
hand is the tedious part. The `auth` group installs
[`devsys-auth`](./devsys-auth.sh): log in once, export an encrypted
bundle, import it everywhere else.

```bash
devsys-auth list                          # what credentials exist here
devsys-auth export -o ~/work/creds.age    # age-encrypted, mode 0600
devsys-auth import ~/work/creds.age       # on the other machines
```

Covers `~/.config/gh/hosts.yml`, `~/.fly/config.yml`,
`~/.config/neonctl/credentials.json`, `~/.claude/.credentials.json`,
`~/.gemini/oauth_creds.json`, `~/.codex/auth.json`,
`~/.local/share/opencode/auth.json`, `~/.docker/config.json`, `~/.npmrc`
— only files that are actually auth material. Encryption is mandatory
(passphrase by default, `-r` for an age public key). Import backs up
anything it would overwrite and re-applies `0600`.

Since `~/work` is already shared over Taildrive, dropping the bundle
there is usually the easiest transport.

**Tailscale is excluded on purpose** — a node's identity is
per-machine and can't be copied, so run `sudo tailscale up` on each box.

> The bundle is equivalent to a password vault for every account in it.
> Keep it `0600`, never commit it, and delete stale copies. This model
> suits a handful of long-lived machines you own; for ephemeral or
> multi-tenant fleets use short-lived scoped tokens instead.

### Other deliberate choices

- **Nothing is clobbered.** `/etc/zsh/zshrc`, `/etc/zsh/zshenv` and
  `/etc/tmux.conf` are only ever *appended* to, inside a
  `# >>> devsys env >>>` marker block. Existing AI-CLI configs are
  left alone rather than overwritten.
- **`ai-yolo` is opt-in and applies to every user.** `bypassPermissions`
  / `danger-full-access` / `--yolo` are fine on a disposable
  single-owner VM and not on a machine you care about, so `all` skips it
  and selecting it requires typing `yolo`. It works system-wide via
  Claude Code's `/etc/claude-code/managed-settings.json`, Gemini's
  `/etc/gemini-cli/settings.json`, and — since Codex only reads
  `$HOME/.codex` — a seed into every home plus `/etc/skel`. Every file it
  creates is recorded in `/etc/devsys/ai-yolo.manifest`, so uninstalling
  removes exactly those and never a config you wrote yourself.
- **Docker group membership is a prompt, not a default** — it grants
  effective root, so you're asked before your user is added.
- **Re-runnable.** Every step checks first, so re-running only fills in
  what's missing.

Debian 12/13 and Ubuntu only; it refuses to run elsewhere rather than
half-installing.

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
