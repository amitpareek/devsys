# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

`devsys` — an all-inclusive Ubuntu dev container image published to
`ghcr.io/amitpareek/devsys:latest`. One image, one volume (`/root`),
auto-joins a Tailscale tailnet on boot. Deploys identically on local
Docker / OrbStack and Fly.io. The repo itself contains the image
source (`Dockerfile`, `entrypoint.sh`), the Fly.io deploy helpers
(`fly.toml`, `flysetup.sh`), a CI workflow, and docs. There is no app
code, no tests, no build system in the traditional sense — the
artifact is the container image.

## Common commands

Build image locally (for host arch; ~2 min with warm cache, ~5 min
cold):

```bash
docker build -t devsys:local .
```

Run a local container off your fresh build — needed env vars must be
set or the entrypoint dies immediately:

```bash
export HOSTNAME=devbox
export TS_AUTHKEY=tskey-auth-...
docker run -d --name "$HOSTNAME" --hostname "$HOSTNAME" \
  -e HOSTNAME -e TS_AUTHKEY \
  -v devsys-home:/root \
  devsys:local
docker exec -it "$HOSTNAME" zsh          # lands in /root/work
```

Smoke-test the baked tool set inside a throwaway container (simulates
first-boot seed then greps PATH):

```bash
docker run --rm --entrypoint /bin/bash devsys:local -c '
rsync -aq /etc/skel/devsys/ /root/
for t in node npm pnpm bun python3 mise gh fly neonctl claude gemini codex opencode ob psql redis-server tailscale; do
  command -v "$t" >/dev/null && echo "ok $t" || echo "MISSING $t"
done
'
```

Deploy to Fly.io (interactive, patches `fly.toml` in place, idempotent):

```bash
./flysetup.sh
```

Pull + recreate an already-deployed box after an image update:

```bash
# local
docker compose pull && docker compose up -d --force-recreate
# fly
fly deploy -a <app> --ha=false --now
```

Inspect CI:

```bash
gh run list --repo amitpareek/devsys --limit 5
```

## Architecture

### The image is its own filesystem lifecycle

The Dockerfile installs **every runtime, CLI, and service** into
`/root` (runtimes via mise, AI CLIs via `npm install -g`, shell config
in `.zshrc` / `.zlogin` / `.zshenv`, plus AI-CLI auto-approve configs
at `~/.claude/settings.json`, `~/.codex/config.toml`,
`~/.gemini/settings.json`). Right before `ENTRYPOINT`, the build step
**moves** `/root` to `/etc/skel/devsys` and leaves `/root` empty:

```dockerfile
RUN mv /root /etc/skel/devsys && install -d -m 700 /root
```

At container runtime, the user's persistent volume is mounted at
`/root` (empty on first boot). The entrypoint then rsyncs
`/etc/skel/devsys/` → `/root/` with `--ignore-existing`:

- **First boot**: full ~1.9 GB copy, `.devsys-seeded` sentinel written.
- **Subsequent boots**: metadata-only walk, new files from image
  updates land, user-edited files are preserved (never overwritten).

This pattern means **users get image upgrades transparently** without
losing their shell history, tailscale state, AI auth, or `~/work`
files. It also means a stale file on the volume (e.g. an alias that
was later removed from the image) won't get refreshed until manually
deleted — documented in README's "Upgrading" section.

### Runs as root, deliberately

Every access path — `docker exec`, OrbStack UI terminal, `tailscale
ssh root@host`, `fly ssh console` — lands as root in `/root/work`
with the same PATH. This was a deliberate choice to avoid the "dev
vs root" drift we hit earlier (fly's hallpass SSH always lands as
root). The security argument for non-root doesn't apply here: the
container is tailnet-only, single-owner, not multi-tenant.

The tricky consequence is that `claude-code` refuses
`--dangerously-skip-permissions` as root. Workaround baked into the
image: `~/.claude/settings.json` sets `defaultMode:
"bypassPermissions"` + `env.IS_SANDBOX=1` (Claude's container-sandbox
escape hatch). Codex and Gemini don't have this root-check, so
they're aliased with `--dangerously-bypass-approvals-and-sandbox` and
`--yolo` respectively in `.zshrc`.

### Entrypoint parallelism

