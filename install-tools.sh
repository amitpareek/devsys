#!/usr/bin/env bash
#
# install-tools.sh — install the devsys tool set on a Debian/Ubuntu box,
# one group at a time.
#
# Installs SYSTEM-WIDE (/usr/local, /opt, /etc) so every user on the box
# gets the tools. Needs root. Per-tool logins stay per-user — the login
# check at the end targets whoever invoked sudo, not root.
#
# Usage:
#   ./install-tools.sh                   # arrow-key picker, space to toggle
#   ./install-tools.sh --list            # show groups and what's in them
#   ./install-tools.sh node dotnet       # install specific groups
#   ./install-tools.sh all               # everything except opt-in groups
#   ./install-tools.sh --dry-run all     # print what would happen
#   ./install-tools.sh --check-logins    # just re-run the auth check
#
# One-liner from anywhere. Download-then-run rather than `curl | bash`:
# piping consumes stdin and the picker could not read your keys, and
# `sudo bash <(curl ...)` can't reach the process-substitution fd.
#
#   curl -fsSL https://raw.githubusercontent.com/amitpareek/devsys/main/install-tools.sh -o /tmp/devsys-install.sh \
#     && sudo bash /tmp/devsys-install.sh
#
# Re-running is safe — every step checks first and only fills in gaps.

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/amitpareek/devsys/main"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MARKER="# >>> devsys env >>>"
MARKER_END="# <<< devsys env <<<"

# ---- system-wide layout ----------------------------------------------------
BIN_DIR="/usr/local/bin"
CONF_DIR="/etc/devsys"
ENV_FILE="$CONF_DIR/env.sh"
RC_FILE="$CONF_DIR/rc.zsh"
YOLO_FILE="$CONF_DIR/yolo.zsh"
MISE_DIR="/opt/mise"
MISE_CONF="/etc/mise/config.toml"
BUN_DIR="/opt/bun"
FLY_DIR="/opt/fly"
DOTNET_DIR="/usr/share/dotnet"
NPM_PREFIX="/usr/local"

DRY_RUN=0
ASSUME_YES=0
CHECK_ONLY=0
APT_UPDATED=0

# ---------------------------------------------------------------- output ----

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YLW=$'\033[33m'
  RED=$'\033[31m'; CYN=$'\033[36m'; R=$'\033[0m'
else
  B=''; DIM=''; GRN=''; YLW=''; RED=''; CYN=''; R=''
fi

# Raw ANSI rather than tput — ncurses-bin isn't guaranteed on a minimal box.
CUR_HIDE=$'\033[?25l'; CUR_SHOW=$'\033[?25h'; CLR_LINE=$'\033[2K'
cursor_up() { printf '\033[%dA' "$1"; }

step() { printf '\n%s==>%s %s%s%s\n' "$CYN" "$R" "$B" "$*" "$R"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$GRN" "$R" "$*"; }
skip() { printf '    %s·%s %s %s(already present)%s\n' "$DIM" "$R" "$*" "$DIM" "$R"; }
warn() { printf '%s!%s  %s\n' "$YLW" "$R" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s$ %s%s\n' "$DIM" "$*" "$R"
  else
    "$@"
  fi
}

# Shell-quoted variant, for the few steps that need a real pipeline.
runsh() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s$ %s%s\n' "$DIM" "$1" "$R"
  else
    bash -c "$1"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# Make a directory usable for the rest of THIS run. env.sh only adds dirs
# that already exist, so anything created mid-run (mise shims, bun, dotnet)
# has to be spliced into PATH here too — otherwise a later group can't see
# the binaries the previous group just installed.
path_prepend() {
  local d="$1"
  [ -d "$d" ] || return 0
  case ":$PATH:" in
    *":$d:"*) ;;
    *) PATH="$d:$PATH"; export PATH ;;
  esac
}

# ------------------------------------------------------------- platform ----

OS_ID=""
OS_CODENAME=""

detect_os() {
  [ -r /etc/os-release ] || die "cannot read /etc/os-release — is this Linux?"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) : ;;
    *) die "this script targets Debian/Ubuntu (found ID=${ID:-?}). Nothing was changed." ;;
  esac
  # Docker's repo is keyed on the upstream distro, not a derivative's name.
  case "$OS_ID" in
    ubuntu) DOCKER_DISTRO=ubuntu ;;
    debian) DOCKER_DISTRO=debian ;;
    *)
      case "${ID_LIKE:-}" in
        *ubuntu*) DOCKER_DISTRO=ubuntu ;;
        *)        DOCKER_DISTRO=debian ;;
      esac
      ;;
  esac
  [ -n "$OS_CODENAME" ] || OS_CODENAME="$(lsb_release -cs 2>/dev/null || true)"
}

# Everything lands in system paths, so root is non-negotiable. We don't
# re-exec under sudo: this script is often run as `bash <(curl ...)`, and
# sudo cannot reopen that process-substitution fd.
require_root() {
  [ "$(id -u)" = 0 ] && return 0
  die "must run as root — this installs system-wide so every user gets the tools.

       sudo $0 [groups...]
   or: curl -fsSL $REPO_RAW/install-tools.sh -o /tmp/devsys-install.sh && sudo bash /tmp/devsys-install.sh"
}

# The human behind the sudo, for per-user auth checks.
TARGET_USER=""
TARGET_HOME=""
resolve_target_user() {
  TARGET_USER="${SUDO_USER:-$(id -un)}"
  TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
  [ -n "$TARGET_HOME" ] || TARGET_HOME="${HOME:-/root}"
}

# Run a command as the invoking human, not root.
as_target() {
  if [ "$TARGET_USER" = "root" ] || [ "$TARGET_USER" = "$(id -un)" ]; then
    "$@"
  else
    sudo -u "$TARGET_USER" -H "$@"
  fi
}

apt_update_once() {
  [ "$APT_UPDATED" = 1 ] && return 0
  step "apt-get update"
  run apt-get update -qq
  APT_UPDATED=1
}

apt_install() {
  apt_update_once
  run env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends "$@"
}

# The bare minimum needed to fetch anything at all. tailscale installs before
# the `base` group, and a minbase Debian has no curl, so anything that reaches
# the network must call this first.
PREREQS_DONE=0
ensure_prereqs() {
  [ "$PREREQS_DONE" = 1 ] && return 0
  PREREQS_DONE=1
  if have curl && have gpg && [ -e /etc/ssl/certs/ca-certificates.crt ]; then
    return 0
  fi
  info "installing fetch prerequisites (ca-certificates, curl, gnupg)"
  apt_install ca-certificates curl gnupg
}

