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
  # Visible read: some terminals block paste into silent reads, which is
  # painful for long auth keys. If you'd rather not echo, pre-set the
  # env var before running: TS_AUTHKEY=... ./flysetup.sh
  local prompt="$1" reply
  read -rp "$(printf "${YELLOW}?${NC} %s: " "$prompt")" reply
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

# Auto-detect default org (the first one in `fly orgs list`, usually your
# personal one). User can override.
DEFAULT_ORG=$(fly orgs list --json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(next(iter(d))) if d else print('personal')" \
  2>/dev/null || echo personal)

ORG=$(ask "Fly org slug (prefix for the app name)" "$DEFAULT_ORG")

# Hostname: lowercase, alphanumeric + underscore only. Re-prompt on invalid.
HOSTNAME_INPUT=""
while [ -z "$HOSTNAME_INPUT" ]; do
  HOSTNAME_INPUT=$(ask "Hostname (lowercase, a-z 0-9 _ only — e.g. cksys)" "devbox")
  if ! printf '%s' "$HOSTNAME_INPUT" | grep -qE '^[a-z0-9_]+$'; then
    err "'$HOSTNAME_INPUT' — only a-z, 0-9, and _ are allowed."
    HOSTNAME_INPUT=""
  fi
done

# Fly app names must match [a-z0-9-]. Sanitize (underscores in hostname
# become hyphens in the app name for DNS-friendliness).
APP_NAME=$(echo "${ORG}-devsys-${HOSTNAME_INPUT}" \
  | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -c 'a-z0-9-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')

# Fly volume names accept [a-z0-9_] — hostname is already safe.
VOL_NAME="devsys_${HOSTNAME_INPUT}_vol"

# Region — pick from a curated list of common fly regions. Type 'custom'
# to enter anything else (full list: fly platform regions).
echo
echo -e "${BOLD}Region:${NC}"
REGIONS=(
  "ams|Amsterdam, Netherlands"
  "bom|Mumbai, India"
  "cdg|Paris, France"
  "dfw|Dallas, Texas"
  "fra|Frankfurt, Germany"
  "iad|Ashburn, Virginia (US East)"
  "lax|Los Angeles, California"
  "lhr|London, UK"
  "nrt|Tokyo, Japan"
  "ord|Chicago, Illinois"
  "sea|Seattle, Washington"
  "sin|Singapore"
  "syd|Sydney, Australia"
  "yyz|Toronto, Canada"
)
i=1
for r in "${REGIONS[@]}"; do
  printf "  %2d. %-4s  %s\n" "$i" "${r%%|*}" "${r##*|}"
  i=$((i+1))
done
printf "  %2d. custom (type a code)\n" "$i"
echo
REGION=""
while [ -z "$REGION" ]; do
  REPLY=$(ask "Region #" "1")
  if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#REGIONS[@]}" ]; then
    REGION="${REGIONS[$((REPLY-1))]%%|*}"
  elif [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -eq "$((${#REGIONS[@]}+1))" ]; then
    REGION=$(ask "Region code (3 letters)" "")
    [ -z "$REGION" ] && REGION=""
  else
    warn "Pick a number 1–$((${#REGIONS[@]}+1))"
  fi
done

VOL_SIZE=$(ask "Persistent volume size in GB" "10")

# Use env-provided TS_AUTHKEY if present (so you can pipe it in from a
# password manager); otherwise prompt.
if [ -n "${TS_AUTHKEY:-}" ]; then
  ok "TS_AUTHKEY picked up from environment (not prompting)"
else
  TS_AUTHKEY=$(ask_secret "Tailscale auth key (tskey-auth-...)")
fi

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
echo "  org            = $ORG"
echo "  hostname       = $HOSTNAME_INPUT"
echo "  fly app        = $APP_NAME"
echo "  region         = $REGION"
echo "  volume         = $VOL_NAME (${VOL_SIZE}GB)"
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
  -e "s|^  HOSTNAME = .*|  HOSTNAME = \"$HOSTNAME_INPUT\"|" \
  -e "s|^  source       = .*|  source       = \"$VOL_NAME\"|" \
  -e "s|^  initial_size = .*|  initial_size = \"${VOL_SIZE}gb\"|" \
  fly.toml
ok "fly.toml updated (backup at fly.toml.bak)"

# ---- Fly resources ----------------------------------------------------------
if fly apps list 2>/dev/null | awk '{print $1}' | grep -qx "$APP_NAME"; then
  ok "app '$APP_NAME' already exists"
else
  info "Creating app '$APP_NAME' in org '$ORG'..."
  fly apps create "$APP_NAME" --org "$ORG"
fi

VOLS_JSON=$(fly volumes list -a "$APP_NAME" --json 2>/dev/null || echo '[]')
EXISTING_VOL_ID=$(echo "$VOLS_JSON" \
  | python3 -c "
import sys, json
for v in json.load(sys.stdin):
    if v.get('name') == '$VOL_NAME':
        print(v['id']); break
" 2>/dev/null || echo "")

if [ -n "$EXISTING_VOL_ID" ]; then
  warn "volume '$VOL_NAME' already exists (id: $EXISTING_VOL_ID)"
  echo "  Options:"
  echo "    [k] Keep existing volume and its data  (default, safe)"
  echo "    [d] DELETE the existing volume and create a fresh one (destructive)"
  REPLY=$(ask "Choice [k/d]" "k")
  case "$(echo "$REPLY" | tr '[:upper:]' '[:lower:]')" in
    d|delete)
      read -rp "$(printf "${RED}!${NC} Type '%s' to confirm destructive delete: " "$VOL_NAME")" CONFIRM
      if [ "$CONFIRM" = "$VOL_NAME" ]; then
        info "destroying volume $EXISTING_VOL_ID ..."
        fly volumes destroy "$EXISTING_VOL_ID" -a "$APP_NAME" --yes
        info "creating fresh volume '$VOL_NAME' (${VOL_SIZE}GB in $REGION)..."
        fly volumes create "$VOL_NAME" --size "$VOL_SIZE" --region "$REGION" -a "$APP_NAME" --yes
      else
        warn "name mismatch — keeping existing volume"
      fi
      ;;
    *)
      ok "keeping existing volume"
      ;;
  esac
else
  info "Creating volume '$VOL_NAME' (${VOL_SIZE}GB in $REGION)..."
  fly volumes create "$VOL_NAME" --size "$VOL_SIZE" --region "$REGION" -a "$APP_NAME" --yes
fi

info "Setting TS_AUTHKEY secret..."
fly secrets set -a "$APP_NAME" --stage TS_AUTHKEY="$TS_AUTHKEY" >/dev/null
ok "secret staged (will apply on next deploy)"

# ---- Deploy -----------------------------------------------------------------
echo
info "Deploying (single machine, immediate)..."
fly deploy -a "$APP_NAME" --ha=false --now

# Belt-and-suspenders: make sure any stopped machine is actually running.
# Fresh deploys sometimes leave the machine in 'stopped' if the volume
# attach shuffles things around.
info "Ensuring machine is started..."
fly machine list -a "$APP_NAME" --json 2>/dev/null \
  | python3 -c "
import sys, json
for m in json.load(sys.stdin):
    if m.get('state') != 'started':
        print(m['id'])
" 2>/dev/null \
  | while read -r MID; do
      [ -n "$MID" ] && fly machine start "$MID" -a "$APP_NAME" || true
    done
ok "machine is running"

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
