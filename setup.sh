#!/usr/bin/env bash
# ============================================================================
# setup.sh — first-boot installer for devsys-base containers
#
# Safe to re-run:
#   - First run:  prompts for hostname + tool selection, installs everything
#   - Re-runs:    verifies each selected tool is functional, repairs if not.
#                 Use --reconfigure to change hostname or selection.
#
# State lives in /var/lib/devsys-setup/state.json
# ============================================================================
set -euo pipefail

STATE_DIR="/var/lib/devsys-setup"
STATE_FILE="$STATE_DIR/state.json"
USERNAME="dev"
USER_HOME="/home/$USERNAME"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
BLUE='\033[0;34m'; GRAY='\033[0;37m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${BLUE}[info]${NC} $*"; }
ok()   { echo -e "${GREEN}[ ok ]${NC} $*"; }
skip() { echo -e "${GRAY}[skip]${NC} $*"; }
warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
err()  { echo -e "${RED}[err ]${NC} $*" >&2; }
ask()  { read -rp "$(echo -e "${YELLOW}?${NC} $* ")" REPLY; echo "$REPLY"; }

# ----------------------------------------------------------------------------
# Root check — we need sudo for apt installs. Re-run as dev user otherwise.
# ----------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  if [ "${ALLOW_ROOT:-0}" != "1" ]; then
    err "Run this as user '$USERNAME', not root. Try: su - $USERNAME -c setup.sh"
    exit 1
  fi
fi

if [ "$(whoami)" != "$USERNAME" ] && [ "${ALLOW_ROOT:-0}" != "1" ]; then
  err "setup.sh expects user '$USERNAME' (got '$(whoami)')."
  exit 1
fi

# ----------------------------------------------------------------------------
# Arg parsing
# ----------------------------------------------------------------------------
RECONFIGURE=0
for arg in "$@"; do
  case "$arg" in
    --reconfigure) RECONFIGURE=1 ;;
    --help|-h)
      cat <<EOF
Usage: setup.sh [--reconfigure]

  --reconfigure   re-prompt for hostname and tool selection
                  (without this, re-runs just verify/repair existing selection)
EOF
      exit 0
      ;;
  esac
done

# ----------------------------------------------------------------------------
# State file — TOML-flavored JSON-ish. We grep for keys to keep deps zero.
# Format (line-oriented, one key per line):
#     hostname="customer-a"
#     node=true
#     python=true
#     redis=false
#     ...
# ----------------------------------------------------------------------------
sudo mkdir -p "$STATE_DIR"
sudo chown "$USERNAME":"$USERNAME" "$STATE_DIR"
touch "$STATE_FILE"

state_get() {
  local key="$1"
  grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- | sed 's/^"//; s/"$//'
}
state_set() {
  local key="$1" val="$2"
  local tmp
  tmp=$(mktemp)
  grep -vE "^${key}=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
  if [[ "$val" == "true" || "$val" == "false" ]]; then
    echo "${key}=${val}" >> "$tmp"
  else
    echo "${key}=\"${val}\"" >> "$tmp"
  fi
  mv "$tmp" "$STATE_FILE"
}
state_has() { [ -n "$(state_get "$1")" ]; }

# ============================================================================
# PART 1: Hostname + Tailscale
# ============================================================================
echo
echo -e "${BOLD}devsys-base setup${NC}"
echo

CURRENT_HOSTNAME=$(state_get hostname || true)

if [ -n "$CURRENT_HOSTNAME" ] && [ "$RECONFIGURE" != "1" ]; then
  skip "hostname already set: $CURRENT_HOSTNAME (use --reconfigure to change)"
  TS_HOSTNAME="$CURRENT_HOSTNAME"
else
  DEFAULT_HOSTNAME=$(hostname)
  DEFAULT_HOSTNAME=${CURRENT_HOSTNAME:-$DEFAULT_HOSTNAME}
  HOSTNAME_INPUT=$(ask "Tailnet hostname for this container [$DEFAULT_HOSTNAME]:")
  TS_HOSTNAME=${HOSTNAME_INPUT:-$DEFAULT_HOSTNAME}
  state_set hostname "$TS_HOSTNAME"
  ok "hostname: $TS_HOSTNAME"