# Is a package installable from the currently configured repos?
# NOTE: deliberately pipe-free. `apt-cache policy | grep -q` looks obvious but
# is a nondeterministic trap under `set -o pipefail`: grep -q exits at the
# first match, apt-cache then dies of SIGPIPE, and pipefail reports the whole
# pipeline as failed — so a package that IS available reads as missing,
# depending purely on whether the output fit in the pipe buffer.
apt_has() {
  apt_update_once
  [ "$DRY_RUN" = 1 ] && return 0
  local out cand
  out="$(apt-cache policy "$1" 2>/dev/null || true)"
  case "$out" in *"Candidate:"*) ;; *) return 1 ;; esac
  cand="${out#*Candidate: }"
  cand="${cand%%$'\n'*}"
  case "$cand" in ''|"(none)"*) return 1 ;; *) return 0 ;; esac
}

# Install the first candidate that exists — for packages whose name carries
# a version (libicu72 on bookworm, libicu74 on noble, ...).
apt_install_first() {
  local p
  for p in "$@"; do
    if apt_has "$p"; then apt_install "$p"; return 0; fi
  done
  warn "none of these are available, skipping: $*"
  return 0
}

dpkg_arch() { dpkg --print-architecture; }

# add_apt_repo <name> <key-url> <deb-line>
add_apt_repo() {
  local name="$1" keyurl="$2" line="$3"
  local keyring="/etc/apt/keyrings/${name}.gpg"
  local list="/etc/apt/sources.list.d/${name}.list"
  if [ -f "$list" ] && [ -f "$keyring" ]; then
    skip "apt repo: $name"
    return 0
  fi
  ensure_prereqs
  info "adding apt repo: $name"
  run install -d -m 755 /etc/apt/keyrings
  runsh "curl -fsSL '$keyurl' | gpg --dearmor -o '$keyring'"
  runsh "printf '%s\n' '$line' > '$list'"
  run chmod go+r "$keyring"
  APT_UPDATED=0   # new repo — force another update before the next install
}

# ------------------------------------------------------------ env plumbing --

# Idempotently append a marker block to a system shell config file.
ensure_block() {
  local target="$1" body="$2"
  if [ "$DRY_RUN" = 1 ]; then info "would wire $target"; return 0; fi
  [ -e "$target" ] || { install -d -m 755 "$(dirname "$target")"; touch "$target"; }
  if grep -qF "$MARKER" "$target"; then
    skip "$target already wired up"
    return 0
  fi
  {
    printf '\n%s\n' "$MARKER"
    printf '%s\n' "$body"
    printf '%s\n' "$MARKER_END"
  } >>"$target"
  ok "wired $target"
}

write_env_file() {
  run install -d -m 755 "$CONF_DIR" "$BIN_DIR"
  if [ "$DRY_RUN" = 1 ]; then info "would write $ENV_FILE + profile hooks"; return 0; fi

  cat >"$ENV_FILE" <<ENVSH
# Written by devsys install-tools.sh — system-wide tool environment.
# Safe to edit; re-running the installer regenerates it.
export MISE_DATA_DIR="$MISE_DIR"
export MISE_GLOBAL_CONFIG_FILE="$MISE_CONF"
export BUN_INSTALL="$BUN_DIR"
[ -d "$DOTNET_DIR" ] && export DOTNET_ROOT="$DOTNET_DIR"

for _d in \\
  "$BIN_DIR" \\
  "$MISE_DIR/shims" \\
  "$BUN_DIR/bin" \\
  "$DOTNET_DIR" \\
  "\$HOME/.dotnet/tools"
do
  case ":\$PATH:" in
    *":\$_d:"*) ;;
    *) [ -d "\$_d" ] && PATH="\$_d:\$PATH" ;;
  esac
done
unset _d
export PATH

# Prefer micro, then nano, then vim. Never overrides an EDITOR you set.
if [ -z "\${EDITOR:-}" ]; then
  for _e in micro nano vim; do
    if command -v "\$_e" >/dev/null 2>&1; then export EDITOR="\$_e"; break; fi
  done
  unset _e
fi
if [ -n "\${EDITOR:-}" ] && [ -z "\${VISUAL:-}" ]; then
  export VISUAL="\$EDITOR"
fi

# Keep this last: sourcing must not exit non-zero, or callers running under
# \`set -e\` would abort on the final conditional above.
:
ENVSH
  chmod 644 "$ENV_FILE"
  ok "wrote $ENV_FILE"

  # sh/bash login shells.
  ensure_block /etc/profile.d/devsys.sh \
    "[ -f $ENV_FILE ] && . $ENV_FILE"
  chmod 644 /etc/profile.d/devsys.sh 2>/dev/null || true

  # zsh reads /etc/zsh/zshenv for every shell, and does NOT read
  # /etc/profile.d on its own.
  ensure_block /etc/zsh/zshenv \
    "[ -f $ENV_FILE ] && . $ENV_FILE"

  # Make the new PATH live for the rest of this run.
  # shellcheck disable=SC1090
  . "$ENV_FILE"
}

fetch_to() {
  local url="$1" dest="$2"
  run install -d -m 755 "$(dirname "$dest")"
  run curl -fsSL -o "$dest" "$url"
}

# ----------------------------------------------------------------- groups ---

# tailscale is deliberately FIRST: the usual flow is to get the box on the
# tailnet, hand it to a developer, and let them install the rest.
GROUP_ORDER=(
  tailscale
  base build editors cli shell
  mise node python dotnet
  docker cloud ai ai-yolo data notes auth
)

