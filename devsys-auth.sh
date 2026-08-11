#!/usr/bin/env bash
#
# devsys-auth — move tool logins between your own machines, encrypted.
#
# Log in once on one box, export an encrypted bundle, import it on the
# others. Covers the CLIs whose auth is just files under $HOME: gh, fly,
# neonctl, claude, gemini, codex, opencode, docker, npm.
#
#   devsys-auth list                 # what credentials exist here
#   devsys-auth export               # write ./devsys-auth.age
#   devsys-auth export -o ~/work/a.age
#   devsys-auth import ~/work/a.age  # restore onto this box
#
# Encryption is mandatory and uses age. By default it prompts for a
# passphrase; pass -r <age-recipient> to encrypt to a public key instead.
#
# Tailscale is NOT included: a tailnet node's identity is per-machine and
# cannot be copied. Run `sudo tailscale up` on each box.
#
# The bundle is equivalent to a password vault for every account it holds.
# Keep it 0600, never commit it, and delete stale copies.

set -euo pipefail

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YLW=$'\033[33m'
  RED=$'\033[31m'; CYN=$'\033[36m'; R=$'\033[0m'
else
  B=''; DIM=''; GRN=''; YLW=''; RED=''; CYN=''; R=''
fi

info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$GRN" "$R" "$*"; }
warn() { printf '%s!%s  %s\n' "$YLW" "$R" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }
step() { printf '\n%s==>%s %s%s%s\n' "$CYN" "$R" "$B" "$*" "$R"; }

# Credential paths, relative to $HOME. Only what is actually auth material —
# not general config, and not history files that happen to sit alongside.
# Format: path|label
CRED_PATHS=(
  '.config/gh/hosts.yml|GitHub CLI'
  '.fly/config.yml|Fly.io'
  '.config/neonctl/credentials.json|Neon'
  '.claude/.credentials.json|Claude Code'
  '.gemini/oauth_creds.json|Gemini CLI'
  '.gemini/google_accounts.json|Gemini CLI (account)'
  '.codex/auth.json|Codex CLI'
  '.local/share/opencode/auth.json|opencode'
  '.docker/config.json|Docker registries'
  '.npmrc|npm registry token'
)

RECIPIENT=""
OUT=""
IDENTITY=""
DEFAULT_IDENTITY="$HOME/.config/age/keys.txt"

need_age() {
  command -v age >/dev/null 2>&1 || die "age is not installed.
       sudo apt-get install -y age
   or: sudo install-tools.sh auth"
}

# Credentials are per-user. Running under sudo would operate on root's home,
# which is almost never what someone means.
check_user() {
  if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != root ]; then
    die "don't run this under sudo — it would use root's credentials, not yours.
       run it as yourself:  devsys-auth $*"
  fi
  [ -n "${HOME:-}" ] || die "HOME is not set"
}

# Echo the subset of CRED_PATHS that exists, as "path|label".
present_creds() {
  local entry path label
  for entry in "${CRED_PATHS[@]}"; do
    IFS='|' read -r path label <<<"$entry"
    [ -s "$HOME/$path" ] && printf '%s|%s\n' "$path" "$label"
  done
}

cmd_list() {
  step "credentials on this box ($(id -un)@$(hostname))"
  local found=0 entry path label
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    IFS='|' read -r path label <<<"$entry"
    printf '    %s✓%s %-38s %s%s%s\n' "$GRN" "$R" "$path" "$DIM" "$label" "$R"
    found=$((found + 1))
  done <<<"$(present_creds)"

  local entry2 path2 label2
  for entry2 in "${CRED_PATHS[@]}"; do
    IFS='|' read -r path2 label2 <<<"$entry2"
    [ -s "$HOME/$path2" ] || printf '    %s·  %-38s %s%s\n' "$DIM" "$path2" "$label2" "$R"
  done

  printf '\n'
  if [ "$found" = 0 ]; then
    info "nothing to export yet — log in to something first"
  else
    info "$found credential file(s) would be included in an export"
  fi
  info "${DIM}tailscale is excluded: node identity is per-machine${R}"
  printf '\n'
}