fi

# Tailscale up / verify
if tailscale status --peers=false >/dev/null 2>&1; then
  CURRENT_TS_NAME=$(tailscale status --json 2>/dev/null | grep -oE '"HostName":"[^"]+"' | head -n1 | cut -d'"' -f4 || true)
  if [ -n "$CURRENT_TS_NAME" ] && [ "$CURRENT_TS_NAME" != "$TS_HOSTNAME" ]; then
    info "tailnet hostname is '$CURRENT_TS_NAME', want '$TS_HOSTNAME' — updating"
    sudo tailscale set --hostname="$TS_HOSTNAME" --ssh=true || true
  else
    skip "tailscale already up as '$TS_HOSTNAME'"
    sudo tailscale set --ssh=true >/dev/null 2>&1 || true
  fi
else
  info "running 'tailscale up' — open the URL below in a browser to approve"
  echo
  sudo tailscale up \
    --hostname="$TS_HOSTNAME" \
    --ssh=true \
    --accept-dns=true
  ok "tailscale authenticated"
fi

# ============================================================================
# PART 2: Tool selection
# ============================================================================

# Tool catalog: id|label|category
# Categories: runtime, cli, service, shell, knowledge
TOOLS=(
  "node|Node.js LTS (via mise) + npm|runtime"
  "python|Python 3.12 (via mise)|runtime"
  "bun|Bun|runtime"
  "pnpm|pnpm (via corepack)|runtime"
  "gh|GitHub CLI|cli"
  "fly|Fly.io (flyctl)|cli"
  "neon|Neon (neonctl)|cli"
  "claude|Claude Code (with --dangerously-skip-permissions alias)|cli"
  "gemini|Gemini CLI|cli"
  "codex|Codex CLI|cli"
  "opencode|opencode|cli"
  "redis|Redis (auto-start on 127.0.0.1:6379)|service"
  "modern_cli|ripgrep, fd, bat, fzf, eza, htop, ncdu, jq|shell"
  "starship|starship prompt|shell"
  "direnv|direnv|shell"
  "tmux|tmux|shell"
  "lazygit|lazygit (lg alias)|shell"
  "obsidian_export|obsidian-export (vault → markdown)|knowledge"
  "glow|glow (markdown TUI renderer)|knowledge"
)

tool_label() {
  local id="$1"
  for t in "${TOOLS[@]}"; do
    IFS='|' read -r tid label _ <<< "$t"
    [ "$tid" = "$id" ] && { echo "$label"; return; }
  done
}

NEED_SELECTION=0
if [ "$RECONFIGURE" = "1" ]; then NEED_SELECTION=1; fi
if ! state_has "selection_done"; then NEED_SELECTION=1; fi