declare -A GROUP_DESC=(
  [base]="apt essentials — curl, wget, git, zsh, vim, unzip, rsync, ssh client, net tools, jq"
  [build]="compiler toolchain — build-essential, pkg-config, system python3 + venv + pip"
  [editors]="nano + micro (ctrl+s/ctrl+q, mouse, syntax highlighting); sets \$EDITOR"
  [cli]="modern CLI kit — ripgrep, fd, bat, fzf, eza, htop, ncdu, glow, lazygit"
  [shell]="zsh setup — starship prompt, direnv, tmux (mouse on), z session picker, aliases"
  [mise]="mise version manager (shared runtime store in $MISE_DIR)"
  [node]="JS/TS — node@lts, npm, pnpm, bun"
  [python]="Python 3.12 via mise (separate from the system python3)"
  [dotnet]=".NET SDK (LTS channel) + runtime deps; dotnet on PATH"
  [docker]="Docker CE engine + CLI, buildx and compose v2 plugins"
  [cloud]="gh (GitHub), flyctl (Fly.io), neonctl (Neon)"
  [ai]="AI coding CLIs — claude, gemini, codex, opencode"
  [ai-yolo]="auto-approve configs for the AI CLIs — DANGEROUS outside a throwaway box"
  [data]="redis-server, postgresql-client (psql)"
  [notes]="obsidian-headless (ob)"
  [tailscale]="tailscale + tailscaled via the official installer"
  [auth]="devsys-auth — move tool logins between your machines as an encrypted bundle"
)

# node/python need mise; the npm-based CLIs need node.
declare -A GROUP_DEPS=(
  [build]="base"
  [editors]="base"
  [cli]="base"
  [shell]="base"
  [mise]="base"
  [node]="base mise"
  [python]="base mise"
  [dotnet]="base"
  [docker]="base"
  [cloud]="base node"
  [ai]="base node"
  [ai-yolo]="ai"
  [data]="base"
  [notes]="base node"
  [auth]="base"
)
# tailscale has NO deps on purpose — it must be installable first, before
# the full base group, so the box can be handed over early.

DEFAULT_GROUPS=(tailscale base build editors cli shell mise node python auth)

# Never pulled in by `all` — must be named explicitly.
OPT_IN_ONLY=(ai-yolo)

# ------------------------------------------------------------- installers --

install_base() {
  step "base"
  apt_install \
    ca-certificates curl wget gnupg lsb-release \
    git vim less zsh bash \
    unzip rsync jq \
    iputils-ping net-tools dnsutils openssh-client
  write_env_file
  ok "base packages"
}

install_build() {
  step "build"
  apt_install build-essential pkg-config python3 python3-pip python3-venv
  ok "build toolchain"
}

install_editors() {
  step "editors"
  apt_install nano micro
  ok "nano + micro"
  # base already brings vim; EDITOR is set in env.sh so git/crontab use it.
}

install_cli() {
  step "cli"
  apt_install ripgrep fd-find bat fzf htop ncdu

  # Debian/Ubuntu ship these under alternate names.
  if [ "$DRY_RUN" = 0 ]; then
    have fdfind && ln -sf "$(command -v fdfind)" "$BIN_DIR/fd"
    have batcat && ln -sf "$(command -v batcat)" "$BIN_DIR/bat"
  fi

  # eza is in Debian 13+/Ubuntu 24.10+; older releases need the gierens repo.
  if have eza; then
    skip "eza"
  elif apt_has eza; then
    apt_install eza; ok "eza (distro package)"
  else
    add_apt_repo gierens \
      "https://raw.githubusercontent.com/eza-community/eza/main/deb.asc" \
      "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main"
    apt_install eza; ok "eza (gierens repo)"
  fi

  if have glow; then
    skip "glow"
  elif apt_has glow; then
    apt_install glow; ok "glow (distro package)"
  else
    add_apt_repo charm \
      "https://repo.charm.sh/apt/gpg.key" \
      "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *"
    apt_install glow; ok "glow (charm repo)"
  fi

  install_lazygit
}

install_lazygit() {
  if have lazygit; then skip "lazygit"; return 0; fi
  local arch lg_arch ver tmp
  arch="$(dpkg_arch)"
  case "$arch" in
    arm64) lg_arch=arm64 ;;
    amd64) lg_arch=x86_64 ;;
    *) warn "lazygit: unsupported arch $arch — skipping"; return 0 ;;
  esac
  if [ "$DRY_RUN" = 1 ]; then
    info "would download latest lazygit for Linux_$lg_arch into $BIN_DIR"
    return 0
  fi
  ver="$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest \
        | grep -oP '"tag_name": *"v\K[^"]+')" || die "lazygit: could not resolve latest version"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/lazygit.tgz" \
    "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${ver}_Linux_${lg_arch}.tar.gz"
  tar -xzf "$tmp/lazygit.tgz" -C "$tmp" lazygit
  install -m 755 "$tmp/lazygit" "$BIN_DIR/lazygit"
  rm -rf "$tmp"
  ok "lazygit $ver"
}

install_shell() {
  step "shell"
  apt_install direnv tmux

  if have starship; then
    skip "starship"
  else
    runsh "curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir '$BIN_DIR'"
    ok "starship"
  fi

  # z — tmux session/window picker from this repo.
  if [ -f "$BIN_DIR/z" ]; then
    skip "z"
  elif [ -f "$SCRIPT_DIR/z.sh" ]; then
    run install -m 755 "$SCRIPT_DIR/z.sh" "$BIN_DIR/z"
    ok "z (from local checkout)"
  else
    fetch_to "$REPO_RAW/z.sh" "$BIN_DIR/z"
    run chmod 755 "$BIN_DIR/z"
    ok "z (fetched)"
  fi

  # System tmux config — appended, so an existing /etc/tmux.conf survives.
  if [ "$DRY_RUN" = 1 ]; then
    info "would ensure 'set -g mouse on' in /etc/tmux.conf"
  elif [ -f /etc/tmux.conf ] && grep -qE '^set -g mouse' /etc/tmux.conf; then
    skip "tmux mouse mode"
  else
    printf 'set -g mouse on\n' >>/etc/tmux.conf
    ok "tmux mouse mode"
  fi

  write_shell_rc
}

