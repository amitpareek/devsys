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
BASH_RC_FILE="$CONF_DIR/rc.bash"
YOLO_FILE="$CONF_DIR/yolo.sh"
# Records exactly which config files ai-yolo created, so uninstalling removes
# only those and never a file someone wrote themselves.
YOLO_MANIFEST="$CONF_DIR/ai-yolo.manifest"
CLAUDE_MANAGED="/etc/claude-code/managed-settings.json"
GEMINI_SYSTEM="/etc/gemini-cli/settings.json"
ZSH_COMP_DIR="/usr/local/share/zsh/site-functions"
BASH_COMP_DIR="/etc/bash_completion.d"
MISE_DIR="/opt/mise"
MISE_CONF="/etc/mise/config.toml"
BUN_DIR="/opt/bun"
FLY_DIR="/opt/fly"
DOTNET_DIR="/usr/share/dotnet"
NPM_PREFIX="/usr/local"

# Flags every node joins with. --ssh gives tailnet SSH, --accept-dns uses the
# tailnet's DNS, --accept-routes picks up subnet routes advertised by others.
TS_FLAGS=(--ssh=true --accept-dns=true --accept-routes=true)

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
#
# Via `bash -lc`, deliberately. A bare `sudo -u user cmd` inherits sudo's
# secure_path, so /opt/mise/shims is absent and MISE_DATA_DIR is unset —
# which makes any npm-installed CLI die with
#   /usr/bin/env: 'node': No such file or directory
# because its shebang is `#!/usr/bin/env node`. A login shell sources
# /etc/profile.d/devsys.sh and therefore gets exactly the environment the
# user would get by logging in.
as_target() {
  if [ "$TARGET_USER" = "root" ] || [ "$TARGET_USER" = "$(id -un)" ]; then
    "$@"
    return $?
  fi
  local quoted
  quoted="$(printf '%q ' "$@")"
  sudo -u "$TARGET_USER" -H bash -lc "$quoted"
}

# Same, but takes a shell command string. Any $HOME inside it expands in the
# TARGET user's login shell, which is what the probe strings rely on.
as_target_sh() {
  if [ "$TARGET_USER" = "root" ] || [ "$TARGET_USER" = "$(id -un)" ]; then
    bash -lc "$1"
    return $?
  fi
  sudo -u "$TARGET_USER" -H bash -lc "$1"
}

