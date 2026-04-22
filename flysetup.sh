#!/usr/bin/env bash
# flysetup.sh — interactive one-shot Fly.io deployment for devsys.
#
# Prompts for the handful of values that vary per-deploy, patches
# fly.toml in place, then runs:
#   apps create → volumes create (or reuse) → secrets set → deploy
#
# Safe to re-run: each fly command checks for existing state, so you can
# Ctrl+C mid-setup and resume. Pre-set TS_AUTHKEY in the environment to
# skip the prompt: TS_AUTHKEY=... ./flysetup.sh

set -euo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'

info() { printf "${BLUE}==>${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[ok]${NC}  %s\n" "$*"; }
warn() { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
err()  { printf "${RED}[err]${NC}  %s\n" "$*" >&2; }

# Plain ASCII prompts — ANSI escapes in the prompt string confuse the
# terminal's cursor math, which breaks backspace in some shells/terms.
ask() {
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    read -rp "? ${prompt} [${default}]: " reply
  else
    read -rp "? ${prompt}: " reply
  fi
  echo "${reply:-$default}"
}

ask_visible() {
  local prompt="$1" reply
  read -rp "? ${prompt}: " reply
  echo "$reply"
}

# ---- Preflight --------------------------------------------------------------
command -v fly >/dev/null 2>&1 || {
  err "fly CLI not found. Install: https://fly.io/docs/flyctl/install/"
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  err "python3 not found (used for parsing fly --json output)"
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

# Default org = first entry in `fly orgs list --json`, usually personal.
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

# Fly app names must match [a-z0-9-]. Convert _ → -.
APP_NAME=$(echo "${ORG}-devsys-${HOSTNAME_INPUT}" \
  | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -c 'a-z0-9-' '-' \
  | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')

# Fly volume names accept [a-z0-9_] — hostname is already safe.
VOL_NAME="devsys_${HOSTNAME_INPUT}_vol"

# Region — numbered menu of the most common fly regions + 'custom'.
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
# No default for the region picker — an accidental Enter should re-prompt,
# not silently pick #1.
REGION=""
while [ -z "$REGION" ]; do
  read -rp "? Region # (1-$((${#REGIONS[@]}+1))): " REPLY
  if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "${#REGIONS[@]}" ]; then
    REGION="${REGIONS[$((REPLY-1))]%%|*}"
    ok "region: $REGION (${REGIONS[$((REPLY-1))]##*|})"
  elif [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -eq "$((${#REGIONS[@]}+1))" ]; then
    read -rp "? Region code (3 letters): " REGION
    REGION=$(echo "$REGION" | tr -cd 'a-z0-9')
    [ -z "$REGION" ] && { warn "empty code"; REGION=""; }
  else
    warn "pick a number 1–$((${#REGIONS[@]}+1))"
  fi
done

VOL_SIZE=$(ask "Persistent volume size in GB" "10")

if [ -n "${TS_AUTHKEY:-}" ]; then
  ok "TS_AUTHKEY picked up from environment (not prompting)"
else
  TS_AUTHKEY=$(ask_visible "Tailscale auth key (tskey-auth-...)")
fi
[ -z "$TS_AUTHKEY" ] && { err "TS_AUTHKEY is required."; exit 1; }
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
  warn "app '$APP_NAME' already exists"
  echo "  Options:"
  echo "    [r] Redeploy against existing app  (default, keeps volume/secrets/state)"
  echo "    [d] DELETE the app and recreate    (destructive — loses volume, secrets, everything)"
  REPLY=$(ask "Choice [r/d]" "r")
  case "$(echo "$REPLY" | tr '[:upper:]' '[:lower:]')" in
    d|delete)
      read -rp "! Type '$APP_NAME' to confirm destructive delete: " CONFIRM
      if [ "$CONFIRM" = "$APP_NAME" ]; then
        info "destroying app '$APP_NAME' ..."
        fly apps destroy "$APP_NAME" --yes
        info "Creating fresh app '$APP_NAME' in org '$ORG'..."
        fly apps create "$APP_NAME" --org "$ORG"
      else
        warn "name mismatch — keeping existing app"
      fi
      ;;
    *)
      ok "reusing existing app"
      ;;
  esac
else
  info "Creating app '$APP_NAME' in org '$ORG'..."
  fly apps create "$APP_NAME" --org "$ORG"
fi

VOLS_JSON=$(fly volumes list -a "$APP_NAME" --json 2>/dev/null || echo '[]')
EXISTING_VOL_ID=$(echo "$VOLS_JSON" | python3 -c "
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
ok "secret staged (will apply on deploy)"

# ---- Deploy -----------------------------------------------------------------
echo
info "Deploying (single machine, immediate)..."
fly deploy -a "$APP_NAME" --ha=false --now

# Belt-and-suspenders: handle machines not in 'started' state.
#   stopped  → fly machine start (simple transition)
#   created  → deploy races leave machines stuck here; destroy + redeploy
#   other    → report, leave for the user
info "Checking machine state..."
MACHINES_JSON=$(fly machine list -a "$APP_NAME" --json 2>/dev/null || echo '[]')
NEED_REDEPLOY=0
while IFS=$'\t' read -r MID STATE; do
  [ -z "$MID" ] && continue
  case "$STATE" in
    started)
      ok "machine $MID is started"
      ;;
    stopped)
      info "machine $MID is stopped — starting"
      fly machine start "$MID" -a "$APP_NAME" || warn "start failed"
      ;;
    created)
      warn "machine $MID stuck in 'created' — destroying and redeploying"
      fly machine destroy "$MID" -a "$APP_NAME" --force || true
      NEED_REDEPLOY=1
      ;;
    *)
      warn "machine $MID is in state '$STATE' — not auto-fixing. Inspect: fly status -a $APP_NAME"
      ;;
  esac
done < <(echo "$MACHINES_JSON" | python3 -c "
import sys, json
for m in json.load(sys.stdin):
    print(m['id'], m.get('state','unknown'), sep='\t')
" 2>/dev/null)

if [ "$NEED_REDEPLOY" = "1" ]; then
  info "Redeploying after clearing stuck machine(s)..."
  fly deploy -a "$APP_NAME" --ha=false --now
fi

echo
ok  "Done."
cat <<EOF

Next steps:
  • Wait ~30s for the container to boot and join your tailnet.
  • From any tailnet device:  tailscale ssh root@${HOSTNAME_INPUT}
  • Tail logs:                fly logs -a ${APP_NAME}
  • Shell via fly:            fly ssh console -a ${APP_NAME}
  • Restart (e.g. after new image push):  fly machine restart -a ${APP_NAME} <machine-id>

To wipe it:
  fly apps destroy ${APP_NAME}
EOF