write_shell_rc() {
  run install -d -m 755 "$CONF_DIR"
  if [ "$DRY_RUN" = 1 ]; then
    info "would write $RC_FILE and wire /etc/zsh/zshrc"
    return 0
  fi
  cat >"$RC_FILE" <<'RCZSH'
# Written by devsys install-tools.sh — interactive zsh setup, system-wide.
HISTSIZE=10000
SAVEHIST=10000
[ -n "$HISTFILE" ] || HISTFILE="$HOME/.zsh_history"
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE

eval "$(mise activate zsh 2>/dev/null || true)"
eval "$(direnv hook zsh 2>/dev/null || true)"
eval "$(starship init zsh 2>/dev/null || true)"

command -v eza     >/dev/null && alias ls='eza --group-directories-first'
command -v eza     >/dev/null && alias ll='eza -lah --group-directories-first --git'
command -v eza     >/dev/null && alias tree='eza --tree'
command -v bat     >/dev/null && alias cat='bat --paging=never'
command -v lazygit >/dev/null && alias lg='lazygit'

# Written separately by the ai-yolo group, so regenerating this file
# (i.e. re-running the 'shell' group) never drops those aliases.
[ -f /etc/devsys/yolo.zsh ] && . /etc/devsys/yolo.zsh
:
RCZSH
  chmod 644 "$RC_FILE"
  ok "wrote $RC_FILE"
  ensure_block /etc/zsh/zshrc "[ -f $RC_FILE ] && . $RC_FILE"
}

install_mise() {
  step "mise"
  if have mise; then
    skip "mise"
  else
    # mise.run honours MISE_INSTALL_PATH for a fixed system-wide location.
    runsh "curl -fsSL https://mise.run | MISE_INSTALL_PATH='$BIN_DIR/mise' sh"
    ok "mise -> $BIN_DIR/mise"
  fi
  run install -d -m 755 "$MISE_DIR" "$(dirname "$MISE_CONF")"
  # Shared store means every user resolves the same runtimes; without this
  # the config would land in root's home and nobody else would see it.
  if [ "$DRY_RUN" = 0 ]; then
    [ -f "$MISE_CONF" ] || printf '[tools]\n' >"$MISE_CONF"
    chmod 644 "$MISE_CONF"
    mise trust --quiet "$MISE_CONF" 2>/dev/null || true
  fi
  ok "shared runtime store at $MISE_DIR"
}

# mise_use <tool@version> — install into the shared store and reshim.
mise_use() {
  if [ "$DRY_RUN" = 1 ]; then info "would run: mise use --global --yes $1"; return 0; fi
  MISE_DATA_DIR="$MISE_DIR" MISE_GLOBAL_CONFIG_FILE="$MISE_CONF" \
    mise use --global --yes "$1"
  MISE_DATA_DIR="$MISE_DIR" MISE_GLOBAL_CONFIG_FILE="$MISE_CONF" mise reshim
  # Shims must be readable/executable by everyone, not just root.
  chmod -R a+rX "$MISE_DIR" 2>/dev/null || true
  # The shims dir is created by the first install, so PATH needs it now.
  path_prepend "$MISE_DIR/shims"
  ok "$1"
}

install_node() {
  step "node"
  mise_use node@lts

  # npm globals go to /usr/local so every user gets the binaries.
  if [ "$DRY_RUN" = 0 ]; then
    npm config set prefix "$NPM_PREFIX" --global 2>/dev/null || true
  fi

  if have pnpm; then skip "pnpm"; else npm_global pnpm; fi

  if have bun; then
    skip "bun"
  else
    runsh "export BUN_INSTALL='$BUN_DIR'; curl -fsSL https://bun.sh/install | bash"
    if [ "$DRY_RUN" = 0 ] && [ -x "$BUN_DIR/bin/bun" ]; then
      ln -sf "$BUN_DIR/bin/bun"  "$BIN_DIR/bun"
      ln -sf "$BUN_DIR/bin/bunx" "$BIN_DIR/bunx"
      chmod -R a+rX "$BUN_DIR" 2>/dev/null || true
    fi
    ok "bun"
  fi
}

install_python() {
  step "python"
  mise_use python@3.12
}

install_dotnet() {
  step "dotnet"
  # .NET needs ICU + OpenSSL; the versioned package name differs per release.
  apt_install_first libicu76 libicu74 libicu72 libicu70
  apt_install_first libssl3t64 libssl3
  apt_install zlib1g libgcc-s1 libstdc++6 tzdata

  if have dotnet; then
    skip "dotnet ($(dotnet --version 2>/dev/null || echo present))"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "would run dotnet-install.sh --channel LTS --install-dir $DOTNET_DIR"
    info "would symlink $BIN_DIR/dotnet and export DOTNET_ROOT"
    return 0
  fi
  # dotnet-install.sh over the Microsoft apt feed: one path that works on
  # both amd64 and arm64, and on Debian and Ubuntu alike.
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$tmp/dotnet-install.sh"
  bash "$tmp/dotnet-install.sh" --channel LTS --install-dir "$DOTNET_DIR" --no-path
  rm -rf "$tmp"
  ln -sf "$DOTNET_DIR/dotnet" "$BIN_DIR/dotnet"
  chmod -R a+rX "$DOTNET_DIR" 2>/dev/null || true
  # DOTNET_ROOT is exported by env.sh once the directory exists.
  ok "dotnet $("$DOTNET_DIR/dotnet" --version 2>/dev/null || echo 'LTS')"
  info "global tools install per-user to ~/.dotnet/tools (already on PATH)"
}

# Docker publishes per-suite. A brand-new distro release often isn't there
# yet, so probe before trusting $OS_CODENAME and say so plainly if it's
# missing rather than letting apt fail with a 404 nobody can read.
docker_suite() {
  local base="https://download.docker.com/linux/$DOCKER_DISTRO/dists"
  local fallback c
  case "$DOCKER_DISTRO" in
    debian) fallback=trixie ;;
    *)      fallback=noble  ;;
  esac
  for c in "$OS_CODENAME" "$fallback"; do
    [ -n "$c" ] || continue
    if curl -fsI --max-time 20 "$base/$c/Release" >/dev/null 2>&1; then
      [ "$c" = "$OS_CODENAME" ] || \
        warn "Docker has no '$OS_CODENAME' suite yet — using '$c' packages instead"
      printf '%s\n' "$c"
      return 0
    fi
  done
  die "Docker publishes no repo for '$OS_CODENAME' (nor fallback '$fallback').
       Install Docker manually, or use your distro's docker.io package."
}