if [ "$NEED_SELECTION" = "1" ]; then
  echo
  echo -e "${BOLD}Tool selection${NC}"
  echo "Enter numbers separated by spaces, 'all', 'none', or press Enter for 'all'."
  echo

  # Display grouped by category
  declare -A PREV
  for t in "${TOOLS[@]}"; do
    IFS='|' read -r tid _ _ <<< "$t"
    PREV[$tid]=$(state_get "$tid" || echo "false")
  done

  CURRENT_CAT=""
  i=1
  for t in "${TOOLS[@]}"; do
    IFS='|' read -r tid label cat <<< "$t"
    if [ "$cat" != "$CURRENT_CAT" ]; then
      echo
      case "$cat" in
        runtime)   echo -e "  ${BOLD}Runtimes${NC}" ;;
        cli)       echo -e "  ${BOLD}CLIs${NC}" ;;
        service)   echo -e "  ${BOLD}Services${NC}" ;;
        shell)     echo -e "  ${BOLD}Shell & utilities${NC}" ;;
        knowledge) echo -e "  ${BOLD}Knowledge / notes${NC}" ;;
      esac
      CURRENT_CAT="$cat"
    fi
    marker=" "
    [ "${PREV[$tid]}" = "true" ] && marker="*"
    printf "    %2d. [%s] %s\n" "$i" "$marker" "$label"
    i=$((i+1))
  done
  echo
  echo "  (* = previously selected)"
  echo

  SELECTION=$(ask "Selection:")
  SELECTION=${SELECTION:-all}

  # Parse selection → set state flags
  SELECTED_IDS=()
  if [ "$SELECTION" = "none" ]; then
    :
  elif [ "$SELECTION" = "all" ]; then
    for t in "${TOOLS[@]}"; do
      IFS='|' read -r tid _ _ <<< "$t"
      SELECTED_IDS+=("$tid")
    done
  else
    for num in $SELECTION; do
      if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#TOOLS[@]}" ]; then
        idx=$((num-1))
        IFS='|' read -r tid _ _ <<< "${TOOLS[$idx]}"
        SELECTED_IDS+=("$tid")
      else
        warn "ignoring invalid selection: $num"
      fi
    done
  fi

  # Write all tools as true/false
  for t in "${TOOLS[@]}"; do
    IFS='|' read -r tid _ _ <<< "$t"
    found=false
    for sid in "${SELECTED_IDS[@]}"; do
      [ "$sid" = "$tid" ] && { found=true; break; }
    done
    state_set "$tid" "$found"
  done
  state_set selection_done true
fi

# ============================================================================
# PART 3: Install / repair selected tools
# ============================================================================
echo
info "Installing / verifying selected tools..."

# Ensure zsh is the active shell for this user (relevant if someone ran with bash)
if [ "$(getent passwd "$USERNAME" | cut -d: -f7)" != "/bin/zsh" ]; then
  sudo chsh -s /bin/zsh "$USERNAME" 2>/dev/null || true
fi

# Common env so we can call freshly-installed tools later in the same run
export PATH="$USER_HOME/.local/bin:$USER_HOME/.local/share/mise/shims:$USER_HOME/.bun/bin:$USER_HOME/.npm-global/bin:$USER_HOME/.local/share/pnpm:$PATH"

selected() {
  [ "$(state_get "$1")" = "true" ]
}

# ---- Shell / utilities ---------------------------------------------------

if selected modern_cli; then
  need=""
  for pkg in ripgrep fd-find bat fzf htop ncdu jq unzip rsync iputils-ping net-tools dnsutils; do
    dpkg -s "$pkg" >/dev/null 2>&1 || need="$need $pkg"
  done
  if [ -n "$need" ]; then
    info "installing apt packages:$need"
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends $need >/dev/null
  fi
  sudo ln -sf /usr/bin/fdfind /usr/local/bin/fd
  sudo ln -sf /usr/bin/batcat /usr/local/bin/bat
  # eza via its own repo
  if ! command -v eza >/dev/null; then
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://raw.githubusercontent.com/eza-community/eza/main/deb.asc \
      | sudo gpg --dearmor -o /etc/apt/keyrings/gierens.gpg
    echo "deb [signed-by=/etc/apt/keyrings/gierens.gpg] http://deb.gierens.de stable main" \
      | sudo tee /etc/apt/sources.list.d/gierens.list >/dev/null
    sudo chmod 644 /etc/apt/keyrings/gierens.gpg /etc/apt/sources.list.d/gierens.list
    sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends eza >/dev/null
  fi
  ok "modern CLI utilities"
else
  skip "modern_cli"
fi

if selected direnv; then
  if ! command -v direnv >/dev/null; then
    sudo apt-get install -y --no-install-recommends direnv >/dev/null
  fi
  ok "direnv"
else
  skip "direnv"
fi

if selected tmux; then
  if ! command -v tmux >/dev/null; then
    sudo apt-get install -y --no-install-recommends tmux >/dev/null
  fi
  ok "tmux"
else
  skip "tmux"
fi

if selected starship; then
  if ! command -v starship >/dev/null; then
    curl -fsSL https://starship.rs/install.sh | sudo sh -s -- --yes --bin-dir /usr/local/bin >/dev/null
  fi
  ok "starship"
