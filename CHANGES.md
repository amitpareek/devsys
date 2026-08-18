# Changelog

All notable changes to **devsys** (`ghcr.io/amitpareek/devsys`).
Dates are UTC. Format follows [Keep a Changelog](https://keepachangelog.com).

## [Unreleased]

### Changed

- **The `tailscale` group now asks how to join, instead of hard-coding
  it.** Three prompts in order — enable Tailscale SSH?, comma-separated
  tags, then the auth key — followed by `tailscale up` and the existing
  "install the rest?" hand-over pause. Tags are normalised: `prod, Dev`
  becomes `tag:prod,tag:dev`, since Tailscale requires the prefix and
  lowercase names. The auth key is read visibly, matching
  `flysetup.sh`'s reasoning that a silent read breaks paste in many
  terminals. `TS_SSH`, `TS_TAGS` and `TS_AUTHKEY` preset any of the three
  from the environment, which is how the cloud-config drives it
  unattended with no prompts.

- **`notes` (the Obsidian headless Sync client) is now in the default
  selection** and in the cloud-config's group list — it existed as a
  group but was never selected by default. Confirmed
  `obsidian-headless` on npm is the official client: published by
  Dynalist Inc. from `github.com/obsidianmd/obsidian-headless`,
  installing the `ob` binary, per
  <https://obsidian.md/help/sync/headless>.

- **`bind9-dnsutils` replaces `dnsutils`** in the base package set.
  Debian 13 dropped the `dnsutils` transitional package; it still
  installs there via the virtual provider, so this was not a failure,
  but naming the real package removes the ambiguity. Present on Debian
  12, 13 and Ubuntu alike.

### Added

- **[`cloud-config.yaml`](./cloud-config.yaml)** — cloud-init user-data
  that provisions a blank Debian 12/13 VM unattended: sets the hostname
  (which becomes the tailnet name), creates the developer account with
  passwordless sudo and their SSH key, installs the chosen groups
  system-wide, and switches their shell to zsh. Generic cloud-init, so it
  works on Hetzner, DigitalOcean, Vultr, AWS, GCP, Azure, Proxmox,
  multipass and libvirt alike. Settings live in
  `/etc/devsys/bootstrap.conf` (`TS_AUTHKEY`, `DEVSYS_USER`,
  `DEVSYS_GROUPS`, `DEVSYS_REF` — pin the ref for reproducible rebuilds).
  Logs to `/var/log/devsys-bootstrap.log`, marks completion with
  `/var/lib/devsys-bootstrap.done`.

  `TS_AUTHKEY` is an opt-in placeholder rather than a requirement: empty
  means install Tailscale and wait for a human, set means join
  unattended. Documented with the caveat that user-data is readable from
  the instance metadata service, so a short-lived tagged key should be
  treated as burned once the VM boots; the bootstrap blanks it from disk
  afterwards, which does not remove it from metadata.

  The account's shell is deliberately `bash` in the `users:` block and
  switched to zsh only after install — cloud-init creates users before
  packages, so naming `/bin/zsh` up front would leave a broken shell.

- **`DEVSYS_USER` and `TS_AUTHKEY` environment support in
  `install-tools.sh`**, needed for any unattended run. cloud-init's
  `runcmd` executes as root with no `$SUDO_USER`, so without `DEVSYS_USER`
  the docker group, ai-yolo seeding and login checks would all silently
  target root rather than the developer receiving the VM; it errors out if
  the named user doesn't exist. `TS_AUTHKEY` joins the tailnet with the
  standard flag set, and with neither a key nor a terminal the node is
  left unjoined instead of running a bare `tailscale up` that would block
  until timeout.

### Fixed

- **The login check could fire OAuth logins unattended.** `--yes` made
  `confirm()` auto-accept, so a non-interactive run with `-y` would have
  attempted `gh auth login` with no terminal to complete it. It now lists
  the commands to run and attempts nothing when stdin isn't a tty.

### Added

- **The picker is now desired state, and re-running shows what's
  installed.** It opens reflecting reality — each group is probed and
  labelled `installed` / `partial` / `—`, and anything present starts
  checked. Unchecking an installed group **uninstalls** it after typing
  `remove` to confirm. Removals cascade to dependents (dropping `mise`
  takes `node` with it) and run in reverse install order. `base` is
  PROTECTED and can never be removed — it provides curl, ca-certificates
  and gnupg, so removing it would break the running script and cascade
  into everything else. A fresh box with nothing installed still starts
  from the defaults. New `c` key resets the selection to current state.

  Naming groups on the command line only ever installs — `install-tools.sh
  node` never means "remove everything else". `--remove <group>...` is the
  explicit, scriptable uninstall.

- **`--cleanup`** — per-group table of disk footprint, a last-used
  estimate and whether any user's shell history mentions the tools, then
  flags groups with no history hits and 14+ days idle as removal
  candidates and offers the picker. Size comes from dpkg's
  `Installed-Size` plus `du` of the directories we own (`/opt/mise`,
  `/opt/bun`, `/usr/share/dotnet`, npm `node_modules`). Last-used is
  binary atime, which is an estimate not a fact — `relatime` means
  day-granularity, and a `noatime` mount is detected and reported rather
  than being silently shown as "never used". Data directories
  (`/var/lib/docker`, `/var/lib/redis`, `/var/lib/tailscale`) are sized
  and listed but never removed with their group.

- **Automatic shell integration for bash as well as zsh.** Previously
  bash got PATH only. Now `/etc/devsys/rc.bash` mirrors `rc.zsh` (mise,
  direnv, starship, fzf keybindings, aliases) and is wired into
  `/etc/bash.bashrc`; aliases moved to a shared
  `/etc/devsys/aliases.sh`. `rc.zsh` now also runs `compinit` with
  `/usr/local/share/zsh/site-functions` on `fpath`, without which no
  completion did anything.

- **System-wide shell completions**, generated for whatever is
  installed, so nobody pastes `eval "$(tool completion zsh)"` anywhere:
  gh, mise, flyctl, starship, docker, tailscale, rclone and bun, for
  both shells. Best-effort — a tool with no completion subcommand is
  skipped quietly.

- **Tailscale joins with a fixed flag set**:
  `--hostname=<vm name> --ssh=true --accept-dns=true --accept-routes=true`.
  The hostname is derived from the machine's own hostname and sanitised
  to a DNS label (lowercased, non-alphanumerics to hyphens, edges
  trimmed); override with `TS_HOSTNAME`. An already-joined node gets
  `tailscale set` with the same flags instead of a blocking re-`up`.

### Changed

- **`ai-yolo` is now genuinely system-wide.** It previously did two
  different things at once: the codex/gemini aliases landed in `/etc` and
  so applied to *every* user, while the auto-approve configs were written
  only to `$SUDO_USER`'s home. The result was that a new account
  inherited `codex --dangerously-bypass-approvals-and-sandbox` and
  `gemini --yolo` without anyone deciding it, while `claude` — which has
  no alias and relies solely on its settings file — kept prompting. Now
  it is uniformly system-wide: Claude Code via
  `/etc/claude-code/managed-settings.json` (managed policy settings
  outrank per-user ones), Gemini via `/etc/gemini-cli/settings.json`, and
  Codex — which only ever reads `$HOME/.codex` — seeded into every home
  plus `/etc/skel` for future accounts.

  Every file it creates is recorded in
  `/etc/devsys/ai-yolo.manifest`, and uninstalling deletes exactly those
  — so a config a user wrote themselves (which install already skipped)
  is never destroyed.

- **`tailscale up` no longer hangs forever.** A bare `up` blocks
  indefinitely when the tailnet requires manual device approval, with no
  indication why. It now runs with `--timeout=120s` and then reports the
  actual backend state, naming the fix for `NeedsMachineAuth` (approve
  the node in the admin console — no re-authentication needed) and
  `NeedsLogin`. The install continues either way.

### Fixed

- **Login check crashed for any npm-installed CLI.** Offering to run
  `codex login` died with `/usr/bin/env: 'node': No such file or
  directory`: commands ran via `sudo -u <user>`, which inherits sudo's
  `secure_path`, so `/opt/mise/shims` was absent and `MISE_DATA_DIR`
  unset — and every one of those CLIs starts with `#!/usr/bin/env node`.
  Now run through `bash -lc`, which sources
  `/etc/profile.d/devsys.sh` and therefore gets exactly the environment a
  real login gets. This also let the `$HOME`-rewriting hack in the probes
  go away, since `$HOME` now expands in the target user's own shell.

- **Status detection depended on the caller's PATH.** Under `sudo`'s
  `secure_path` a fully installed `node` group read as `partial`, which
  in desired-state mode would have offered to remove it. The script now
  adopts the environment it manages (`/etc/devsys/env.sh` plus the known
  directories) before probing anything.

- **`/etc/devsys/env.sh` aborted when `HOME` was unset.** It referenced
  `$HOME` unguarded, so sourcing it under `set -u` — from cron, a systemd
  unit, or this script itself — failed with `HOME: unbound variable`.
  Now `${HOME:-}`; verified sourcing cleanly under `set -eu` with no
  `HOME` and a stripped `PATH`.

- **`install-tools.sh` now installs system-wide and targets Debian
  12/13.** Reworked from the earlier `$HOME`-relative design because
  each VM belongs to one developer but every account on it should see
  the tools. Binaries go to `/usr/local/bin`, the shared mise runtime
  store to `/opt/mise` (+ `/etc/mise/config.toml`), bun/flyctl to
  `/opt`, .NET to `/usr/share/dotnet`, generated config to
  `/etc/devsys/`, and shell hooks into `/etc/profile.d/devsys.sh`,
  `/etc/zsh/zshenv` and `/etc/zsh/zshrc`. Requires root. Logins stay
  per-user — everything auth-related targets `$SUDO_USER`.

  Because `sudo bash <(curl ...)` cannot reopen a process-substitution
  fd, the documented one-liner is now download-then-run.

- **`runtimes` split into `mise`, `node` and `python`, and a separate
  `dotnet` group added** — one developer may want JS and C# on the same
  box without dragging in the other's toolchain.

- **`tailscale` is now the first group and pauses afterwards.** It
  enables `tailscaled` at boot, offers to run `tailscale up`, then asks
  whether to continue — so a VM can be put on the tailnet and handed to
  a developer who finishes the install themselves. Declining prints the
  exact resume command. `tailscale` deliberately has no group
  dependencies so it can run before the full `base` group; a small
  `ensure_prereqs` step installs just ca-certificates/curl/gnupg.

### Added

- **`docker` group** — Docker CE from `download.docker.com`, with
  `docker-buildx-plugin` and `docker-compose-plugin`. The repo suite is
  probed before use, so an unsupported release fails with a readable
  message instead of an apt 404, and falls back to the newest published
  suite. Adding your user to the `docker` group is a prompt, not a
  default, because that grants effective root.

- **`dotnet` group** — .NET SDK from the LTS channel via
  `dotnet-install.sh` (works on amd64 and arm64, and on Debian and
  Ubuntu alike, unlike the Microsoft apt feed). Installs the ICU and
  OpenSSL runtime deps, picking the right versioned package name per
  release (`libicu76`/`libicu72`, `libssl3t64`/`libssl3`).

- **`auth` group + [`devsys-auth`](./devsys-auth.sh)** — moves tool
  logins between machines you own as an age-encrypted bundle:
  `devsys-auth list|export|import`. Covers gh, fly, neonctl, claude,
  gemini, codex, opencode, docker and npm credential files only — no
  general config, no history files. Encryption is mandatory
  (passphrase, or `-r` for an age public key with `-i` on import);
  bundles are `0600`; import backs up anything it would overwrite and
  re-applies `0600`. Tailscale is excluded because node identity is
  per-machine.

- **Login checking.** After installing (or via `--check-logins`) the
  script probes each auth-requiring tool as the invoking user, reports
  logged-in / not-logged-in, and offers to run each login command right
  there. Also reports whether `tailscaled` is enabled at boot, since
  being logged in is worthless if the daemon doesn't come back after a
  reboot.

### Fixed

- **Nondeterministic package detection under `set -o pipefail`.**
  `apt_has` used `apt-cache policy | grep -q`; `grep -q` exits at the
  first match, `apt-cache` then dies of SIGPIPE, and `pipefail` reports
  the whole pipeline as failed — so an available package read as
  missing depending purely on whether its output fit the pipe buffer.
  This is why `libssl3t64` was reported unavailable on trixie while
  `libicu76` succeeded in the same run, and why `eza`/`glow` fell back
  to third-party repos unpredictably. Rewritten pipe-free with bash
  string matching; verified 30/30 stable per package on both Debian 12
  and 13. The same trap in the docker-group membership check was fixed
  too.

- **`npm` not found immediately after installing node.** `env.sh` only
  adds PATH entries for directories that already exist, so
  `/opt/mise/shims` — created by the first mise install — was missing
  from the running script's PATH, and the `node` group failed at its own
  `pnpm` step. `mise_use` now splices the shims directory into PATH for
  the remainder of the run.

- **Removed the `/dev/fd` dependency.** Group resolution used
  `mapfile < <(...)`; process substitution needs `/dev/fd`, which is
  absent in minimal chroots and some CI images, where the script died
  with `/dev/fd/63: No such file or directory`. Replaced with a
  herestring-based helper.

- **`nano` and `micro` editors, plus a default `$EDITOR`.** The image
  previously baked only `vim`. `nano` happened to be present on some
  existing volumes because it had been installed by hand — it was never
  in the `Dockerfile`, so fresh deploys didn't get it. Now all three are
  baked, and `.zshrc` sets `EDITOR="${EDITOR:-micro}"` + `VISUAL="$EDITOR"`
  so `git commit`, `crontab -e` etc. open something friendly. An
  inherited `EDITOR` (e.g. `docker run -e EDITOR=vim`) still wins.

  micro was chosen as the default over nano because it behaves like a
  normal editor (ctrl+s save, ctrl+q quit) while still having syntax
  highlighting, mouse support and multi-cursor — and it's a single Go
  binary in Ubuntu's repos, so no download step.

  Image-affecting (`Dockerfile`) — CI rebuilds. **Existing deployments:**
  the new binaries arrive with the next image pull + recreate, but the
  `EDITOR` export will *not*, because `--ignore-existing` never
  overwrites an existing `~/.zshrc`. To pick it up, either add the two
  lines by hand or `rm ~/.zshrc` and restart to re-seed it.

- **`editors` group in `install-tools.sh`** — installs `nano` + `micro`
  and wires `EDITOR`/`VISUAL` into the generated `~/.devsys/env.sh`,
  preferring micro → nano → vim by availability and never overriding an
  `EDITOR` you already set. Included in the picker's default selection.

- **`install-tools.sh`** — standalone installer that puts the devsys
  tool set on any plain Ubuntu/Debian box (VPS, CI runner, laptop),
  grouped so you pick what you want. Default invocation shows an
  arrow-key checkbox picker (↑↓ move, space toggle, `a`/`n`/`d`
  select all/none/defaults, Enter installs) built on raw ANSI rather
  than `tput`, so it works without `ncurses-bin`. Also drivable
  non-interactively: `--list`, `--dry-run`, named groups, `all`.
  Groups: `base`, `build`, `cli`, `shell`, `runtimes`, `cloud`, `ai`,
  `ai-yolo`, `data`, `notes`, `tailscale`; inter-group deps are
  resolved automatically (e.g. `ai` pulls `runtimes` pulls `base`).

  Deliberately diverges from the image in four ways:
  - Non-destructive. Everything is `$HOME`-relative; `~/.zshrc`,
    `~/.bashrc` and `~/.tmux.conf` are only appended to, inside a
    `# >>> devsys env >>>` marker block. Generated config is isolated
    in `~/.devsys/{env.sh,rc.zsh,yolo.zsh}`, and pre-existing AI-CLI
    configs are left alone instead of overwritten.
  - The auto-approve configs are split into an opt-in `ai-yolo` group
    that `all` skips and that requires typing `yolo` to confirm —
    `bypassPermissions` / `danger-full-access` are fine in a
    tailnet-only container and not fine on a machine you care about.
  - `sudo` is used only for apt; starship, lazygit, mise, bun and the
    npm globals install under `$HOME`, so it works as any sudo-capable
    user, not just root.
  - Idempotent — re-running tops up only what's missing.

  Not image-affecting, so CI does not rebuild. Verified with
  shellcheck (clean at `info` level), the interactive picker driven
  over a pty, and a real end-to-end `shell`+`runtimes` install as a
  non-root user (node 24.19.0, python 3.12.13, bun 1.3.14 all
  resolving in a fresh zsh login shell).

- **Taildrive share on boot.** `entrypoint.sh` now runs `tailscale drive
  share` after the tailnet comes up, exposing `~/work` over Tailscale's
  built-in WebDAV server (`100.100.100.100:8080`) as a share named `work`.
  Configurable via the `TS_DRIVE_SHARES` env var
  (`"name:path,name:path"`; empty disables). Best-effort: it's a no-op
  until the tailnet policy grants the `drive:share`/`drive:access`
  `nodeAttrs`, so it never aborts boot. README's "Configure the tailnet
  policy" step documents the required `nodeAttrs` (one-time, tailnet-wide),
  the `grants` block needed for read-write (without it shares mount
  read-only), the tagged-auth-key targeting caveat, how to mount a share,
  and the known iOS Files write limitation (tailscale#14499).
  Image-affecting (`entrypoint.sh`) — existing deployments pick it up on
  the next image pull + recreate.

- `z` — tmux session/window manager with arrow-key picker, baked at
  `/usr/local/bin/z`. Outside tmux it manages sessions; inside tmux it
  manages windows of the current session. Installed system-wide (not
  under `/root`), so it's available immediately without volume seed
  and updates land on every image pull.

- `/etc/tmux.conf` with `set -g mouse on`. System-wide so it refreshes
  on image pulls; `~/.tmux.conf` still overrides per-volume.

- `CLAUDE.md` at repo root — architecture + conventions guide for
  future Claude Code sessions. Covers the skel-seed lifecycle, root
  rationale and `IS_SANDBOX=1` workaround, entrypoint parallelism,
  `WORKDIR` rationale, flysetup name-derivation, CI matrix, and the
  "every change updates `CHANGES.md`" rule.

---

## 2026-04-22 — initial all-inclusive image, root refactor, AI auto-approve

Large bootstrapping session. The image grew from "base Ubuntu +
`setup.sh` to pick tools" into a single all-inclusive dev container
that boots straight onto Tailscale, runs as root in a
container-sandbox, auto-approves every AI CLI, and deploys identically
on local Docker / OrbStack / Fly.io from one image.

### Added

- **All-inclusive image.** Every runtime, CLI, and service pre-installed
  — Node LTS + Python 3.12 (via mise), Bun, pnpm; gh, flyctl, neonctl,
  Claude Code, Gemini CLI, Codex CLI, opencode, obsidian-headless
  (`ob`), psql; redis + tailscale as always-on services; starship,
  direnv, tmux, lazygit, eza, bat, fd, rg, fzf, htop, ncdu, jq, glow
  for the shell. No interactive `setup.sh` on first boot.
- **Fly.io deployment path** via [`fly.toml`](./fly.toml) and the
  interactive [`flysetup.sh`](./flysetup.sh) (org/hostname/region/volume
  prompts, validates hostname charset, numbered region picker, handles
  existing-app and existing-volume states, `fly deploy --ha=false
  --now` + post-deploy machine-start sweep, backs up fly.toml).
- **Compose template in README.** Two-container example with YAML
  anchors so `container_name` / `hostname` / `HOSTNAME` env are edited
  in one place. `TS_AUTHKEY` comes from the shell env, not the file.
  `compose.yml` is gitignored to keep secrets out of commits.
- **GitHub Actions workflow** ([`docker.yml`](./.github/workflows/docker.yml))
  publishes multi-arch images to GHCR on every `main` push that
  touches `Dockerfile`, `entrypoint.sh`, or the workflow itself. Uses
  native-arch runners (`ubuntu-24.04` + `ubuntu-24.04-arm`) with
  per-arch GHA cache scopes and a `merge` job for the multi-arch
  manifest — ~10 min → ~3 min.
- **AI CLI auto-approve defaults** baked into `/etc/skel/devsys`:
  - `~/.claude/settings.json` — `defaultMode: bypassPermissions` +
    `env.IS_SANDBOX=1`. The `IS_SANDBOX=1` signal lets Claude Code
    accept `bypassPermissions` even as root; zero prompts.
  - `~/.codex/config.toml` — `approval_policy = "never"`,
    `sandbox_mode = "danger-full-access"`.
  - `~/.gemini/settings.json` — `general.defaultApprovalMode =
    "auto_edit"`.
  - zsh aliases: `codex` → `codex --dangerously-bypass-approvals-and-sandbox`,
    `gemini` → `gemini --yolo`. (Claude stays un-aliased; its flag
    refuses as root, so it relies solely on `settings.json`.)
- **Every-boot home-dir top-up.** Entrypoint rsyncs the baked
  `/etc/skel/devsys` into `/root` on every boot with
  `--ignore-existing` — new files from image updates surface
  automatically, user edits are preserved.
- **Parallel seed + tailscale bring-up.** First-boot tailnet
  reachability dropped from ~3-5 min (sequential) to ~30 s (rsync in
  background, tailscaled starts immediately).
- **`WORKDIR /root/work`** in the image so every shell (`docker exec`,
  OrbStack UI terminal, `fly ssh console`, `tailscale ssh`) lands in
  `~/work` regardless of shell startup files.
- **`.zlogin` fallback cd** for OrbStack's injected shell, which
  ignores `.zshrc`.
- **README** rewritten for the new model: required env-var table at
  top, Quick install snippet, instant tailnet SSH + Cursor/VS Code
  Remote-SSH guidance, precise tool inventory tables, Obsidian and
  .NET SDK sections, Upgrading + Troubleshooting sections, compose
  command reference with start/pull/recreate/stop lifecycle.

### Changed

- **Container now runs as root, not a separate `dev` user.** Unifies
  every access path — `docker exec`, OrbStack terminal, `tailscale ssh
  root@host`, and `fly ssh console` all land in the same shell, same
  `~/work`, same PATH. No more "lands as root, can't see dev's npm
  globals" drift. The IS_SANDBOX path for Claude + aliases for Codex
  and Gemini (with `--dangerously-bypass-...` / `--yolo`) make this
  safe for AI CLIs.
- **Volume mount destination moved** from `/home/dev` → `/root`. Same
  model, different path. Upgrade path documented in README.
- **Fly VM size bumped** from `shared-cpu-1x` to `performance-1x` —
  dedicated CPU, ~3-4× faster I/O for the seed rsync and npm/builds.
  ~$5.70/mo → ~$31/mo.
- **HOSTNAME env var** is the single source of truth for both the
  kernel hostname and the Tailscale hostname (no separate `TS_HOSTNAME`
  var).
- **Tailscaled output** goes to the container's stdout (visible in
  `docker logs` / `fly logs`), with `--verbose=1`. Previously hidden in
  `/var/log/tailscaled.log`, which made the "tailscale never came up"
  case undiagnosable from outside the container.
- **Flysetup prompts**: hostname first, then org. App name derived as
  `<org>-devsys-<hostname>` (fly app names are globally unique,
  hostname-only collided). Volume name derived as
  `devsys_<hostname>_vol`. Hostname validated against `[a-z0-9_]`.
  Region picker is a numbered menu. Backspace works everywhere —
  removed ANSI escapes from the prompt strings that were confusing
  terminal cursor math. Existing app → prompt `[r]edeploy /
  [d]elete+recreate`; existing volume → prompt `[k]eep / [d]elete`.
  Deploy uses `--ha=false --now` and a post-deploy sweep that
  destroys+redeploys stuck `created` machines.
- **CI workflow** uses matrix over native-arch runners instead of a
  single runner with QEMU; merge job stitches per-arch digests into a
  multi-arch manifest.

### Fixed

- `groupadd: GID '1000' already exists` — removed Ubuntu 24.04's
  pre-existing `ubuntu` user before creating our own (in the pre-root
  era).
- `/home/dev/.cache` permission-denied during `mise` — explicit chown
  + mkdir of the dotdirs (pre-root era).
- `corepack prepare pnpm --activate` ordering race — install pnpm
  directly via `npm install -g` instead of corepack + reshim.
- `flyctl` install leaking `$HOME/.fly` ownership into `/home/dev`
  during the root build — force `HOME=/root` for the installer.
- `obsidian-export` silent install failure — wrong asset URL pattern
  and no arm64 upstream build; switched to `obsidian-headless` (`ob`)
  which is the proper headless client and works on both archs.
- `FATAL: TS_AUTHKEY env var is required` — entrypoint now validates
  `HOSTNAME` and `TS_AUTHKEY` before any other work and dies
  immediately if missing.
- OrbStack terminal dropping users in `/` instead of `~/work` —
  `WORKDIR /root/work` in Dockerfile + `.zlogin` fallback.
- Stale `/root/.zshrc` on existing volumes keeping the
  `--dangerously-skip-permissions` alias after image updates — root
  cause is the `--ignore-existing` rsync, documented with the
  `rm /root/.zshrc && restart` fix in README.
- `claude --dangerously-skip-permissions` refusal as root — replaced
  with `~/.claude/settings.json` using `bypassPermissions` +
  `IS_SANDBOX=1`, no flag needed, works silently.

### Removed

- `setup.sh`, `build.sh`, `Dockerfile.old`, `entrypoint.old.sh`,
  `customer-a.docker-compose.yml`, `customer-b.docker-compose.yml` —
  legacy from the "base image + first-boot picker" model, superseded
  by the all-inclusive image.
- `/root/vault` folder from the image — users create their own
  subfolder inside `~/work` if they want one. Obsidian notes guidance
  slimmed to a link and a one-liner.
- `.env` / `.env.example` compose variables file — inline snippet in
  README is the canonical template; local `compose.yml` is gitignored.