install_docker() {
  step "docker"
  if have docker && docker --version >/dev/null 2>&1; then
    skip "docker ($(docker --version 2>/dev/null))"
  else
    local suite
    if [ "$DRY_RUN" = 1 ]; then suite="$OS_CODENAME"; else suite="$(docker_suite)"; fi
    add_apt_repo docker \
      "https://download.docker.com/linux/$DOCKER_DISTRO/gpg" \
      "deb [arch=$(dpkg_arch) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$DOCKER_DISTRO $suite stable"
    apt_install docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
    ok "docker-ce + buildx + compose v2"
  fi

  # Group membership is what makes docker usable without sudo. It also
  # grants effective root, so this is opt-in rather than automatic.
  if [ "$TARGET_USER" = "root" ]; then
    info "running as root, no docker group change needed"
    return 0
  fi
  # Same pipefail trap as apt_has — keep this pipe-free.
  if case " $(id -nG "$TARGET_USER" 2>/dev/null) " in *" docker "*) true ;; *) false ;; esac; then
    skip "$TARGET_USER already in the docker group"
    return 0
  fi
  warn "membership of the 'docker' group grants effective root on this host."
  if confirm "Add $TARGET_USER to the docker group?"; then
    run usermod -aG docker "$TARGET_USER"
    ok "added $TARGET_USER to docker — log out and back in (or run: newgrp docker)"
  else
    info "skipped — use 'sudo docker', or add the group later with:"
    info "  sudo usermod -aG docker $TARGET_USER"
  fi
}

# npm_global <pkg...> — installs to $NPM_PREFIX so all users get the binary.
npm_global() {
  have npm || die "npm not found — install the 'node' group first"
  run npm install -g --prefix "$NPM_PREFIX" "$@"
  ok "npm -g: $*"
}

install_cloud() {
  step "cloud"

  if have gh; then
    skip "gh"
  else
    add_apt_repo github-cli \
      "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
      "deb [arch=$(dpkg_arch) signed-by=/etc/apt/keyrings/github-cli.gpg] https://cli.github.com/packages stable main"
    apt_install gh
    ok "gh"
  fi

  if have flyctl; then
    skip "flyctl"
  else
    runsh "export FLYCTL_INSTALL='$FLY_DIR'; curl -fsSL https://fly.io/install.sh | sh"
    if [ -x "$FLY_DIR/bin/flyctl" ] || [ "$DRY_RUN" = 1 ]; then
      run ln -sf "$FLY_DIR/bin/flyctl" "$BIN_DIR/flyctl"
      run ln -sf "$FLY_DIR/bin/flyctl" "$BIN_DIR/fly"
      if [ "$DRY_RUN" = 0 ]; then chmod -R a+rX "$FLY_DIR" 2>/dev/null || true; fi
      ok "flyctl (+ 'fly' alias)"
    else
      warn "flyctl installed but $FLY_DIR/bin/flyctl not found"
    fi
  fi

  if have neonctl; then skip "neonctl"; else npm_global neonctl; fi
}