else
  skip "starship"
fi

if selected lazygit; then
  if ! command -v lazygit >/dev/null; then
    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in arm64) LG_ARCH=arm64 ;; amd64) LG_ARCH=x86_64 ;; *) err "unsupported arch $ARCH"; exit 1 ;; esac
    LG_VERSION=$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -oP '"tag_name": "v\K[^"]+')
    curl -fsSL -o /tmp/lazygit.tgz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LG_VERSION}_Linux_${LG_ARCH}.tar.gz"
    tar -xzf /tmp/lazygit.tgz -C /tmp lazygit
    sudo install /tmp/lazygit /usr/local/bin/lazygit
    rm -f /tmp/lazygit /tmp/lazygit.tgz
  fi
  ok "lazygit"
else
  skip "lazygit"
fi

# ---- Runtimes ------------------------------------------------------------

if selected node || selected python || selected pnpm; then
  # mise is needed for node/python; install once
  if [ ! -x "$USER_HOME/.local/bin/mise" ]; then
    curl -fsSL https://mise.run | sh
  fi
fi

if selected node; then
  if ! "$USER_HOME/.local/bin/mise" which node >/dev/null 2>&1; then
    "$USER_HOME/.local/bin/mise" use --global node@lts
    "$USER_HOME/.local/bin/mise" reshim
  fi
  # npm prefix → user dir, no sudo for globals
  mkdir -p "$USER_HOME/.npm-global"
  "$USER_HOME/.local/share/mise/shims/npm" config set prefix "$USER_HOME/.npm-global" >/dev/null 2>&1 || true
  ok "Node.js LTS + npm (prefix: ~/.npm-global)"
else
  skip "node"
fi

if selected python; then
  if ! "$USER_HOME/.local/bin/mise" which python >/dev/null 2>&1; then
    "$USER_HOME/.local/bin/mise" use --global python@3.12
    "$USER_HOME/.local/bin/mise" reshim
  fi
  ok "Python 3.12"
else
  skip "python"
fi

if selected bun; then
  if ! command -v bun >/dev/null && [ ! -x "$USER_HOME/.bun/bin/bun" ]; then
    curl -fsSL https://bun.sh/install | bash
  fi
  ok "Bun (install dir: ~/.bun)"
else
  skip "bun"
fi

if selected pnpm; then
  if ! command -v pnpm >/dev/null; then
    # corepack ships with Node; enables pnpm
    if command -v corepack >/dev/null; then
      corepack enable 2>/dev/null || true
      corepack prepare pnpm@latest --activate 2>/dev/null || true
    else
      warn "corepack not available — install Node first (selection: node)"
    fi
  fi
  # Explicit defaults — no drift
  mkdir -p "$USER_HOME/.local/share/pnpm"
  if command -v pnpm >/dev/null; then
    pnpm config set store-dir "$USER_HOME/.local/share/pnpm/store" >/dev/null 2>&1 || true
    pnpm config set global-dir "$USER_HOME/.local/share/pnpm/global" >/dev/null 2>&1 || true
    pnpm config set global-bin-dir "$USER_HOME/.local/share/pnpm" >/dev/null 2>&1 || true
  fi
  ok "pnpm (store: ~/.local/share/pnpm)"
else
  skip "pnpm"
fi

# ---- CLIs (apt-based) ----------------------------------------------------

if selected gh; then
  if ! command -v gh >/dev/null; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg
    sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends gh >/dev/null
  fi
  ok "gh (run 'gh auth login' on first use)"
else
  skip "gh"
fi

if selected fly; then
  if ! command -v fly >/dev/null; then
    curl -fsSL https://fly.io/install.sh | FLYCTL_INSTALL="$USER_HOME/.fly" sh
    # Use a stable location; symlink into ~/.local/bin
    mkdir -p "$USER_HOME/.local/bin"
    ln -sf "$USER_HOME/.fly/bin/flyctl" "$USER_HOME/.local/bin/fly"
    ln -sf "$USER_HOME/.fly/bin/flyctl" "$USER_HOME/.local/bin/flyctl"
  fi
  ok "flyctl (run 'fly auth login' on first use)"
