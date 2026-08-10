#!/usr/bin/env bash
#
# install-tools.sh — install the devsys tool set on any Ubuntu/Debian box,
# one group at a time. Same tools the container image bakes in, but
# HOME-relative and non-destructive: nothing already on the box gets
# clobbered, and your ~/.zshrc / ~/.bashrc are only ever appended to.
#
# Usage:
#   ./install-tools.sh                  # arrow-key picker, space to toggle
#   ./install-tools.sh --list           # show groups and what's in them
#   ./install-tools.sh base cli shell   # install specific groups
#   ./install-tools.sh all              # everything except ai-yolo
#   ./install-tools.sh --dry-run all    # print what would happen
#
# One-liner from anywhere (process substitution keeps stdin a tty, so the
# interactive picker still works — a plain `curl | bash` would not):
#   bash <(curl -fsSL https://raw.githubusercontent.com/amitpareek/devsys/main/install-tools.sh)
#
# Needs sudo (or root) for the apt groups. Everything else lands under
# $HOME. Re-running is safe — every step is idempotent.

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/amitpareek/devsys/main"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MARKER="# >>> devsys env >>>"
DEVSYS_DIR="$HOME/.devsys"
ENV_FILE="$DEVSYS_DIR/env.sh"
RC_FILE="$DEVSYS_DIR/rc.zsh"
YOLO_FILE="$DEVSYS_DIR/yolo.zsh"

DRY_RUN=0
ASSUME_YES=0
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

# Shell-quoted variant, for things that genuinely need a pipeline.
runsh() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '    %s$ %s%s\n' "$DIM" "$1" "$R"
  else
    bash -c "$1"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------- platform ----

require_debian() {
  [ -r /etc/os-release ] || die "cannot read /etc/os-release — is this Linux?"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}${ID_LIKE:-}" in
    *debian*|*ubuntu*) : ;;
    *) die "this script targets Ubuntu/Debian (found ID=${ID:-?}). Nothing was changed." ;;
  esac
}

SUDO=""
setup_sudo() {
  if [ "$(id -u)" = 0 ]; then
    SUDO=""
  elif have sudo; then
    SUDO="sudo"
  else
    die "not root and sudo is not installed — cannot install apt packages"
  fi
}

apt_update_once() {
  [ "$APT_UPDATED" = 1 ] && return 0
  step "apt-get update"
  run $SUDO apt-get update -qq
  APT_UPDATED=1
}

apt_install() {
  apt_update_once
  run $SUDO apt-get install -y --no-install-recommends "$@"
}

# Is a package installable from the currently configured repos?
apt_has() {
  apt_update_once
  [ "$DRY_RUN" = 1 ] && return 0
  apt-cache policy "$1" 2>/dev/null | grep -qE 'Candidate: +[0-9]'
}

dpkg_arch() { dpkg --print-architecture; }

# add_apt_repo <name> <key-url> <deb-line>
# Dearmors the key into /etc/apt/keyrings/<name>.gpg and writes the list file.
add_apt_repo() {
  local name="$1" keyurl="$2" line="$3"
  local keyring="/etc/apt/keyrings/${name}.gpg"
  local list="/etc/apt/sources.list.d/${name}.list"
  if [ -f "$list" ] && [ -f "$keyring" ]; then
    skip "apt repo: $name"
    return 0
  fi
  info "adding apt repo: $name"
  run $SUDO install -d -m 755 /etc/apt/keyrings
  runsh "curl -fsSL '$keyurl' | gpg --dearmor | $SUDO tee '$keyring' >/dev/null"
  runsh "echo '$line' | $SUDO tee '$list' >/dev/null"
  run $SUDO chmod go+r "$keyring"
  APT_UPDATED=0   # new repo — force another update before the next install
}

# ------------------------------------------------------------ env plumbing --