install_ai() {
  step "ai"
  local pending=() pkg bin
  while read -r pkg bin; do
    if have "$bin"; then skip "$bin"; else pending+=("$pkg"); fi
  done <<'PKGS'
@anthropic-ai/claude-code claude
@google/gemini-cli gemini
@openai/codex codex
opencode-ai opencode
PKGS
  if [ ${#pending[@]} -eq 0 ]; then
    info "all AI CLIs already present"
  else
    npm_global "${pending[@]}"
  fi
}

install_ai_yolo() {
  step "ai-yolo"
  warn "This writes auto-approve configs that let the AI CLIs run any command"
  warn "without asking. Only sane on a disposable, single-owner box."
  if [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    printf '    type %syolo%s to confirm: ' "$B" "$R"
    local ans; read -r ans
    [ "$ans" = "yolo" ] || { warn "skipped ai-yolo"; return 0; }
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "would write $TARGET_HOME/.claude/settings.json, .codex/config.toml, .gemini/settings.json"
    info "would write codex/gemini yolo aliases to $YOLO_FILE"
    return 0
  fi

  # These are per-user configs — write them for the human, not root.
  write_user_json "$TARGET_HOME/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "defaultMode": "bypassPermissions",
    "deny": []
  },
  "env": {
    "IS_SANDBOX": "1"
  }
}
JSON

  write_user_json "$TARGET_HOME/.codex/config.toml" <<'TOML'
approval_policy = "never"
sandbox_mode    = "danger-full-access"
TOML

  write_user_json "$TARGET_HOME/.gemini/settings.json" <<'JSON'
{
  "general": {
    "defaultApprovalMode": "auto_edit"
  }
}
JSON

  install -d -m 755 "$CONF_DIR"
  cat >"$YOLO_FILE" <<'RCZSH'
# Written by devsys install-tools.sh (ai-yolo group). Delete this file to
# turn flag-based auto-approve back off.
alias codex='codex --dangerously-bypass-approvals-and-sandbox'
alias gemini='gemini --yolo'
RCZSH
  chmod 644 "$YOLO_FILE"
  ok "wrote $YOLO_FILE"

  if [ ! -f "$RC_FILE" ]; then
    warn "the 'shell' group isn't installed, so $YOLO_FILE won't be sourced."
  fi
}

# write_user_json <path> — writes stdin, never overwriting, owned by the human.
write_user_json() {
  local path="$1" owner_group
  if [ -e "$path" ]; then
    cat >/dev/null   # drain the heredoc
    skip "$path exists — left alone"
    return 0
  fi
  install -d -m 700 "$(dirname "$path")"
  cat >"$path"
  chmod 600 "$path"
  owner_group="$(id -gn "$TARGET_USER" 2>/dev/null || echo "$TARGET_USER")"
  chown -R "$TARGET_USER:$owner_group" "$(dirname "$path")" 2>/dev/null || true
  ok "wrote $path (owner: $TARGET_USER)"
}

install_data() {
  step "data"
  apt_install redis-server postgresql-client
  ok "redis-server + psql"
}

install_notes() {
  step "notes"
  if have ob; then skip "obsidian-headless (ob)"; else npm_global obsidian-headless; fi
}

install_auth() {
  step "auth"
  apt_install age
  if [ -f "$SCRIPT_DIR/devsys-auth.sh" ]; then
    run install -m 755 "$SCRIPT_DIR/devsys-auth.sh" "$BIN_DIR/devsys-auth"
    ok "devsys-auth (from local checkout)"
  else
    fetch_to "$REPO_RAW/devsys-auth.sh" "$BIN_DIR/devsys-auth"
    run chmod 755 "$BIN_DIR/devsys-auth"
    ok "devsys-auth (fetched)"
  fi
  info "log in once on one box, then: ${B}devsys-auth export${R}"
  info "on the others: ${B}devsys-auth import <bundle.age>${R}"
}

install_tailscale() {
  step "tailscale"
  ensure_prereqs
  if have tailscale; then
    skip "tailscale"
  else
    runsh "curl -fsSL https://tailscale.com/install.sh | sh"
    ok "tailscale installed"
  fi

  [ "$DRY_RUN" = 1 ] && {
    info "would enable tailscaled at boot and offer to run 'tailscale up'"
    return 0
  }

  enable_tailscaled

  # Joining is interactive by design — you approve the node in the browser.
  if tailscale status >/dev/null 2>&1; then
    ok "already joined: $(tailscale status --peers=false 2>/dev/null | head -1)"
    return 0
  fi
  if confirm "Run 'tailscale up' now to join the tailnet?"; then
    tailscale up || warn "'tailscale up' did not complete — run it again later"
  else
    info "join later with: ${B}sudo tailscale up${R}"
  fi
}

# Survive a reboot. The official installer normally enables the unit, but
# don't assume — an unenabled tailscaled means the box silently drops off
# the tailnet after a restart, which is the worst way to find out.
enable_tailscaled() {
  if ! have systemctl || [ ! -d /run/systemd/system ]; then
    warn "no systemd here — tailscaled won't be started at boot by this script."
    info "in a container, tailscaled is started by the entrypoint instead."
    return 0
  fi

  if ! systemctl is-enabled tailscaled >/dev/null 2>&1; then
    run systemctl enable tailscaled
    ok "tailscaled enabled at boot"
  else
    skip "tailscaled already enabled at boot"
  fi

  if ! systemctl is-active tailscaled >/dev/null 2>&1; then
    run systemctl start tailscaled
    ok "tailscaled started"
  else
    skip "tailscaled already running"
  fi

  # Say plainly what the reboot behaviour now is, rather than implying it.
  local en ac
  en="$(systemctl is-enabled tailscaled 2>/dev/null || echo unknown)"
  ac="$(systemctl is-active  tailscaled 2>/dev/null || echo unknown)"
  info "tailscaled: ${B}enabled=$en active=$ac${R} — login state persists in /var/lib/tailscale"
}

# After tailscale is on, the box is reachable and can change hands. Offer to
# stop here so a developer can finish the install themselves.
handover_pause() {
  local remaining=("$@")
  [ ${#remaining[@]} -gt 0 ] || return 0
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || return 0

  printf '\n%s──%s %sTailscale is done — this box is now reachable.%s\n' \
    "$CYN" "$R" "$B" "$R"
  info "still to install: ${remaining[*]}"
  info "you can hand the VM over now and let the developer finish."
  printf '\n'
  if confirm "Continue installing the rest now?"; then
    return 0
  fi
  printf '\n'
  info "stopping here. To finish later, run on this box:"
  printf '\n      %ssudo %s %s%s\n\n' "$B" "$0" "${remaining[*]}" "$R"
  info "or just ${B}sudo $0${R} for the picker."
  printf '\n'
  exit 0
}

run_group() {
  case "$1" in
    base)      install_base ;;
    build)     install_build ;;
    editors)   install_editors ;;
    cli)       install_cli ;;
    shell)     install_shell ;;
    mise)      install_mise ;;
    node)      install_node ;;
    python)    install_python ;;
    dotnet)    install_dotnet ;;
    docker)    install_docker ;;
    cloud)     install_cloud ;;
    ai)        install_ai ;;
    ai-yolo)   install_ai_yolo ;;
    data)      install_data ;;
    notes)     install_notes ;;
    auth)      install_auth ;;
    tailscale) install_tailscale ;;
    *)         die "unknown group: $1" ;;
  esac
}

# --------------------------------------------------------- login checking ---
#
# Auth is per-user and easy to forget, so after installing we probe each
# tool that needs a login and offer to run it right there.
#
# Fields: tool|binary|probe command|login command|note
#
# SINGLE-QUOTED on purpose — $HOME must survive as a literal so the probe can
# be re-pointed at the invoking user's home rather than root's.
# shellcheck disable=SC2016
LOGIN_CHECKS=(
  'GitHub|gh|gh auth status|gh auth login|'
  'Fly.io|flyctl|flyctl auth whoami|flyctl auth login|'
  'Neon|neonctl|neonctl me|neonctl auth|'
  'Claude Code|claude|test -s $HOME/.claude/.credentials.json|claude|run once, follow the prompt'
  'Gemini CLI|gemini|test -s $HOME/.gemini/oauth_creds.json|gemini|run once, follow the prompt'
  'Codex CLI|codex|test -s $HOME/.codex/auth.json|codex login|'
  'opencode|opencode|test -s $HOME/.local/share/opencode/auth.json|opencode auth login|'
  'Tailscale|tailscale|tailscale status|tailscale up|needs sudo'
  'Docker Hub|docker|grep -qE "\"auths\"[[:space:]]*:[[:space:]]*\{[[:space:]]*\"" $HOME/.docker/config.json|docker login|only if you push images'
)
# NB: no field may contain a literal "|" — it is the field separator.