else
  skip "fly"
fi

# ---- CLIs (npm-based: neon + AI CLIs) ------------------------------------

npm_install_global() {
  local pkg="$1"
  local check="$2"
  if ! command -v "$check" >/dev/null 2>&1; then
    if command -v npm >/dev/null; then
      npm install -g "$pkg" >/dev/null 2>&1 || { err "npm install -g $pkg failed"; return 1; }
    else
      err "npm not available — select 'node' first"
      return 1
    fi
  fi
}

if selected neon;     then npm_install_global "neonctl" "neonctl" && ok "neonctl (run 'neonctl auth' on first use)"; else skip "neon"; fi
if selected claude;   then npm_install_global "@anthropic-ai/claude-code" "claude" && ok "claude (aliased with --dangerously-skip-permissions)"; else skip "claude"; fi
if selected gemini;   then npm_install_global "@google/gemini-cli" "gemini" && ok "gemini"; else skip "gemini"; fi
if selected codex;    then npm_install_global "@openai/codex" "codex" && ok "codex"; else skip "codex"; fi
if selected opencode; then npm_install_global "opencode-ai" "opencode" && ok "opencode"; else skip "opencode"; fi

# ---- Service: Redis ------------------------------------------------------

if selected redis; then
  if ! command -v redis-server >/dev/null; then
    sudo apt-get install -y --no-install-recommends redis-server >/dev/null
  fi
  # Start it now (entrypoint will start it on future container boots)
  if ! pgrep -x redis-server >/dev/null; then
    sudo mkdir -p /var/lib/redis /var/log/redis
    sudo chown redis:redis /var/lib/redis /var/log/redis
    sudo redis-server \
      --bind 127.0.0.1 \
      --port 6379 \
      --daemonize yes \
      --dir /var/lib/redis \
      --logfile /var/log/redis/redis.log \
      --save "3600 1 300 100 60 10000"
    sleep 0.3
  fi
  if redis-cli ping 2>/dev/null | grep -q PONG; then
    ok "redis (127.0.0.1:6379)"
  else
    warn "redis-server installed but not responding"
  fi
else
  skip "redis"
fi

# ---- Knowledge tools -----------------------------------------------------

if selected obsidian_export; then
  if ! command -v obsidian-export >/dev/null; then
    # Prebuilt binary from GitHub releases (Rust project)
    ARCH=$(dpkg --print-architecture)
    case "$ARCH" in
      arm64) OE_ARCH=aarch64-unknown-linux-gnu ;;
      amd64) OE_ARCH=x86_64-unknown-linux-gnu ;;
      *)     warn "unsupported arch for obsidian-export: $ARCH"; OE_ARCH="" ;;
    esac
    if [ -n "$OE_ARCH" ]; then
      OE_URL=$(curl -fsSL https://api.github.com/repos/zoni/obsidian-export/releases/latest \
        | grep -oE '"browser_download_url":[^,]*'"$OE_ARCH"'[^,]*\.tar\.xz"' \
        | head -n1 | cut -d'"' -f4)
      if [ -n "$OE_URL" ]; then
        curl -fsSL -o /tmp/oe.tar.xz "$OE_URL"
        tar -xJf /tmp/oe.tar.xz -C /tmp
        OE_BIN=$(find /tmp -maxdepth 2 -type f -name obsidian-export | head -n1)
        if [ -n "$OE_BIN" ]; then
          sudo install "$OE_BIN" /usr/local/bin/obsidian-export
        fi
        rm -rf /tmp/oe.tar.xz /tmp/obsidian-export-*
      else
        warn "could not locate obsidian-export release asset"
      fi
    fi
  fi
  if command -v obsidian-export >/dev/null; then
    ok "obsidian-export"
  fi
else
  skip "obsidian-export"
fi

if selected glow; then
  if ! command -v glow >/dev/null; then
    # Charm repo
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
      | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
    sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends glow >/dev/null
  fi
  ok "glow"