# Idempotently append a sourcing stanza to a shell rc file.
ensure_sourced() {
  local rc="$1" body="$2"
  [ "$DRY_RUN" = 1 ] && { info "would wire $rc -> $ENV_FILE"; return 0; }
  touch "$rc"
  if grep -qF "$MARKER" "$rc"; then
    skip "$rc already wired up"
    return 0
  fi
  {
    printf '\n%s\n' "$MARKER"
    printf '%s\n' "$body"
    printf '%s\n' "# <<< devsys env <<<"
  } >>"$rc"
  ok "wired $rc"
}

write_env_file() {
  run mkdir -p "$DEVSYS_DIR" "$HOME/.local/bin"
  [ "$DRY_RUN" = 1 ] && { info "would write $ENV_FILE"; return 0; }
  cat >"$ENV_FILE" <<'ENVSH'
# Written by devsys install-tools.sh — safe to edit, safe to delete.
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
export PNPM_HOME="$HOME/.local/share/pnpm"
export BUN_INSTALL="$HOME/.bun"
export MISE_DATA_DIR="$HOME/.local/share/mise"

for d in \
  "$HOME/.local/bin" \
  "$HOME/.local/share/mise/shims" \
  "$HOME/.bun/bin" \
  "$HOME/.npm-global/bin" \
  "$HOME/.local/share/pnpm"
do
  case ":$PATH:" in
    *":$d:"*) ;;
    *) PATH="$d:$PATH" ;;
  esac
done
unset d
export PATH
ENVSH
  ok "wrote $ENV_FILE"

  ensure_sourced "$HOME/.bashrc" "[ -f \"\$HOME/.devsys/env.sh\" ] && . \"\$HOME/.devsys/env.sh\""
  # zsh: env in .zshenv (every shell), interactive bits in .zshrc.
  ensure_sourced "$HOME/.zshenv" "[ -f \"\$HOME/.devsys/env.sh\" ] && . \"\$HOME/.devsys/env.sh\""

  # Make the new PATH live for the rest of this run.
  # shellcheck disable=SC1090
  . "$ENV_FILE"
}

fetch_to() {
  local url="$1" dest="$2"
  run mkdir -p "$(dirname "$dest")"
  run curl -fsSL -o "$dest" "$url"
}

# ----------------------------------------------------------------- groups ---

# Order here is install order; deps are resolved on top of it.
GROUP_ORDER=(base build cli shell runtimes cloud ai ai-yolo data notes tailscale)

declare -A GROUP_DESC=(
  [base]="apt essentials — curl, wget, git, zsh, vim, unzip, rsync, ssh client, net tools, jq"
  [build]="compiler toolchain — build-essential, pkg-config, python3 + venv + pip"
  [cli]="modern CLI kit — ripgrep, fd, bat, fzf, eza, htop, ncdu, glow, lazygit"
  [shell]="zsh setup — starship prompt, direnv, tmux (mouse on), z session picker, devsys aliases"
  [runtimes]="mise + node@lts + python@3.12, pnpm, bun"
  [cloud]="gh (GitHub), flyctl (Fly.io), neonctl (Neon)"
  [ai]="AI coding CLIs — claude, gemini, codex, opencode"
  [ai-yolo]="auto-approve configs for the AI CLIs — DANGEROUS outside a throwaway box"
  [data]="redis-server, postgresql-client (psql)"
  [notes]="obsidian-headless (ob)"
  [tailscale]="tailscale + tailscaled via the official installer"
)

declare -A GROUP_DEPS=(
  [shell]="base"
  [cli]="base"
  [runtimes]="base"
  [cloud]="base runtimes"
  [ai]="base runtimes"
  [ai-yolo]="ai"
  [notes]="base runtimes"
)

# Groups selected when you just hit Enter at the picker.
DEFAULT_GROUPS=(base build cli shell runtimes)

# Groups never pulled in by `all` — must be named explicitly.
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