cmd_export() {
  need_age
  local dest="${OUT:-./devsys-auth.age}"
  step "export credentials -> $dest"

  local list=() entry path label
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    IFS='|' read -r path label <<<"$entry"
    list+=("$path")
    printf '    %s+%s %-38s %s%s%s\n' "$GRN" "$R" "$path" "$DIM" "$label" "$R"
  done <<<"$(present_creds)"

  [ ${#list[@]} -gt 0 ] || die "no credential files found — nothing to export"

  printf '\n'
  warn "this bundle grants full access to every account above."
  warn "treat it like a password vault: 0600, never committed, deleted when stale."
  printf '\n'

  local tmp; tmp="$(mktemp)"; chmod 600 "$tmp"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT

  tar -czf "$tmp" -C "$HOME" -- "${list[@]}"

  if [ -n "$RECIPIENT" ]; then
    age -r "$RECIPIENT" -o "$dest" "$tmp"
  else
    info "choose a passphrase — you'll need it on the other machines"
    age -p -o "$dest" "$tmp"
  fi
  chmod 600 "$dest"
  rm -f "$tmp"; trap - EXIT

  ok "wrote $dest ($(du -h "$dest" | cut -f1), mode 0600)"
  printf '\n'
  info "move it to another box and run:  ${B}devsys-auth import $(basename "$dest")${R}"
  info "over your tailnet, ~/work is already shared — dropping it there works."
  printf '\n'
}

cmd_import() {
  need_age
  local src="${1:-}"
  [ -n "$src" ] || die "usage: devsys-auth import <bundle.age>"
  [ -s "$src" ] || die "no such bundle: $src"
  step "import credentials from $src"

  local tmp; tmp="$(mktemp)"; chmod 600 "$tmp"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT

  # A bundle made with -r needs the matching identity; a passphrase bundle
  # needs no -i at all. Fall back to the conventional age key location.
  local ident="$IDENTITY"
  [ -z "$ident" ] && [ -s "$DEFAULT_IDENTITY" ] && ident="$DEFAULT_IDENTITY"
  if [ -n "$ident" ]; then
    [ -s "$ident" ] || die "no such identity file: $ident"
    info "decrypting with identity $ident"
    age -d -i "$ident" -o "$tmp" "$src" \
      || die "decryption failed — wrong identity for this bundle?"
  else
    age -d -o "$tmp" "$src" \
      || die "decryption failed — wrong passphrase?
       if this bundle was made with -r, pass the matching key: -i <keyfile>"
  fi

  info "bundle contains:"
  tar -tzf "$tmp" | sed 's/^/      /'
  printf '\n'

  # Anything we'd overwrite gets a timestamped backup first.
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  local backed_up=0 f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -e "$HOME/$f" ]; then
      cp -a "$HOME/$f" "$HOME/$f.bak-$stamp"
      backed_up=$((backed_up + 1))
    fi
  done <<<"$(tar -tzf "$tmp" | grep -v '/$')"
  [ "$backed_up" -gt 0 ] && info "backed up $backed_up existing file(s) as *.bak-$stamp"

  if [ -t 0 ]; then
    printf '    %sExtract into %s now?%s [y/N] ' "$B" "$HOME" "$R"
    local ans; read -r ans
    case "$ans" in [yY]|[yY][eE][sS]) ;; *) info "aborted"; rm -f "$tmp"; trap - EXIT; exit 0 ;; esac
  fi

  tar -xzf "$tmp" -C "$HOME"
  rm -f "$tmp"; trap - EXIT

  # Credential files must not be group/world readable.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -e "$HOME/$f" ] && chmod 600 "$HOME/$f"
  done <<<"$(present_creds | cut -d'|' -f1)"

  ok "credentials restored into $HOME"
  printf '\n'
  info "verify with: ${B}install-tools.sh --check-logins${R}"
  info "tailscale still needs: ${B}sudo tailscale up${R}"
  printf '\n'
}

usage() {
  cat <<EOF
${B}devsys-auth${R} — move tool logins between your own machines, encrypted.

  devsys-auth list                    show which credentials exist here
  devsys-auth export [-o FILE] [-r R] write an encrypted bundle
  devsys-auth import <FILE> [-i KEY]  restore a bundle onto this box

Options:
  -o FILE   output path for export (default ./devsys-auth.age)
  -r R      encrypt to an age recipient (public key) instead of a passphrase
  -i KEY    age identity file for import (default \$HOME/.config/age/keys.txt
            if it exists; omit entirely for passphrase bundles)
  -h        this text

Covers: $(printf '%s ' "${CRED_PATHS[@]%%|*}")

Excludes tailscale — node identity is per-machine, so run
\`sudo tailscale up\` on each box.
EOF
}

main() {
  local cmd="${1:-}"
  if [ $# -gt 0 ]; then shift; fi

  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) OUT="${2:-}"; shift ;;
      -r) RECIPIENT="${2:-}"; shift ;;
      -i) IDENTITY="${2:-}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  case "$cmd" in
    list)   check_user list;   cmd_list ;;
    export) check_user export; cmd_export ;;
    import) check_user import; cmd_import "${args[0]:-}" ;;
    -h|--help|help|'') usage ;;
    *) die "unknown command: $cmd (try --help)" ;;
  esac
}

main "$@"