else
  skip "glow"
fi

# ============================================================================
# PART 4: Shell config (zshrc) — rewritten each run so it always matches state
# ============================================================================
info "Writing ~/.zshrc and ~/.zshenv..."

# .zshenv is read even by non-login shells — critical for tailscale ssh one-liners
cat > "$USER_HOME/.zshenv" <<'ZSHENV'
# Generated by devsys setup.sh — edits survive re-runs ONLY if below marker
typeset -U path PATH
path=(
  "$HOME/.local/bin"
  "$HOME/.local/share/mise/shims"
  "$HOME/.bun/bin"
  "$HOME/.npm-global/bin"
  "$HOME/.local/share/pnpm"
  $path
)
export PATH

# Tool default dirs (explicit to prevent drift)
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
export PNPM_HOME="$HOME/.local/share/pnpm"
export BUN_INSTALL="$HOME/.bun"
export MISE_DATA_DIR="$HOME/.local/share/mise"

# ---- USER CUSTOMIZATIONS BELOW (preserved across re-runs) ----
ZSHENV

cat > "$USER_HOME/.zshrc" <<'ZSHRC'
# Generated by devsys setup.sh
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE
ZSHRC

# Conditional activations
if selected node || selected python; then
  cat >> "$USER_HOME/.zshrc" <<'EOF'
eval "$(~/.local/bin/mise activate zsh 2>/dev/null || true)"
EOF
fi
if selected direnv; then
  echo 'eval "$(direnv hook zsh 2>/dev/null || true)"' >> "$USER_HOME/.zshrc"
fi
if selected starship; then
  echo 'eval "$(starship init zsh 2>/dev/null || true)"' >> "$USER_HOME/.zshrc"
fi

# Aliases
cat >> "$USER_HOME/.zshrc" <<'EOF'

# Aliases
EOF
if selected modern_cli; then
  cat >> "$USER_HOME/.zshrc" <<'EOF'
alias ls='eza --group-directories-first'
alias ll='eza -lah --group-directories-first --git'
alias tree='eza --tree'
alias cat='bat --paging=never'
EOF
fi
if selected lazygit; then
  echo "alias lg='lazygit'" >> "$USER_HOME/.zshrc"
fi
if selected claude; then
  echo "alias claude='claude --dangerously-skip-permissions'" >> "$USER_HOME/.zshrc"
fi

# cd to work on login
cat >> "$USER_HOME/.zshrc" <<'EOF'

# Land in ~/work
cd ~/work 2>/dev/null || true

# ---- USER CUSTOMIZATIONS BELOW (preserved across re-runs) ----
EOF

ok "wrote ~/.zshrc and ~/.zshenv"

# ============================================================================
# PART 5: Working dirs
# ============================================================================
mkdir -p "$USER_HOME/work"
# Vault dir is bind-mounted by compose; just ensure the mountpoint exists.
# The actual vault (bsvault / personal) is mounted at ~/vault regardless of name.
mkdir -p "$USER_HOME/vault"

# ============================================================================
# Done
# ============================================================================
state_set setup_complete true
state_set setup_timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
ok "Setup complete."
echo
echo "  Tailnet hostname: $TS_HOSTNAME"
echo "  User:             $USERNAME"
echo "  State file:       $STATE_FILE"
echo
echo "Next:"
echo "  1. Exit this shell (type 'exit')"
echo "  2. From any tailnet device: tailscale ssh $USERNAME@$TS_HOSTNAME"
echo "  3. First-use auth for installed tools:"
selected gh     && echo "       gh auth login"
selected fly    && echo "       fly auth login"
selected neon   && echo "       neonctl auth"
selected claude && echo "       claude            # opens browser auth"
selected gemini && echo "       gemini            # opens browser auth"
selected codex  && echo "       codex             # opens browser auth"
echo
echo "Re-run this script any time to:"
echo "  - verify and repair tools:     setup.sh"
echo "  - change hostname / selection: setup.sh --reconfigure"