install_cli() {
  step "cli"
  apt_install ripgrep fd-find bat fzf htop ncdu

  # Ubuntu ships these under alternate names; alias them in ~/.local/bin.
  run mkdir -p "$HOME/.local/bin"
  have fdfind  && run ln -sf "$(command -v fdfind)"  "$HOME/.local/bin/fd"
  have batcat  && run ln -sf "$(command -v batcat)"  "$HOME/.local/bin/bat"

  # eza — in noble+ universe on some releases, otherwise the gierens repo.
  if have eza; then
    skip "eza"
  elif apt_has eza; then
    apt_install eza
    ok "eza (distro package)"
  else
    add_apt_repo gierens \
      "https://raw.githubusercontent.com/eza-community/eza/main/deb.asc" \
      "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main"
    apt_install eza
    ok "eza (gierens repo)"
  fi

  # glow — charm repo.
  if have glow; then
    skip "glow"
  else
    add_apt_repo charm \
      "https://repo.charm.sh/apt/gpg.key" \
      "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *"
    apt_install glow
    ok "glow"
  fi

  install_lazygit
}

install_lazygit() {
  if have lazygit; then
    skip "lazygit"
    return 0
  fi
  local arch lg_arch ver tmp
  arch="$(dpkg_arch)"
  case "$arch" in
    arm64) lg_arch=arm64 ;;
    amd64) lg_arch=x86_64 ;;
    *) warn "lazygit: unsupported arch $arch — skipping"; return 0 ;;
  esac
  if [ "$DRY_RUN" = 1 ]; then
    info "would download latest lazygit for Linux_$lg_arch into ~/.local/bin"
    return 0
  fi
  ver="$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest \
        | grep -oP '"tag_name": *"v\K[^"]+')" || die "lazygit: could not resolve latest version"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/lazygit.tgz" \
    "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${ver}_Linux_${lg_arch}.tar.gz"
  tar -xzf "$tmp/lazygit.tgz" -C "$tmp" lazygit
  install -m 755 "$tmp/lazygit" "$HOME/.local/bin/lazygit"
  rm -rf "$tmp"
  ok "lazygit $ver"
}

install_shell() {
  step "shell"
  apt_install direnv tmux

  # starship — into ~/.local/bin, no sudo needed.
  if have starship; then
    skip "starship"
  else
    runsh "curl -fsSL https://starship.rs/install.sh | sh -s -- --yes --bin-dir '$HOME/.local/bin'"
    ok "starship"
  fi

  # z — tmux session/window picker from this repo.
  if [ -f "$HOME/.local/bin/z" ]; then
    skip "z"
  elif [ -f "$SCRIPT_DIR/z.sh" ]; then
    run install -m 755 "$SCRIPT_DIR/z.sh" "$HOME/.local/bin/z"
    ok "z (from local checkout)"
  else
    fetch_to "$REPO_RAW/z.sh" "$HOME/.local/bin/z"
    run chmod 755 "$HOME/.local/bin/z"
    ok "z (fetched)"
  fi

  # tmux mouse mode — appended, so an existing ~/.tmux.conf survives.
  if [ "$DRY_RUN" = 1 ]; then
    info "would ensure 'set -g mouse on' in ~/.tmux.conf"
  elif [ -f "$HOME/.tmux.conf" ] && grep -qE '^set -g mouse' "$HOME/.tmux.conf"; then
    skip "tmux mouse mode"
  else
    printf 'set -g mouse on\n' >>"$HOME/.tmux.conf"
    ok "tmux mouse mode"
  fi

  write_shell_rc
}