confirm() {
  local prompt="$1" ans
  [ "$ASSUME_YES" = 1 ] && return 0
  [ "$DRY_RUN" = 1 ] && return 1
  [ -t 0 ] || return 1
  printf '    %s%s%s [y/N] ' "$B" "$prompt" "$R"
  read -r ans
  case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

check_logins() {
  step "login check — for user: $TARGET_USER"

  local any=0 pending=()
  local entry name bin probe login note status
  for entry in "${LOGIN_CHECKS[@]}"; do
    IFS='|' read -r name bin probe login note <<<"$entry"
    have "$bin" || continue
    any=1

    # Probe as the human, with their HOME, quietly.
    if as_target env HOME="$TARGET_HOME" sh -c "${probe//\$HOME/$TARGET_HOME}" \
         >/dev/null 2>&1; then
      status="${GRN}logged in${R}"
    else
      status="${YLW}NOT logged in${R}"
      pending+=("$name|$login|$note")
    fi
    printf '    %-14s %b%s\n' "$name" "$status" \
      "$([ -n "$note" ] && printf ' %s(%s)%s' "$DIM" "$note" "$R")"
  done

  # Being logged in is worthless if the daemon won't come back after a reboot.
  if have tailscale && have systemctl && [ -d /run/systemd/system ]; then
    local en
    en="$(systemctl is-enabled tailscaled 2>/dev/null || echo unknown)"
    if [ "$en" = enabled ]; then
      printf '    %-14s %s%s%s\n' "tailscaled" "$GRN" "starts on boot" "$R"
    else
      printf '    %-14s %s%s%s %s(run: sudo systemctl enable --now tailscaled)%s\n' \
        "tailscaled" "$YLW" "NOT enabled at boot ($en)" "$R" "$DIM" "$R"
    fi
  fi

  if [ "$any" = 0 ]; then
    info "no tools needing a login are installed yet"
    return 0
  fi
  if [ ${#pending[@]} -eq 0 ]; then
    ok "everything is authenticated"
    return 0
  fi

  printf '\n'
  info "${B}${#pending[@]} tool(s) still need a login.${R}"
  local p pname plogin pnote
  for p in "${pending[@]}"; do
    IFS='|' read -r pname plogin pnote <<<"$p"
    printf '\n'
    info "$pname — ${B}$plogin${R}${pnote:+  $DIM($pnote)$R}"
    if confirm "Run it now as $TARGET_USER?"; then
      # Interactive on purpose: these flows need a browser code or paste.
      if [ "$pname" = "Tailscale" ]; then
        $plogin || warn "$pname login did not complete"
      else
        # Intentionally unquoted: $plogin is a multi-word command line.
        # shellcheck disable=SC2086
        as_target env HOME="$TARGET_HOME" $plogin || warn "$pname login did not complete"
      fi
    else
      info "skipped — run it later as $TARGET_USER"
    fi
  done
}

# ------------------------------------------------------------ selection ----

is_default() {
  local g="$1" d
  for d in "${DEFAULT_GROUPS[@]}"; do [ "$d" = "$g" ] && return 0; done
  return 1
}

is_opt_in_only() {
  local g="$1" o
  for o in "${OPT_IN_ONLY[@]}"; do [ "$o" = "$g" ] && return 0; done
  return 1
}

valid_group() {
  local g
  for g in "${GROUP_ORDER[@]}"; do [ "$g" = "$1" ] && return 0; done
  return 1
}

all_but_opt_in() {
  local g
  for g in "${GROUP_ORDER[@]}"; do
    is_opt_in_only "$g" || printf '%s\n' "$g"
  done
}

# append_lines <array-name> <text> — split text on newlines and append.
# Deliberately not `mapfile < <(cmd)`: process substitution needs /dev/fd,
# which is missing in minimal chroots and some CI images. Herestrings use
# a temp file and work anywhere.
append_lines() {
  local __name="$1" __text="$2" __line
  while IFS= read -r __line; do
    [ -n "$__line" ] || continue
    eval "$__name+=(\"\$__line\")"
  done <<<"$__text"
}

print_groups() {
  local i=1 g mark
  printf '\n%sdevsys tool groups%s %s(installed system-wide)%s\n\n' "$B" "$R" "$DIM" "$R"
  for g in "${GROUP_ORDER[@]}"; do
    mark=""
    is_default "$g"     && mark="${GRN}[default]${R}"
    is_opt_in_only "$g" && mark="${YLW}[opt-in]${R}"
    printf '  %s%2d%s  %s%-10s%s %s\n' "$B" "$i" "$R" "$CYN" "$g" "$R" "$mark"
    printf '      %s%s%s\n' "$DIM" "${GROUP_DESC[$g]}" "$R"
    i=$((i + 1))
  done
  printf '\n'
}

# Expand a selection into a dep-resolved, install-ordered list.
resolve() {
  local -A want=()
  local g dep queue=("$@")
  while [ ${#queue[@]} -gt 0 ]; do
    g="${queue[0]}"; queue=("${queue[@]:1}")
    [ -n "${want[$g]:-}" ] && continue
    want[$g]=1
    for dep in ${GROUP_DEPS[$g]:-}; do
      [ -n "${want[$dep]:-}" ] || queue+=("$dep")
    done
  done
  for g in "${GROUP_ORDER[@]}"; do
    [ -n "${want[$g]:-}" ] && printf '%s\n' "$g"
  done
}

# ---- arrow-key checkbox picker ---------------------------------------------

PICKED=()
declare -a CHECKED=()
PICK_CUR=0
PICK_COLS=80

pick_reset_defaults() {
  local i g
  for i in "${!GROUP_ORDER[@]}"; do
    g="${GROUP_ORDER[$i]}"
    if is_default "$g"; then CHECKED[i]=1; else CHECKED[i]=0; fi
  done
}

pick_set_all() {
  local i g want="$1"
  for i in "${!GROUP_ORDER[@]}"; do
    g="${GROUP_ORDER[$i]}"
    if [ "$want" = 1 ] && is_opt_in_only "$g"; then CHECKED[i]=0; else CHECKED[i]=$want; fi
  done
}

pick_render_row() {
  local i="$1" g box name desc pointer color avail
  g="${GROUP_ORDER[$i]}"
  if [ "${CHECKED[i]}" = 1 ]; then box="${GRN}[x]${R}"; else box="[ ]"; fi
  if [ "$i" = "$PICK_CUR" ]; then pointer="${B}${CYN}❯${R}"; else pointer=" "; fi
  if is_opt_in_only "$g"; then color="$YLW"; else color="$CYN"; fi
  name=$(printf '%-10s' "$g")
  avail=$((PICK_COLS - 21))
  [ "$avail" -lt 12 ] && avail=12
  desc="${GROUP_DESC[$g]}"
  if [ "${#desc}" -gt "$avail" ]; then desc="${desc:0:$((avail - 1))}…"; fi
  printf '  %s %s %s%s%s %s%s%s\n' \
    "$pointer" "$box" "$color" "$name" "$R" "$DIM" "$desc" "$R"
}

pick_hint() {
  printf '  %s↑↓%s move  %sspace%s toggle  %sa%s all  %sn%s none  %sd%s defaults  %s⏎%s install  %sq%s quit\n' \
    "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R"
}

pick_move() {
  local n=${#GROUP_ORDER[@]}
  PICK_CUR=$(( (PICK_CUR + $1 + n) % n ))
}

pick_interactive() {
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    die "the picker needs a terminal — name groups explicitly, e.g.
         sudo $0 node dotnet docker"
  fi

  PICK_COLS=$( (command -v tput >/dev/null && tput cols) 2>/dev/null || echo 80 )
  pick_reset_defaults
  PICK_CUR=0

  local n=${#GROUP_ORDER[@]}
  local nlines=$((n + 2))
  local key rest saved_stty
  saved_stty="$(stty -g 2>/dev/null || true)"
  restore_tty() {
    printf '%s' "$CUR_SHOW" >&2
    [ -n "$saved_stty" ] && stty "$saved_stty" 2>/dev/null || stty echo 2>/dev/null || true
  }
  trap 'restore_tty; exit 130' INT TERM
  trap 'restore_tty' EXIT
  stty -echo 2>/dev/null || true
  printf '%s' "$CUR_HIDE" >&2

  {
    printf '\n  %sdevsys tool groups%s  %sselect what to install (system-wide)%s\n\n' \
      "$B" "$R" "$DIM" "$R"
    local i
    for i in "${!GROUP_ORDER[@]}"; do pick_render_row "$i"; done
    printf '\n'; pick_hint
  } >&2

  while true; do
    IFS= read -rsn1 key || key=''
    if [ "$key" = $'\033' ]; then
      rest=''
      read -rsn2 -t 0.05 rest || true
      if [ -z "$rest" ]; then key='q'; else key="$rest"; fi
    fi
    case "$key" in
      '[A'|k) pick_move -1 ;;
      '[B'|j) pick_move 1 ;;
      ' ')
        if [ "${CHECKED[PICK_CUR]}" = 1 ]; then CHECKED[PICK_CUR]=0; else CHECKED[PICK_CUR]=1; fi
        ;;
      a|A) pick_set_all 1 ;;
      n|N) pick_set_all 0 ;;
      d|D) pick_reset_defaults ;;
      '')  break ;;
      q|Q)
        restore_tty; trap - EXIT INT TERM
        printf '\n  %saborted — nothing installed%s\n\n' "$DIM" "$R" >&2
        exit 0
        ;;
    esac
    {
      cursor_up "$nlines"
      local i
      for i in "${!GROUP_ORDER[@]}"; do printf '%s' "$CLR_LINE"; pick_render_row "$i"; done
      printf '%s\n' "$CLR_LINE"
      printf '%s' "$CLR_LINE"; pick_hint
    } >&2
  done

  restore_tty
  trap - EXIT INT TERM

  PICKED=()
  local i
  for i in "${!GROUP_ORDER[@]}"; do
    [ "${CHECKED[i]}" = 1 ] && PICKED+=("${GROUP_ORDER[$i]}")
  done
  if [ ${#PICKED[@]} -eq 0 ]; then
    printf '\n  %snothing selected — exiting%s\n\n' "$DIM" "$R" >&2
    exit 0
  fi
}

usage() {
  cat <<EOF
${B}install-tools.sh${R} — install the devsys tool set, by group, system-wide.

  sudo ./install-tools.sh                 arrow-key picker (space to toggle)
  sudo ./install-tools.sh --list          list groups and contents
  sudo ./install-tools.sh <group>...      install named groups (deps auto-added)
  sudo ./install-tools.sh all             everything except: ${OPT_IN_ONLY[*]}
  sudo ./install-tools.sh --check-logins  probe tool auth, offer to log in

Options:
  --dry-run        print the commands instead of running them
  -y, --yes        don't prompt for confirmation (implies yes to ai-yolo)
  --check-logins   only run the login check
  --no-login-check skip the login check after installing
  -l, --list       list groups and exit
  -h, --help       this text

Groups: ${GROUP_ORDER[*]}

Tools go to /usr/local, /opt and /etc so every user on the box gets them.
Logins stay per-user — the check targets \$SUDO_USER, not root.
EOF
}

# ------------------------------------------------------------------- main ---

SKIP_LOGIN_CHECK=0

main() {
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)        DRY_RUN=1 ;;
      -y|--yes)         ASSUME_YES=1 ;;
      --check-logins)   CHECK_ONLY=1 ;;
      --no-login-check) SKIP_LOGIN_CHECK=1 ;;
      -l|--list)        print_groups; exit 0 ;;
      -h|--help)        usage; exit 0 ;;
      -*)               die "unknown option: $1 (try --help)" ;;
      *)                args+=("$1") ;;
    esac
    shift
  done

  detect_os
  resolve_target_user

  if [ "$CHECK_ONLY" = 1 ]; then
    check_logins
    printf '\n'
    exit 0
  fi

  [ "$DRY_RUN" = 1 ] || require_root

  local selected=() g
  if [ ${#args[@]} -eq 0 ]; then
    pick_interactive
    selected=("${PICKED[@]}")
  else
    for g in "${args[@]}"; do
      if [ "$g" = "all" ]; then
        append_lines selected "$(all_but_opt_in)"
      else
        valid_group "$g" || die "unknown group: $g (try --list)"
        selected+=("$g")
      fi
    done
  fi
  [ ${#selected[@]} -gt 0 ] || die "nothing selected"

  local plan=()
  append_lines plan "$(resolve "${selected[@]}")"

  printf '\n%sPlan%s%s (deps resolved):%s %s\n' "$B" "$R" "$DIM" "$R" "${plan[*]}"
  printf '%sTarget:%s system-wide (%s, %s, %s) · logins for: %s\n' \
    "$DIM" "$R" "$BIN_DIR" "/opt" "$CONF_DIR" "$TARGET_USER"
  [ "$DRY_RUN" = 1 ] && printf '%s(dry run — nothing will be installed)%s\n' "$YLW" "$R"

  local i
  for i in "${!plan[@]}"; do
    g="${plan[$i]}"
    run_group "$g"
    # The handover point: everything after tailscale is the developer's job.
    if [ "$g" = tailscale ] && [ "$DRY_RUN" = 0 ]; then
      handover_pause "${plan[@]:$((i + 1))}"
    fi
  done

  step "done"
  info "installed groups: ${plan[*]}"
  info "open a new shell, or: ${B}exec zsh -l${R}"

  if [ "$DRY_RUN" = 0 ] && [ "$SKIP_LOGIN_CHECK" = 0 ]; then
    check_logins
  fi
  printf '\n'
}

main "$@"
