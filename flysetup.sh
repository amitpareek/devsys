#!/usr/bin/env bash
# flysetup.sh — interactive one-shot Fly.io deployment for devsys.
#
# Prompts for the handful of values that vary per-deploy, patches
# fly.toml in place, then runs the standard fly sequence:
#   apps create → volumes create → secrets set → deploy
#
# Safe to re-run: each fly command checks for existing state first, so
# you can Ctrl+C mid-setup and resume.

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'

info() { printf "${BLUE}==>${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[ok]${NC}  %s\n" "$*"; }
warn() { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
err()  { printf "${RED}[err]${NC}  %s\n" "$*" >&2; }

ask() {
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -rp "$(printf "${YELLOW}?${NC} %s [%s]: " "$prompt" "$default")" reply
    echo "${reply:-$default}"
  else
    read -rp "$(printf "${YELLOW}?${NC} %s: " "$prompt")" reply
    echo "$reply"
  fi
}

ask_secret() {
  local prompt="$1" reply
  read -rsp "$(printf "${YELLOW}?${NC} %s: " "$prompt")" reply
  echo >&2   # newline after hidden input
  echo "$reply"
}

# ---- Preflight --------------------------------------------------------------
command -v fly >/dev/null 2>&1 || {
  err "fly CLI not found. Install: https://fly.io/docs/flyctl/install/"
  exit 1
}

[ -f fly.toml ] || { err "run this from the repo root (fly.toml not found)"; exit 1; }

if ! fly auth whoami >/dev/null 2>&1; then
  info "You're not logged into fly. Running 'fly auth login'..."
  fly auth login
fi

CURRENT_USER=$(fly auth whoami 2>/dev/null || echo unknown)
ok "logged in as: ${CURRENT_USER}"
echo

# ---- Prompts ----------------------------------------------------------------
printf "${BOLD}devsys → Fly.io setup${NC}\n\n"

APP_NAME=$(ask "App name (also becomes tailnet hostname)" "my-devsys")
REGION=$(ask   "Primary region (see: fly platform regions)" "ams")
VOL_SIZE=$(ask "Persistent volume size in GB" "10")
TS_AUTHKEY=$(ask_secret "Tailscale auth key (tskey-auth-...)")

if [ -z "$TS_AUTHKEY" ]; then
  err "TS_AUTHKEY is required."
  exit 1
fi
case "$TS_AUTHKEY" in
  tskey-auth-*) : ;;
  *) warn "TS_AUTHKEY doesn't start with 'tskey-auth-' — continuing anyway." ;;
esac

echo
info "Plan:"
echo "  app            = $APP_NAME"
echo "  region         = $REGION"
echo "  volume size    = ${VOL_SIZE}GB"
echo "  ts authkey     = (hidden)"
echo
read -rp "$(printf "${YELLOW}?${NC} Proceed? [Y/n]: ")" CONFIRM
case "${CONFIRM:-Y}" in [Yy]*|"") : ;; *) err "aborted"; exit 1 ;; esac
echo

# ---- Patch fly.toml ---------------------------------------------------------
info "Patching fly.toml..."
# Back up once in case user wants to diff
[ -f fly.toml.bak ] || cp fly.toml fly.toml.bak

# Portable sed -i: macOS vs GNU
if sed --version >/dev/null 2>&1; then SED_I=(-i); else SED_I=(-i ''); fi

sed "${SED_I[@]}" \
  -e "s|^app\( *\)=.*|app            = \"$APP_NAME\"|" \
  -e "s|^primary_region\( *\)=.*|primary_region = \"$REGION\"|" \
  -e "s|^  HOSTNAME = .*|  HOSTNAME = \"$APP_NAME\"|" \
  -e "s|^  initial_size = .*|  initial_size = \"${VOL_SIZE}gb\"|" \
  fly.toml
ok "fly.toml updated (backup at fly.toml.bak)"

# ---- Fly resources ----------------------------------------------------------
if fly apps list 2>/dev/null | awk '{print $1}' | grep -qx "$APP_NAME"; then
  ok "app '$APP_NAME' already exists"
else
  info "Creating app '$APP_NAME'..."
  fly apps create "$APP_NAME"
fi

VOLS_JSON=$(fly volumes list -a "$APP_NAME" --json 2>/dev/null || echo '[]')
if echo "$VOLS_JSON" | grep -q '"name": *"devsys_home"'; then
  ok "volume 'devsys_home' already exists"
else
  info "Creating volume 'devsys_home' (${VOL_SIZE}GB in $REGION)..."
  fly volumes create devsys_home --size "$VOL_SIZE" --region "$REGION" -a "$APP_NAME" --yes
fi

info "Setting TS_AUTHKEY secret..."
fly secrets set -a "$APP_NAME" --stage TS_AUTHKEY="$TS_AUTHKEY" >/dev/null
ok "secret staged (will apply on next deploy)"

# ---- Deploy -----------------------------------------------------------------
echo
info "Deploying..."
fly deploy -a "$APP_NAME"

echo
ok  "Done."
cat <<EOF

Next steps:
  • Wait ~30s for the container to boot and join your tailnet.
  • From any tailnet device:  tailscale ssh dev@${APP_NAME}
  • Tail logs:                fly logs -a ${APP_NAME}
  • Shell via fly:            fly ssh console -a ${APP_NAME}
  • Restart (e.g. after new image push):  fly machine restart -a ${APP_NAME} <machine-id>

To re-run setup from scratch, delete the app:
  fly apps destroy ${APP_NAME}
EOF