write_shell_rc() {
  run mkdir -p "$DEVSYS_DIR"
  if [ "$DRY_RUN" = 1 ]; then
    info "would write $RC_FILE and source it from ~/.zshrc"
    return 0
  fi
  cat >"$RC_FILE" <<'RCZSH'
# Written by devsys install-tools.sh — safe to edit, safe to delete.
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
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
[ -f "$HOME/.devsys/yolo.zsh" ] && . "$HOME/.devsys/yolo.zsh"
RCZSH
  ok "wrote $RC_FILE"
  ensure_sourced "$HOME/.zshrc" "[ -f \"\$HOME/.devsys/rc.zsh\" ] && . \"\$HOME/.devsys/rc.zsh\""
}

install_runtimes() {
  step "runtimes"

  if have mise; then
    skip "mise"
  else
    runsh "curl -fsSL https://mise.run | sh"
    ok "mise"
  fi

  local mise="$HOME/.local/bin/mise"
  [ -x "$mise" ] || mise="$(command -v mise || true)"
  if [ -n "$mise" ] && [ "$DRY_RUN" = 0 ]; then
    "$mise" use --global --yes node@lts
    "$mise" use --global --yes python@3.12
    "$mise" reshim
    ok "node@lts + python@3.12 via mise"
  elif [ "$DRY_RUN" = 1 ]; then
    info "would run: mise use --global node@lts python@3.12; mise reshim"
  fi

  # mise shims are on PATH via env.sh (sourced by write_env_file).
  run mkdir -p "$HOME/.npm-global" "$HOME/.local/share/pnpm/store" "$HOME/.local/share/pnpm/global"

  if have pnpm; then
    skip "pnpm"
  else
    npm_global pnpm
  fi
  if [ "$DRY_RUN" = 0 ] && have pnpm; then
    pnpm config set store-dir      "$HOME/.local/share/pnpm/store"
    pnpm config set global-dir     "$HOME/.local/share/pnpm/global"
    pnpm config set global-bin-dir "$HOME/.local/share/pnpm"
  fi

  if have bun; then
    skip "bun"
  else
    runsh "export BUN_INSTALL='$HOME/.bun'; curl -fsSL https://bun.sh/install | bash"
    ok "bun"
  fi
}

# npm_global <pkg...> — installs into $HOME/.npm-global, never sudo.
npm_global() {
  have npm || die "npm not found — install the 'runtimes' group first"
  run npm install -g --prefix "$HOME/.npm-global" "$@"
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
    runsh "curl -fsSL https://fly.io/install.sh | sh"
    run mkdir -p "$HOME/.local/bin"
    if [ -x "$HOME/.fly/bin/flyctl" ] || [ "$DRY_RUN" = 1 ]; then
      run ln -sf "$HOME/.fly/bin/flyctl" "$HOME/.local/bin/flyctl"
      run ln -sf "$HOME/.fly/bin/flyctl" "$HOME/.local/bin/fly"
      ok "flyctl (+ 'fly' alias)"
    else
      warn "flyctl installed but $HOME/.fly/bin/flyctl not found — check fly.io/install.sh output"
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
    info "would write ~/.claude/settings.json, ~/.codex/config.toml, ~/.gemini/settings.json"
    info "would write codex/gemini yolo aliases to $YOLO_FILE"
    return 0
  fi

  write_if_absent "$HOME/.claude/settings.json" <<'JSON'
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

  write_if_absent "$HOME/.codex/config.toml" <<'TOML'
approval_policy = "never"
sandbox_mode    = "danger-full-access"
TOML

  write_if_absent "$HOME/.gemini/settings.json" <<'JSON'
{
  "general": {
    "defaultApprovalMode": "auto_edit"
  }
}
JSON

  # codex/gemini take the yolo flag directly; claude refuses it as root and
  # relies on ~/.claude/settings.json instead.
  mkdir -p "$DEVSYS_DIR"
  cat >"$YOLO_FILE" <<'RCZSH'
# Written by devsys install-tools.sh (ai-yolo group). Delete this file to
# turn flag-based auto-approve back off.
alias codex='codex --dangerously-bypass-approvals-and-sandbox'
alias gemini='gemini --yolo'
RCZSH
  ok "wrote $YOLO_FILE"

  if [ ! -f "$RC_FILE" ]; then
    warn "the 'shell' group isn't installed, so $YOLO_FILE won't be sourced."
    warn "either install it, or source that file from your own shell rc."
  fi
}

