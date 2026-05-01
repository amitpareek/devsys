# Changelog

All notable changes to **devsys** (`ghcr.io/amitpareek/devsys`).
Dates are UTC. Format follows [Keep a Changelog](https://keepachangelog.com).

## [Unreleased]

### Added

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