# Adopt the PATH this script itself manages, before doing anything that looks
# at what's installed. Without this, status detection reflects the caller's
# PATH: sudo's secure_path has no /opt/mise/shims or /opt/bun/bin, so a fully
# installed `node` group would read as "partial" and unchecking it in the
# picker would trigger a bogus removal.
adopt_system_env() {
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE" || true
  fi
  path_prepend "$BIN_DIR"
  path_prepend "$MISE_DIR/shims"
  path_prepend "$BUN_DIR/bin"
  path_prepend "$DOTNET_DIR"
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
  "\${HOME:-}/.dotnet/tools"
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
  [ai-yolo]="auto-approve for the AI CLIs, ALL users — DANGEROUS outside a throwaway VM"
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

# Groups that must never be uninstalled. `base` provides curl, ca-certificates
# and gnupg — removing it would break this very script mid-run, and every other
# group depends on it, so unchecking it would cascade into wiping everything.
PROTECTED=(base)

is_protected() {
  local g="$1" p
  for p in "${PROTECTED[@]}"; do [ "$p" = "$g" ] && return 0; done
  return 1
}

# ---- what is already installed? --------------------------------------------
#
# One probe list per group. An entry starting with / is a path test, anything
# else is a command lookup. A group is "installed" when every probe passes,
# "partial" when some do, "missing" when none do.
declare -A GROUP_PROBE=(
  [tailscale]="tailscale"
  [base]="git jq zsh rsync /etc/devsys/env.sh"
  [build]="gcc pkg-config"
  [editors]="nano micro"
  [cli]="rg fd bat fzf htop ncdu eza glow lazygit"
  [shell]="starship direnv tmux /usr/local/bin/z /etc/devsys/rc.zsh /etc/devsys/rc.bash"
  [mise]="mise /opt/mise"
  [node]="node npm pnpm bun"
  [python]="/opt/mise/installs/python"
  [dotnet]="dotnet /usr/share/dotnet"
  [docker]="docker"
  [cloud]="gh flyctl neonctl"
  [ai]="claude gemini codex opencode"
  [ai-yolo]="/etc/devsys/yolo.sh"
  [data]="redis-server psql"
  [notes]="ob"
  [auth]="devsys-auth age"
)

declare -A STATUS=()

group_status() {
  local g="$1" c present=0 total=0
  for c in ${GROUP_PROBE[$g]:-}; do
    total=$((total + 1))
    case "$c" in
      /*) [ -e "$c" ] && present=$((present + 1)) ;;
      *)  have "$c" && present=$((present + 1)) ;;
    esac
  done
  if   [ "$total"   = 0 ]; then printf 'missing\n'
  elif [ "$present" = "$total" ]; then printf 'installed\n'
  elif [ "$present" = 0 ]; then printf 'missing\n'
  else printf 'partial\n'
  fi
}

scan_status() {
  local g
  for g in "${GROUP_ORDER[@]}"; do STATUS[$g]="$(group_status "$g")"; done
}

# Is this a box we've never touched? Used to decide whether the picker should
# start from the defaults or from what's actually on disk.
box_is_fresh() {
  local g
  for g in "${GROUP_ORDER[@]}"; do
    [ "${STATUS[$g]}" = missing ] || return 1
  done
  return 0
}

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
  apt_install direnv tmux bash-completion

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
  run install -d -m 755 "$CONF_DIR" "$ZSH_COMP_DIR" "$BASH_COMP_DIR"
  if [ "$DRY_RUN" = 1 ]; then
    info "would write $RC_FILE + $BASH_RC_FILE and wire zsh + bash"
    return 0
  fi

  # Aliases are identical in both shells, so keep one copy.
  cat >"$CONF_DIR/aliases.sh" <<'ALIASES'
# Written by devsys install-tools.sh — shared by zsh and bash.
command -v eza     >/dev/null 2>&1 && alias ls='eza --group-directories-first'
command -v eza     >/dev/null 2>&1 && alias ll='eza -lah --group-directories-first --git'
command -v eza     >/dev/null 2>&1 && alias tree='eza --tree'
command -v bat     >/dev/null 2>&1 && alias cat='bat --paging=never'
command -v lazygit >/dev/null 2>&1 && alias lg='lazygit'
:
ALIASES
  chmod 644 "$CONF_DIR/aliases.sh"

  cat >"$RC_FILE" <<'RCZSH'
# Written by devsys install-tools.sh — interactive zsh setup, system-wide.
HISTSIZE=10000
SAVEHIST=10000
[ -n "$HISTFILE" ] || HISTFILE="$HOME/.zsh_history"
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE

# Completions installed by the installer live here; compinit must run or
# none of them do anything. -i skips the insecure-directory prompt.
fpath=(/usr/local/share/zsh/site-functions $fpath)
autoload -Uz compinit && compinit -i -C 2>/dev/null || true

eval "$(mise activate zsh 2>/dev/null || true)"
eval "$(direnv hook zsh 2>/dev/null || true)"
eval "$(starship init zsh 2>/dev/null || true)"

# fzf ctrl-r / ctrl-t keybindings (Debian ships them as examples).
for _f in /usr/share/doc/fzf/examples/key-bindings.zsh \
          /usr/share/doc/fzf/examples/completion.zsh; do
  [ -r "$_f" ] && . "$_f"
done
unset _f

[ -f /etc/devsys/aliases.sh ] && . /etc/devsys/aliases.sh

# Written separately by the ai-yolo group, so regenerating this file
# (i.e. re-running the 'shell' group) never drops those aliases.
[ -f /etc/devsys/yolo.sh ] && . /etc/devsys/yolo.sh
:
RCZSH
  chmod 644 "$RC_FILE"
  ok "wrote $RC_FILE"

  cat >"$BASH_RC_FILE" <<'RCBASH'
# Written by devsys install-tools.sh — interactive bash setup, system-wide.
HISTSIZE=10000
HISTFILESIZE=10000
HISTCONTROL=ignoreboth
shopt -s histappend checkwinsize 2>/dev/null || true

# bash-completion, then anything the installer dropped in.
if ! shopt -oq posix; then
  [ -r /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion
fi

eval "$(mise activate bash 2>/dev/null || true)"
eval "$(direnv hook bash 2>/dev/null || true)"
eval "$(starship init bash 2>/dev/null || true)"

for _f in /usr/share/doc/fzf/examples/key-bindings.bash \
          /usr/share/doc/fzf/examples/completion.bash; do
  [ -r "$_f" ] && . "$_f"
done
unset _f

[ -f /etc/devsys/aliases.sh ] && . /etc/devsys/aliases.sh
[ -f /etc/devsys/yolo.sh ]    && . /etc/devsys/yolo.sh
:
RCBASH
  chmod 644 "$BASH_RC_FILE"
  ok "wrote $BASH_RC_FILE"

  ensure_block /etc/zsh/zshrc    "[ -f $RC_FILE ] && . $RC_FILE"
  ensure_block /etc/bash.bashrc  "[ -f $BASH_RC_FILE ] && . $BASH_RC_FILE"
}

# ---- shell completions -----------------------------------------------------
#
# Generated system-wide for whatever is installed, so nobody has to paste
# `eval "$(tool completion zsh)"` into their own rc file. Best-effort: a tool
# that has no completion subcommand is skipped quietly.
# Format: binary|command template with SHELL as the placeholder
COMPLETION_GENS=(
  'gh|gh completion -s SHELL'
  'mise|mise completion SHELL'
  'flyctl|flyctl completion SHELL'
  'starship|starship completions SHELL'
  'docker|docker completion SHELL'
  'tailscale|tailscale completion SHELL'
  'rclone|rclone completion SHELL'
)

install_completions() {
  step "shell completions"
  [ "$DRY_RUN" = 1 ] && { info "would generate zsh + bash completions for installed tools"; return 0; }

  install -d -m 755 "$ZSH_COMP_DIR" "$BASH_COMP_DIR"

  local entry bin tmpl sh out dest done_any=0
  for entry in "${COMPLETION_GENS[@]}"; do
    IFS='|' read -r bin tmpl <<<"$entry"
    have "$bin" || continue
    for sh in zsh bash; do
      out="$(${tmpl//SHELL/$sh} 2>/dev/null || true)"
      # A usable completion script is more than a line of noise.
      [ "$(printf '%s' "$out" | wc -c)" -gt 100 ] || continue
      if [ "$sh" = zsh ]; then dest="$ZSH_COMP_DIR/_$bin"; else dest="$BASH_COMP_DIR/$bin"; fi
      printf '%s\n' "$out" >"$dest"
      chmod 644 "$dest"
      done_any=1
    done
    ok "$bin"
  done

  # bun ships its own installer that writes into the zsh site-functions dir.
  if have bun; then
    SHELL=zsh bun completions >/dev/null 2>&1 || true
    ok "bun"
    done_any=1
  fi

  if [ "$done_any" = 0 ]; then
    info "nothing installed yet that provides completions"
  else
    info "zsh: $ZSH_COMP_DIR   bash: $BASH_COMP_DIR"
  fi
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

# ---- ai-yolo: system-wide auto-approve -------------------------------------
#
# Applies to EVERY user on the box, by request. Two mechanisms are needed:
# Claude Code and Gemini CLI read a system-level config, but Codex only ever
# reads $HOME/.codex, so its config is seeded into each home plus /etc/skel
# for accounts created later.

claude_yolo_json() {
  cat <<'JSON'
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
}

codex_yolo_toml() {
  cat <<'TOML'
approval_policy = "never"
sandbox_mode    = "danger-full-access"
TOML
}

gemini_yolo_json() {
  cat <<'JSON'
{
  "general": {
    "defaultApprovalMode": "auto_edit"
  }
}
JSON
}

# Every home ai-yolo should seed: root, real login accounts, and /etc/skel so
# future accounts inherit it. Emits "user:home" pairs.
yolo_homes() {
  printf 'root:/root\n'
  getent passwd \
    | awk -F: '$3 >= 1000 && $3 < 60000 && $6 ~ /^\// { print $1 ":" $6 }'
  printf 'root:/etc/skel\n'
}

# write_yolo <path> <owner> <content-fn> <dir-mode>
# Never overwrites. Records what it created in the manifest.
write_yolo() {
  local path="$1" owner="$2" fn="$3" dmode="$4" grp
  if [ -e "$path" ]; then
    skip "$path exists — left alone"
    return 0
  fi
  install -d -m "$dmode" "$(dirname "$path")"
  "$fn" >"$path"
  chmod 644 "$path"
  if [ "$owner" != root ]; then
    grp="$(id -gn "$owner" 2>/dev/null || echo "$owner")"
    chown "$owner:$grp" "$path" "$(dirname "$path")" 2>/dev/null || true
  fi
  printf '%s\n' "$path" >>"$YOLO_MANIFEST"
  ok "wrote $path"
}

install_ai_yolo() {
  step "ai-yolo"
  warn "This enables auto-approve for EVERY user on this box: the AI CLIs will"
  warn "run any command without asking. Only sane on a disposable, single-owner VM."
  if [ "$ASSUME_YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    printf '    type %syolo%s to confirm: ' "$B" "$R"
    local ans; read -r ans
    [ "$ans" = "yolo" ] || { warn "skipped ai-yolo"; return 0; }
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "would write $CLAUDE_MANAGED and $GEMINI_SYSTEM (system-wide)"
    info "would seed .codex/config.toml into every home + /etc/skel"
    info "would write codex/gemini yolo aliases to $YOLO_FILE"
    return 0
  fi

  install -d -m 755 "$CONF_DIR"
  touch "$YOLO_MANIFEST"; chmod 644 "$YOLO_MANIFEST"

  # Claude Code: managed policy settings outrank every per-user setting.
  write_yolo "$CLAUDE_MANAGED" root claude_yolo_json 755
  # Gemini CLI: system-level settings.
  write_yolo "$GEMINI_SYSTEM"  root gemini_yolo_json 755

  # Codex has no system-wide config path, so seed per home.
  local entry user home
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    user="${entry%%:*}"; home="${entry#*:}"
    [ "$home" = /etc/skel ] || [ -d "$home" ] || continue
    write_yolo "$home/.codex/config.toml" "$user" codex_yolo_toml 700
  done <<EOF
$(yolo_homes)
EOF

  # Aliases are read from /etc by both shells, so they cover all users.
  cat >"$YOLO_FILE" <<'RCSH'
# Written by devsys install-tools.sh (ai-yolo group). Sourced by both zsh and
# bash, for every user. Delete this file to turn flag-based auto-approve off.
alias codex='codex --dangerously-bypass-approvals-and-sandbox'
alias gemini='gemini --yolo'
RCSH
  chmod 644 "$YOLO_FILE"
  ok "wrote $YOLO_FILE (all users)"

  if [ ! -f "$RC_FILE" ]; then
    warn "the 'shell' group isn't installed, so $YOLO_FILE won't be sourced."
  fi
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
    info "would enable tailscaled at boot, then:"
    info "  tailscale up --hostname=$(ts_hostname) ${TS_FLAGS[*]}"
    return 0
  }

  enable_tailscaled

  local hn; hn="$(ts_hostname)"
  info "tailnet hostname: ${B}$hn${R}   flags: ${TS_FLAGS[*]}"

  # Already on the tailnet: apply the settings idempotently instead of
  # re-running `up`, which would block on a fresh auth round-trip.
  if tailscale status >/dev/null 2>&1; then
    ok "already joined"
    run tailscale set --hostname="$hn" "${TS_FLAGS[@]}" \
      || warn "could not apply tailscale settings"
    ok "settings applied"
    return 0
  fi

  if ! confirm "Run 'tailscale up' now to join the tailnet?"; then
    info "join later with: ${B}sudo tailscale up --hostname=$hn ${TS_FLAGS[*]}${R}"
    return 0
  fi

  # --timeout matters: a bare `tailscale up` blocks forever when the tailnet
  # requires manual device approval, with no clue why. Time out, then report
  # the actual backend state and what to do about it.
  tailscale up --timeout=120s --hostname="$hn" "${TS_FLAGS[@]}" || true
  ts_report_state "$hn"
}

# VM name = tailnet name. Tailscale wants a DNS label, so fold to lowercase
# and replace anything else with a hyphen. Override with TS_HOSTNAME.
ts_hostname() {
  local h="${TS_HOSTNAME:-}"
  if [ -z "$h" ]; then
    h="$(hostname -s 2>/dev/null || true)"
    [ -n "$h" ] || h="$(cat /etc/hostname 2>/dev/null || true)"
  fi
  h="${h,,}"
  h="${h//[^a-z0-9-]/-}"
  while case "$h" in -*) true ;; *) false ;; esac; do h="${h#-}"; done
  while case "$h" in *-) true ;; *) false ;; esac; do h="${h%-}"; done
  [ -n "$h" ] || h="devbox"
  printf '%s' "$h"
}

ts_report_state() {
  local hn="$1" state
  state="$(tailscale status --json 2>/dev/null || true)"
  case "$state" in
    *'"BackendState": "Running"'*|*'"BackendState":"Running"'*)
      ok "tailnet: joined and running as $hn"
      return 0
      ;;
    *'NeedsMachineAuth'*)
      warn "authenticated, but this node needs ADMIN APPROVAL before it connects."
      info "your tailnet has device approval enabled — approve it on the"
      info "Machines page of the admin console. No need to re-authenticate;"
      info "tailscaled has the credentials and will connect once approved."
      ;;
    *'NeedsLogin'*)
      warn "not logged in — the auth link may have expired, or it was for a"
      warn "different tailnet. Retry with: ${B}sudo tailscale login${R}"
      ;;
    '')
      warn "could not read tailscale status — is tailscaled running?"
      ;;
    *)
      warn "tailscale is not Running yet. Check: ${B}tailscale status${R}"
      ;;
  esac
  info "the install continues regardless — this doesn't block the rest."
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

# ------------------------------------------------------------ uninstallers --
#
# Unchecking an installed group in the picker removes it. Two standing rules:
#   1. never touch user DATA (docker images, redis dumps, tailscale node
#      identity) — only the software. Data removal stays a manual act.
#   2. never remove what the system or this script depends on. `base` is
#      PROTECTED for that reason, and python3 stays even when `build` goes,
#      because much of Debian links against it.

apt_purge() {
  run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$@"
}

npm_uninstall() {
  have npm || { info "npm already gone — skipping npm packages"; return 0; }
  run npm uninstall -g --prefix "$NPM_PREFIX" "$@" || true
}

# Strip the devsys marker block back out of a system rc file.
unwire_block() {
  local target="$1"
  [ -f "$target" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then info "would unwire $target"; return 0; fi
  grep -qF "$MARKER" "$target" || return 0
  sed -i "\|^${MARKER}\$|,\|^${MARKER_END}\$|d" "$target"
  ok "unwired $target"
}

remove_tailscale() {
  step "remove tailscale"
  apt_purge tailscale || true
  warn "node identity left in /var/lib/tailscale — delete it to fully de-register"
  ok "tailscale removed"
}

remove_build() {
  step "remove build"
  apt_purge build-essential pkg-config || true
  info "python3 kept — removing it would break large parts of Debian"
  ok "build removed"
}

remove_editors() {
  step "remove editors"
  apt_purge nano micro || true
  info "vim kept (it belongs to base)"
  ok "editors removed"
}

remove_cli() {
  step "remove cli"
  apt_purge ripgrep fd-find bat fzf htop ncdu eza glow || true
  run rm -f "$BIN_DIR/fd" "$BIN_DIR/bat" "$BIN_DIR/lazygit"
  ok "cli removed"
}

remove_shell() {
  step "remove shell"
  apt_purge direnv tmux || true
  run rm -f "$BIN_DIR/starship" "$BIN_DIR/z" "$RC_FILE" "$BASH_RC_FILE" \
            "$CONF_DIR/aliases.sh"
  unwire_block /etc/zsh/zshrc
  unwire_block /etc/bash.bashrc
  ok "shell removed (PATH/env stays — that belongs to base)"
}

remove_mise() {
  step "remove mise"
  run rm -f "$BIN_DIR/mise"
  run rm -rf "$MISE_DIR" /etc/mise
  ok "mise removed (and the runtimes it managed)"
}

remove_node() {
  step "remove node"
  npm_uninstall pnpm
  run rm -rf "$BUN_DIR"
  run rm -f "$BIN_DIR/bun" "$BIN_DIR/bunx"
  if have mise && [ "$DRY_RUN" = 0 ]; then
    MISE_DATA_DIR="$MISE_DIR" MISE_GLOBAL_CONFIG_FILE="$MISE_CONF" \
      mise uninstall --all node 2>/dev/null || true
  fi
  ok "node + pnpm + bun removed"
}

remove_python() {
  step "remove python"
  if have mise && [ "$DRY_RUN" = 0 ]; then
    MISE_DATA_DIR="$MISE_DIR" MISE_GLOBAL_CONFIG_FILE="$MISE_CONF" \
      mise uninstall --all python 2>/dev/null || true
  fi
  ok "mise-managed python removed (system python3 untouched)"
}

remove_dotnet() {
  step "remove dotnet"
  run rm -rf "$DOTNET_DIR"
  run rm -f "$BIN_DIR/dotnet"
  info "per-user global tools in ~/.dotnet/tools left alone"
  ok "dotnet removed"
}

remove_docker() {
  step "remove docker"
  apt_purge docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin || true
  warn "images, volumes and containers left in /var/lib/docker — delete manually if you mean it"
  ok "docker removed"
}

remove_cloud() {
  step "remove cloud"
  apt_purge gh || true
  npm_uninstall neonctl
  run rm -rf "$FLY_DIR"
  run rm -f "$BIN_DIR/fly" "$BIN_DIR/flyctl"
  ok "cloud removed"
}

remove_ai() {
  step "remove ai"
  npm_uninstall @anthropic-ai/claude-code @google/gemini-cli @openai/codex opencode-ai
  ok "AI CLIs removed (per-user logins under \$HOME left alone)"
}

remove_ai_yolo() {
  step "remove ai-yolo"
  run rm -f "$YOLO_FILE"

  # Manifest-driven so we delete only files ai-yolo actually created, never a
  # settings.json somebody wrote themselves (those were skipped on install).
  if [ -f "$YOLO_MANIFEST" ] && [ "$DRY_RUN" = 0 ]; then
    local f n=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ -e "$f" ]; then rm -f "$f"; n=$((n + 1)); fi
    done <"$YOLO_MANIFEST"
    rm -f "$YOLO_MANIFEST"
    ok "removed $n config file(s) recorded in the manifest"
  elif [ "$DRY_RUN" = 1 ]; then
    info "would remove every config file listed in $YOLO_MANIFEST"
  else
    warn "no manifest found — any pre-existing configs were left untouched"
  fi
  ok "ai-yolo removed (all users)"
}

remove_data() {
  step "remove data"
  apt_purge redis-server postgresql-client || true
  warn "redis data left in /var/lib/redis — delete manually if you mean it"
  ok "data removed"
}

remove_notes() {
  step "remove notes"
  npm_uninstall obsidian-headless
  ok "notes removed"
}

remove_auth() {
  step "remove auth"
  run rm -f "$BIN_DIR/devsys-auth"
  apt_purge age || true
  info "any exported .age bundles are left where you put them"
  ok "auth removed"
}

remove_group() {
  case "$1" in
    tailscale) remove_tailscale ;;
    build)     remove_build ;;
    editors)   remove_editors ;;
    cli)       remove_cli ;;
    shell)     remove_shell ;;
    mise)      remove_mise ;;
    node)      remove_node ;;
    python)    remove_python ;;
    dotnet)    remove_dotnet ;;
    docker)    remove_docker ;;
    cloud)     remove_cloud ;;
    ai)        remove_ai ;;
    ai-yolo)   remove_ai_yolo ;;
    data)      remove_data ;;
    notes)     remove_notes ;;
    auth)      remove_auth ;;
    base)      warn "base is protected and will not be removed" ;;
    *)         die "no uninstaller for group: $1" ;;
  esac
}

# Removing a group must also remove whatever installed group depends on it,
# or you'd be left with e.g. node shims and no mise behind them. Returns the
# closed set in REVERSE install order, so dependents go first.
expand_removals() {
  local -A rm=()
  local g dep other changed=1 i
  for g in "$@"; do
    is_protected "$g" && continue
    rm[$g]=1
  done
  while [ "$changed" = 1 ]; do
    changed=0
    for other in "${GROUP_ORDER[@]}"; do
      [ -n "${rm[$other]:-}" ] && continue
      is_protected "$other" && continue
      [ "${STATUS[$other]:-missing}" = missing ] && continue
      for dep in ${GROUP_DEPS[$other]:-}; do
        if [ -n "${rm[$dep]:-}" ]; then rm[$other]=1; changed=1; break; fi
      done
    done
  done
  for (( i=${#GROUP_ORDER[@]} - 1; i >= 0; i-- )); do
    g="${GROUP_ORDER[$i]}"
    [ -n "${rm[$g]:-}" ] && printf '%s\n' "$g"
  done
}

# confirm_and_remove <array-name> — shows the removal plan, flags dependents
# that were pulled in, and empties the array unless explicitly confirmed.
# Takes the array by NAME so it can clear the caller's copy on a decline.
confirm_and_remove() {
  # nameref so a declined confirmation can clear the caller's array
  local -n __list="$1"
  [ ${#__list[@]} -gt 0 ] || return 0

  printf '\n%s%sTO REMOVE:%s %s\n' "$B" "$RED" "$R" "${__list[*]}"

  local extra=() u found g
  for g in "${__list[@]}"; do
    found=0
    for u in "${unchecked[@]:-}"; do [ "$u" = "$g" ] && found=1; done
    [ "$found" = 0 ] && extra+=("$g")
  done
  [ ${#extra[@]} -gt 0 ] && warn "also removing dependents: ${extra[*]}"

  info "software only — docker images, redis data and the tailscale node"
  info "identity stay on disk for you to delete deliberately."

  if [ "$DRY_RUN" = 1 ]; then
    info "(dry run — nothing will be removed)"
    return 0
  fi
  if [ "$ASSUME_YES" = 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    warn "not a terminal and no --yes — skipping removals"
    __list=()
    return 0
  fi
  printf '\n    type %sremove%s to confirm, anything else to skip: ' "$B$RED" "$R"
  local ans; read -r ans
  if [ "$ans" != "remove" ]; then
    warn "skipping all removals"
    __list=()
  fi
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

    # Probe as the human, in their login shell so $HOME and PATH are theirs.
    if as_target_sh "$probe" >/dev/null 2>&1; then
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
        # Needs root, and must not go through the unprivileged user.
        # shellcheck disable=SC2086
        $plogin || warn "$pname login did not complete"
      else
        as_target_sh "$plogin" || warn "$pname login did not complete"
      fi
    else
      info "skipped — run it later as $TARGET_USER"
    fi
  done
}

# ---------------------------------------------------------------- cleanup ---
#
# Shows what's installed, how much space it costs and whether anyone seems to
# be using it, so dead weight can be unchecked in the picker and removed.
#
# "Last used" comes from binary atime. That is a genuine estimate, not a fact:
# most filesystems mount `relatime` (atime only advances once a day), and a
# `noatime` mount disables it entirely — which is detected and reported rather
# than quietly presented as "never used".

# Big directories a group owns outside of dpkg's accounting.
declare -A GROUP_DIRS=(
  [mise]="/opt/mise"
  [node]="/opt/bun /usr/local/lib/node_modules/pnpm"
  [dotnet]="/usr/share/dotnet"
  [cloud]="/opt/fly /usr/local/lib/node_modules/neonctl"
  [ai]="/usr/local/lib/node_modules/@anthropic-ai /usr/local/lib/node_modules/@google /usr/local/lib/node_modules/@openai /usr/local/lib/node_modules/opencode-ai"
  [notes]="/usr/local/lib/node_modules/obsidian-headless"
  [auth]="/usr/local/bin/devsys-auth"
)

# Data directories that are NOT removed with their group.
declare -A GROUP_DATA=(
  [docker]="/var/lib/docker"
  [data]="/var/lib/redis /var/lib/postgresql"
  [tailscale]="/var/lib/tailscale"
)

human_kb() {
  local kb="${1:-0}"
  if   [ "$kb" -ge 1048576 ]; then printf '%d.%d GB' $((kb / 1048576)) $(( (kb % 1048576) * 10 / 1048576 ))
  elif [ "$kb" -ge 1024 ];    then printf '%d MB' $((kb / 1024))
  else printf '%d KB' "$kb"
  fi
}

# Package owning a path, without a pipe (see the apt_has note on pipefail).
pkg_owning() {
  local out first
  out="$(dpkg -S "$1" 2>/dev/null || true)"
  first="${out%%$'\n'*}"
  case "$first" in
    *:*) printf '%s' "${first%%:*}" ;;
    *)   printf '' ;;
  esac
}

group_size_kb() {
  local g="$1" total=0 c p pkg sz dir
  local -A pkgs=()
  for c in ${GROUP_PROBE[$g]:-}; do
    case "$c" in /*) continue ;; esac
    have "$c" || continue
    p="$(command -v "$c" 2>/dev/null || true)"
    [ -n "$p" ] || continue
    p="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
    pkg="$(pkg_owning "$p")"
    [ -n "$pkg" ] && pkgs[$pkg]=1
  done
  for pkg in "${!pkgs[@]}"; do
    sz="$(dpkg-query -W -f='${Installed-Size}' "$pkg" 2>/dev/null || echo 0)"
    case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    total=$((total + sz))
  done
  for dir in ${GROUP_DIRS[$g]:-}; do
    [ -d "$dir" ] || continue
    sz="$(du -sk "$dir" 2>/dev/null || true)"
    sz="${sz%%[!0-9]*}"
    case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    total=$((total + sz))
  done
  printf '%s' "$total"
}

NOATIME=0
detect_noatime() {
  local opts
  opts="$(findmnt -no OPTIONS --target /usr 2>/dev/null || true)"
  case "$opts" in *noatime*) NOATIME=1 ;; esac
}

# Days since the most recently accessed binary in the group; empty if unknown.
group_days_idle() {
  local g="$1" c p at newest=0 now
  now="$(date +%s)"
  for c in ${GROUP_PROBE[$g]:-}; do
    case "$c" in /*) continue ;; esac
    have "$c" || continue
    p="$(command -v "$c" 2>/dev/null || true)"
    [ -n "$p" ] || continue
    at="$(stat -c %X "$p" 2>/dev/null || true)"
    case "$at" in ''|*[!0-9]*) continue ;; esac
    [ "$at" -gt "$newest" ] && newest="$at"
  done
  [ "$newest" = 0 ] && { printf ''; return 0; }
  printf '%s' $(( (now - newest) / 86400 ))
}

# How many users' shell histories mention any of the group's binaries.
group_history_hits() {
  local g="$1" c hf hits=0
  for hf in /root/.zsh_history /root/.bash_history \
            /home/*/.zsh_history /home/*/.bash_history; do
    [ -r "$hf" ] || continue
    for c in ${GROUP_PROBE[$g]:-}; do
      case "$c" in /*) continue ;; esac
      if grep -qw -- "$c" "$hf" 2>/dev/null; then
        hits=$((hits + 1))
        break
      fi
    done
  done
  printf '%s' "$hits"
}

cleanup_report() {
  step "cleanup — what's installed, what it costs, what looks unused"
  detect_noatime

  printf '\n    %-11s %-10s %9s  %-11s %s\n' \
    "GROUP" "STATUS" "SIZE" "LAST USED" "IN SHELL HISTORY"
  printf '    %s\n' "-------------------------------------------------------------------"

  local g total=0 kb idle hits idle_txt hist_txt any=0 candidates=()
  for g in "${GROUP_ORDER[@]}"; do
    case "${STATUS[$g]}" in installed|partial) ;; *) continue ;; esac
    any=1
    kb="$(group_size_kb "$g")"
    total=$((total + kb))
    idle="$(group_days_idle "$g")"
    hits="$(group_history_hits "$g")"

    if [ -z "$idle" ]; then idle_txt="unknown"
    elif [ "$NOATIME" = 1 ]; then idle_txt="n/a"
    elif [ "$idle" = 0 ]; then idle_txt="today"
    else idle_txt="${idle}d ago"
    fi

    if [ "$hits" -gt 0 ]; then hist_txt="${GRN}yes ($hits)${R}"; else hist_txt="${DIM}no${R}"; fi

    # Flag as a candidate only when both signals agree it's cold.
    if [ "$hits" = 0 ] && [ -n "$idle" ] && [ "$NOATIME" = 0 ] && [ "$idle" -ge 14 ]; then
      candidates+=("$g")
      printf '    %s%-11s%s %-10s %9s  %-11s %b  %sunused?%s\n' \
        "$YLW" "$g" "$R" "${STATUS[$g]}" "$(human_kb "$kb")" "$idle_txt" "$hist_txt" "$YLW" "$R"
    else
      printf '    %-11s %-10s %9s  %-11s %b\n' \
        "$g" "${STATUS[$g]}" "$(human_kb "$kb")" "$idle_txt" "$hist_txt"
    fi
  done

  if [ "$any" = 0 ]; then
    printf '\n'; info "nothing installed yet"; return 0
  fi

  printf '    %s\n' "-------------------------------------------------------------------"
  printf '    %-11s %-10s %9s\n\n' "total" "" "$(human_kb "$total")"

  # Data directories are reported but never removed with their group.
  local d dkb shown=0
  for g in "${!GROUP_DATA[@]}"; do
    for d in ${GROUP_DATA[$g]}; do
      [ -d "$d" ] || continue
      dkb="$(du -sk "$d" 2>/dev/null || true)"; dkb="${dkb%%[!0-9]*}"
      case "$dkb" in ''|*[!0-9]*) continue ;; esac
      [ "$shown" = 0 ] && info "${B}data directories (never removed automatically):${R}"
      shown=1
      printf '      %-24s %9s  %s(%s)%s\n' "$d" "$(human_kb "$dkb")" "$DIM" "$g" "$R"
    done
  done
  [ "$shown" = 1 ] && printf '\n'

  if [ "$NOATIME" = 1 ]; then
    warn "/usr is mounted noatime, so last-use times are unavailable."
    warn "Shell-history hits are the only usage signal here."
  else
    info "${DIM}last-use is estimated from binary atime; relatime means it's"
    info "accurate to about a day, and never proof a tool is unused.${R}"
  fi

  if [ ${#candidates[@]} -gt 0 ]; then
    printf '\n'
    info "${YLW}candidates to remove:${R} ${candidates[*]}"
    info "no shell-history hits and untouched for 14+ days"
  else
    printf '\n'
    info "nothing looks clearly unused"
  fi
  printf '\n'
  info "to remove any of it: run the picker and uncheck the group."
  printf '\n'
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
    printf '  %s%2d%s  %s%-10s%s %-22s %s\n' \
      "$B" "$i" "$R" "$CYN" "$g" "$R" "$(status_label "$g")" "$mark"
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

# The checkbox is DESIRED STATE, so it must start from reality: anything
# already on the box begins checked. On a box with nothing installed there is
# no reality to reflect, so fall back to the defaults.
pick_reset_current() {
  local i g
  if box_is_fresh; then pick_reset_defaults; return 0; fi
  for i in "${!GROUP_ORDER[@]}"; do
    g="${GROUP_ORDER[$i]}"
    case "${STATUS[$g]}" in
      installed|partial) CHECKED[i]=1 ;;
      *)                 CHECKED[i]=0 ;;
    esac
  done
}

status_label() {
  case "${STATUS[$1]}" in
    installed) printf '%sinstalled%s' "$GRN" "$R" ;;
    partial)   printf '%spartial%s'   "$YLW" "$R" ;;
    *)         printf '%s—%s'         "$DIM" "$R" ;;
  esac
}

pick_set_all() {
  local i g want="$1"
  for i in "${!GROUP_ORDER[@]}"; do
    g="${GROUP_ORDER[$i]}"
    if [ "$want" = 1 ] && is_opt_in_only "$g"; then CHECKED[i]=0; else CHECKED[i]=$want; fi
  done
}

pick_render_row() {
  local i="$1" g box name desc pointer color avail stat pad
  g="${GROUP_ORDER[$i]}"
  if [ "${CHECKED[i]}" = 1 ]; then box="${GRN}[x]${R}"; else box="[ ]"; fi
  if [ "$i" = "$PICK_CUR" ]; then pointer="${B}${CYN}❯${R}"; else pointer=" "; fi
  if is_opt_in_only "$g"; then color="$YLW"; else color="$CYN"; fi
  name=$(printf '%-10s' "$g")

  # Status column is 9 visible chars ("installed"); pad by visible width since
  # the label carries colour escapes that printf's %-9s would miscount.
  stat="$(status_label "$g")"
  case "${STATUS[$g]}" in
    installed) pad="" ;;
    partial)   pad="  " ;;
    *)         pad="        " ;;
  esac

  # 2 indent + 2 pointer + 4 box + 11 name + 10 status = 29 columns of chrome
  avail=$((PICK_COLS - 31))
  [ "$avail" -lt 12 ] && avail=12
  desc="${GROUP_DESC[$g]}"
  if [ "${#desc}" -gt "$avail" ]; then desc="${desc:0:$((avail - 1))}…"; fi
  printf '  %s %s %s%s%s %s%s %s%s%s\n' \
    "$pointer" "$box" "$color" "$name" "$R" "$stat" "$pad" "$DIM" "$desc" "$R"
}

pick_hint() {
  printf '  %s↑↓%s move  %sspace%s toggle  %sa%s all  %sn%s none  %sd%s defaults  %sc%s current  %s⏎%s apply  %sq%s quit\n' \
    "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R"
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
  pick_reset_current
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
      c|C) pick_reset_current ;;
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
  sudo ./install-tools.sh --list          list groups, contents and status
  sudo ./install-tools.sh <group>...      install named groups (deps auto-added)
  sudo ./install-tools.sh all             everything except: ${OPT_IN_ONLY[*]}
  sudo ./install-tools.sh --check-logins  probe tool auth, offer to log in
  sudo ./install-tools.sh --cleanup       show size + last-use per group,
                                          flag what looks unused

Run it with sudo from YOUR account, not as root: \$SUDO_USER decides whose
logins are checked, who is offered the docker group, and who owns per-user
config. As bare root, all of that targets root instead.

The picker is DESIRED STATE. It opens reflecting what is already installed —
checked means "should be on this box". Unchecking an installed group UNINSTALLS
it (with confirmation); removals cascade to dependents. Naming groups on the
command line only ever installs, never removes. \`base\` can never be removed.

Options:
  --dry-run        print the commands instead of running them
  -y, --yes        don't prompt for confirmation (implies yes to ai-yolo)
  --check-logins   only run the login check
  --cleanup        report installed groups with size, last-use estimate and
                   shell-history hits, then offer the picker to remove them
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
LIST_ONLY=0
CLEANUP_ONLY=0
REMOVE_MODE=0

main() {
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)        DRY_RUN=1 ;;
      -y|--yes)         ASSUME_YES=1 ;;
      --check-logins)   CHECK_ONLY=1 ;;
      --cleanup)        CLEANUP_ONLY=1 ;;
      --remove)         REMOVE_MODE=1 ;;
      --no-login-check) SKIP_LOGIN_CHECK=1 ;;
      -l|--list)        LIST_ONLY=1 ;;
      -h|--help)        usage; exit 0 ;;
      -*)               die "unknown option: $1 (try --help)" ;;
      *)                args+=("$1") ;;
    esac
    shift
  done

  detect_os
  resolve_target_user
  adopt_system_env

  if [ "$LIST_ONLY" = 1 ]; then
    scan_status
    print_groups
    exit 0
  fi

  if [ "$CLEANUP_ONLY" = 1 ]; then
    scan_status
    cleanup_report
    # Offer the picker straight away so unchecking can act on what was shown.
    if [ -t 0 ] && [ "$DRY_RUN" = 0 ] && confirm "Open the picker to remove some of it?"; then
      require_root
    else
      exit 0
    fi
  fi

  if [ "$CHECK_ONLY" = 1 ]; then
    check_logins
    printf '\n'
    exit 0
  fi

  [ "$DRY_RUN" = 1 ] || require_root

  scan_status

  local selected=() g removals=() unchecked=() from_picker=0

  # Explicit uninstall of named groups — the scriptable counterpart to
  # unchecking them in the picker. Same cascade and same confirmation.
  if [ "$REMOVE_MODE" = 1 ]; then
    [ ${#args[@]} -gt 0 ] || die "--remove needs group names (try --list)"
    for g in "${args[@]}"; do
      valid_group "$g" || die "unknown group: $g (try --list)"
      if is_protected "$g"; then die "$g is protected and cannot be removed"; fi
      if [ "${STATUS[$g]}" = missing ]; then
        info "$g is not installed — nothing to remove"
      else
        unchecked+=("$g")
      fi
    done
    [ ${#unchecked[@]} -gt 0 ] || { step "nothing to do"; printf '\n'; exit 0; }
    append_lines removals "$(expand_removals "${unchecked[@]}")"
    confirm_and_remove removals
    for g in "${removals[@]}"; do remove_group "$g"; done
    step "done"
    info "removed: ${removals[*]:-nothing}"
    printf '\n'
    exit 0
  fi

  if [ ${#args[@]} -eq 0 ]; then
    from_picker=1
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
  # Removals are DESIRED-STATE semantics and therefore only ever come from the
  # picker. `install-tools.sh node` must never be read as "remove everything
  # else" — naming groups means install those, full stop.
  if [ "$from_picker" = 1 ]; then
    local i
    for i in "${!GROUP_ORDER[@]}"; do
      g="${GROUP_ORDER[$i]}"
      [ "${CHECKED[i]}" = 1 ] && continue
      [ "${STATUS[$g]}" = missing ] && continue
      unchecked+=("$g")
    done
    if [ ${#unchecked[@]} -gt 0 ]; then
      append_lines removals "$(expand_removals "${unchecked[@]}")"
    fi
  fi

  [ ${#selected[@]} -gt 0 ] || [ ${#removals[@]} -gt 0 ] || die "nothing selected"

  # Already-installed groups need no work; partial ones get repaired.
  local plan=() resolved=()
  if [ ${#selected[@]} -gt 0 ]; then
    append_lines resolved "$(resolve "${selected[@]}")"
    for g in "${resolved[@]}"; do
      if [ "$from_picker" = 1 ] && [ "${STATUS[$g]}" = installed ]; then continue; fi
      plan+=("$g")
    done
  fi

  if [ ${#removals[@]} -gt 0 ]; then
    confirm_and_remove removals
  fi

  if [ ${#plan[@]} -eq 0 ] && [ ${#removals[@]} -eq 0 ]; then
    step "nothing to do"
    info "everything you selected is already installed"
    printf '\n'
    exit 0
  fi

  printf '\n%sPlan%s%s (deps resolved):%s %s\n' "$B" "$R" "$DIM" "$R" "${plan[*]:-—}"
  printf '%sTarget:%s system-wide (%s, %s, %s) · logins for: %s\n' \
    "$DIM" "$R" "$BIN_DIR" "/opt" "$CONF_DIR" "$TARGET_USER"
  [ "$DRY_RUN" = 1 ] && printf '%s(dry run — nothing will be installed)%s\n' "$YLW" "$R"

  # Removals run first: tearing down before building avoids a half-removed
  # group being immediately reinstalled by a dependency of something else.
  for g in "${removals[@]}"; do
    remove_group "$g"
  done

  local i
  for i in "${!plan[@]}"; do
    g="${plan[$i]}"
    run_group "$g"
    # The handover point: everything after tailscale is the developer's job.
    if [ "$g" = tailscale ] && [ "$DRY_RUN" = 0 ]; then
      handover_pause "${plan[@]:$((i + 1))}"
    fi
  done

  # Late, so it picks up tools installed by any group in this run.
  if [ ${#plan[@]} -gt 0 ]; then
    install_completions
  fi

  step "done"
  [ ${#plan[@]} -gt 0 ]     && info "installed: ${plan[*]}"
  [ ${#removals[@]} -gt 0 ] && info "removed:   ${removals[*]}"
  info "open a new shell, or: ${B}exec zsh -l${R}"

  if [ "$DRY_RUN" = 0 ] && [ "$SKIP_LOGIN_CHECK" = 0 ]; then
    check_logins
  fi
  printf '\n'
}

main "$@"