# write_if_absent <path> — writes stdin to path, never overwriting.
write_if_absent() {
  local path="$1"
  if [ -e "$path" ]; then
    cat >/dev/null   # drain the heredoc
    skip "$path exists — left alone"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  cat >"$path"
  ok "wrote $path"
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

install_tailscale() {
  step "tailscale"
  if have tailscale; then
    skip "tailscale"
    return 0
  fi
  runsh "curl -fsSL https://tailscale.com/install.sh | $SUDO sh"
  ok "tailscale — run '$SUDO tailscale up' to join a tailnet"
}

run_group() {
  case "$1" in
    base)      install_base ;;
    build)     install_build ;;
    cli)       install_cli ;;
    shell)     install_shell ;;
    runtimes)  install_runtimes ;;
    cloud)     install_cloud ;;
    ai)        install_ai ;;
    ai-yolo)   install_ai_yolo ;;
    data)      install_data ;;
    notes)     install_notes ;;
    tailscale) install_tailscale ;;
    *)         die "unknown group: $1" ;;
  esac
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

print_groups() {
  local i=1 g mark
  printf '\n%sdevsys tool groups%s\n\n' "$B" "$R"
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

# ---- arrow-key checkbox picker ---------------------------------------------
#
# Populates the global PICKED array. Everything is drawn to stderr so stdout
# stays clean, and it runs as a plain function call (no subshell) so `die`
# still reaches the top level.

PICKED=()
declare -a CHECKED=()   # 1/0 per GROUP_ORDER index
PICK_CUR=0

pick_reset_defaults() {
  local i g
  for i in "${!GROUP_ORDER[@]}"; do
    g="${GROUP_ORDER[$i]}"
    if is_default "$g"; then CHECKED[i]=1; else CHECKED[i]=0; fi
  done
}

pick_set_all() {
  local i g want="$1"   # want=1 select all (minus opt-in), 0 clear all
  for i in "${!GROUP_ORDER[@]}"; do
    g="${GROUP_ORDER[$i]}"
    if [ "$want" = 1 ] && is_opt_in_only "$g"; then CHECKED[i]=0; else CHECKED[i]=$want; fi
  done
}

pick_render_row() {
  local i="$1" g box name desc pointer color cols avail
  g="${GROUP_ORDER[$i]}"
  cols=${PICK_COLS:-80}

  if [ "${CHECKED[i]}" = 1 ]; then box="${GRN}[x]${R}"; else box="[ ]"; fi
  if [ "$i" = "$PICK_CUR" ]; then pointer="${B}${CYN}❯${R}"; else pointer=" "; fi
  if is_opt_in_only "$g"; then color="$YLW"; else color="$CYN"; fi

  name=$(printf '%-10s' "$g")
  # 2 (indent) + 2 (pointer) + 4 (box) + 11 (name) = 19 columns of chrome
  avail=$((cols - 21))
  [ "$avail" -lt 12 ] && avail=12
  desc="${GROUP_DESC[$g]}"
  if [ "${#desc}" -gt "$avail" ]; then desc="${desc:0:$((avail - 1))}…"; fi

  printf '  %s %s %s%s%s %s%s%s\n' \
    "$pointer" "$box" "$color" "$name" "$R" "$DIM" "$desc" "$R"
}

pick_render_all() {
  local i
  for i in "${!GROUP_ORDER[@]}"; do pick_render_row "$i"; done
  printf '\n'
  printf '  %s↑↓%s move  %sspace%s toggle  %sa%s all  %sn%s none  %sd%s defaults  %s⏎%s install  %sq%s quit\n' \
    "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R"
}

pick_move() {
  local n=${#GROUP_ORDER[@]}
  PICK_CUR=$(( (PICK_CUR + $1 + n) % n ))
}

pick_interactive() {
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    die "the picker needs a terminal — name groups explicitly, or run:
         bash <(curl -fsSL $REPO_RAW/install-tools.sh)"
  fi

  PICK_COLS=$( (command -v tput >/dev/null && tput cols) 2>/dev/null || echo 80 )
  pick_reset_defaults
  PICK_CUR=0

  local n=${#GROUP_ORDER[@]}
  local nlines=$((n + 2))   # rows + blank + hint
  local key rest

  # Always restore the cursor and echo, however we leave.
  local saved_stty
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
    printf '\n  %sdevsys tool groups%s  %sselect what to install%s\n\n' "$B" "$R" "$DIM" "$R"
    pick_render_all
  } >&2

  while true; do
    IFS= read -rsn1 key || key=''

    # Escape sequences: bare Esc quits, Esc[A/B are the arrows.
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
        restore_tty
        trap - EXIT INT TERM
        printf '\n  %saborted — nothing installed%s\n\n' "$DIM" "$R" >&2
        exit 0
        ;;
    esac

    {
      cursor_up "$nlines"
      local i
      for i in "${!GROUP_ORDER[@]}"; do printf '%s' "$CLR_LINE"; pick_render_row "$i"; done
      printf '%s\n' "$CLR_LINE"
      printf '%s' "$CLR_LINE"
      printf '  %s↑↓%s move  %sspace%s toggle  %sa%s all  %sn%s none  %sd%s defaults  %s⏎%s install  %sq%s quit\n' \
        "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R"
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
${B}install-tools.sh${R} — install the devsys tool set, by group.

  ./install-tools.sh                 arrow-key picker (space to toggle)
  ./install-tools.sh --list          list groups and contents
  ./install-tools.sh <group>...      install named groups (deps auto-added)
  ./install-tools.sh all             everything except: ${OPT_IN_ONLY[*]}

Options:
  --dry-run     print the commands instead of running them
  -y, --yes     don't prompt for confirmation (implies yes to ai-yolo)
  -l, --list    list groups and exit
  -h, --help    this text

Groups: ${GROUP_ORDER[*]}
EOF
}

# ------------------------------------------------------------------- main ---

main() {
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)      DRY_RUN=1 ;;
      -y|--yes)       ASSUME_YES=1 ;;
      -l|--list)      print_groups; exit 0 ;;
      -h|--help)      usage; exit 0 ;;
      -*)             die "unknown option: $1 (try --help)" ;;
      *)              args+=("$1") ;;
    esac
    shift
  done

  require_debian
  setup_sudo

  local selected=() g
  if [ ${#args[@]} -eq 0 ]; then
    pick_interactive
    selected=("${PICKED[@]}")
  else
    for g in "${args[@]}"; do
      if [ "$g" = "all" ]; then
        mapfile -t -O "${#selected[@]}" selected < <(all_but_opt_in)
      else
        valid_group "$g" || die "unknown group: $g (try --list)"
        selected+=("$g")
      fi
    done
  fi

  [ ${#selected[@]} -gt 0 ] || die "nothing selected"

  local plan=()
  mapfile -t plan < <(resolve "${selected[@]}")

  printf '\n%sPlan%s%s (deps resolved):%s %s\n' "$B" "$R" "$DIM" "$R" "${plan[*]}"
  [ "$DRY_RUN" = 1 ] && printf '%s(dry run — nothing will be installed)%s\n' "$YLW" "$R"

  for g in "${plan[@]}"; do
    run_group "$g"
  done

  step "done"
  info "installed groups: ${plan[*]}"
  info "open a new shell, or: ${B}exec zsh -l${R}"
  have tailscale && info "join a tailnet: ${B}$SUDO tailscale up${R}"
  printf '\n'
}

main "$@"