`entrypoint.sh` validates `HOSTNAME` + `TS_AUTHKEY` first, then
**forks the seed rsync into the background** and starts tailscaled
immediately. Tailnet reachability in ~30 s on first boot instead of
waiting for the ~1.9 GB copy. Tailscaled's stdout is piped to the
container's stdout (not a log file) so `docker logs` / `fly logs`
shows everything.

A few state dirs are kept under `/root/.local/state/` (tailscale,
redis) so they persist in the volume. Tailscaled starts directly —
no chown dance needed because everything in /root is root-owned.

### `WORKDIR /root/work`

Last image instruction. Makes `docker exec` / OrbStack's terminal /
fly ssh / any container spawn land in `/root/work` without relying on
shell startup files. Critical because OrbStack's injected
`/nix/orb/sys/bin/zsh` ignores our `.zshrc`'s `cd ~/work`. The
`.zlogin` cd is a secondary fallback for shells that do read startup
files but run in an odd order.

### flysetup.sh

Interactive one-shot deploy. Prompts in order: fly org (auto-detected
from `fly orgs list`), hostname (validated `[a-z0-9_]`), region
(numbered picker), volume size, `TS_AUTHKEY` (visible read — silent
read breaks paste in many terminals; env-provided `TS_AUTHKEY` skips
the prompt). Derives `APP_NAME=<org>-devsys-<hostname>` (fly names are
globally unique) and `VOL_NAME=devsys_<hostname>_vol` (fly volume
charset is `[a-z0-9_]`). Patches `fly.toml` in place (backup at
`fly.toml.bak`, gitignored), then runs `fly apps create` → `fly
volumes create` → `fly secrets set` → `fly deploy --ha=false --now`,
with a post-deploy sweep that destroys and redeploys any machine
stuck in the `created` state.

Each step is idempotent: existing fly app prompts
`[r]edeploy/[d]elete+recreate`, existing volume prompts
`[k]eep/[d]elete+recreate`, both require typing the name to confirm
destroy.

### CI (`.github/workflows/docker.yml`)

Path-filtered: **only fires** on changes to `Dockerfile`,
`entrypoint.sh`, or the workflow itself. README / fly.toml /
flysetup.sh edits do **not** trigger a rebuild.

Builds per-arch on **native runners** (`ubuntu-24.04` for amd64,
`ubuntu-24.04-arm` for arm64) with per-arch GHA cache scopes, then a
separate `merge` job stitches the digests into a multi-arch manifest
tagged `:latest`. Avoids QEMU emulation, ~10 min → ~3 min.

## Workflow conventions

> **Every change lands in `CHANGES.md`. No exceptions.** Whenever you
> edit any file in this repo — Dockerfile, scripts, docs, workflow,
> even a typo fix — append an entry to the `## [Unreleased]` block at
> the top of [CHANGES.md](./CHANGES.md) in the same commit. Use the
> Keep a Changelog convention: `Added` / `Changed` / `Fixed` /
> `Removed` subsections. When a version is cut, the `[Unreleased]`
> block gets promoted to a dated heading `## YYYY-MM-DD — title`.
> This is how future sessions know what happened without re-reading
> the git log.

**Push directly to `main`** — single contributor, no PR overhead. CI
handles the publish. If a change is image-affecting, CI builds and
pushes `ghcr.io/amitpareek/devsys:latest` in ~3 min; otherwise it
skips.

**When you change `Dockerfile` or `entrypoint.sh`, rebuild locally
and smoke-test before pushing.** The smoke-test snippet earlier in
this file catches most "did I break a tool" regressions. CI will
catch build failures but not "tool X silently stopped resolving."

**Watch out for the `--ignore-existing` rsync.** Baked files that get
changed in the image don't refresh on existing volumes. If you remove
an alias from the baked `.zshrc` or fix a config file, mention in
the commit + CHANGES.md that existing deployments need to `rm` the
stale file and restart. Don't change to a clobbering rsync — we
deliberately preserve user edits.

**Don't commit `compose.yml`, `fly.toml.bak`, or `.env`.** They're
gitignored for a reason (user-specific deploy state with secrets).
The canonical compose template lives in the README as a code block.

Human-facing docs live in [README.md](./README.md); the per-release
log is [CHANGES.md](./CHANGES.md).
