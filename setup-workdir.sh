#!/usr/bin/env bash
#
# setup-workdir.sh — create ~/work and land there on every interactive login.
#
# Standalone: does not need install-tools.sh or anything else from devsys.
# Creates the directory for root, for every login account, and in /etc/skel so
# accounts you add later inherit it. Then wires a guarded `cd` into the
# system-wide bash and zsh rc files.
#
#   sudo ./setup-workdir.sh              # set it up
#   sudo ./setup-workdir.sh --undo       # remove the cd (keeps your files)
#   sudo DEVSYS_WORKDIR=projects ./setup-workdir.sh
#
# Re-running is safe. Nothing is ever deleted — --undo only removes the cd
# snippet, never the directory or anything in it.

set -euo pipefail

NAME="${DEVSYS_WORKDIR:-work}"
MARK="# >>> devsys workdir >>>"
MEND="# <<< devsys workdir <<<"
UNDO=0
[ "${1:-}" = "--undo" ] && UNDO=1

if [ "$(id -u)" != 0 ]; then
  echo "error: run with sudo — it writes to /etc and other users' homes" >&2
  echo "       sudo $0 ${1:-}" >&2
  exit 1
fi

# root, every real login account, and /etc/skel for future accounts.
homes() {
  printf 'root:/root\n'
  getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $6 ~ /^\// { print $1 ":" $6 }'
  printf 'root:/etc/skel\n'
}

# The snippet itself. Guarded on $PWD being $HOME so that `cd /var/log && zsh`
# is not yanked away from where you deliberately are — only a fresh login,
# which always starts in the home directory, triggers the cd.
snippet() {
  cat <<EOSNIP
$MARK
if [ -d "\$HOME/$NAME" ] && [ "\$PWD" = "\$HOME" ]; then
  cd "\$HOME/$NAME" || true
fi
$MEND
EOSNIP
}

wire() {
  local f="$1"
  if [ "$UNDO" = 1 ]; then
    [ -f "$f" ] || return 0
    grep -qF "$MARK" "$f" || { echo "  · $f — nothing to undo"; return 0; }
    sed -i "\|^${MARK}\$|,\|^${MEND}\$|d" "$f"
    echo "  ✓ $f — cd removed"
    return 0
  fi
  # Only wire zsh if zsh is actually installed.
  if [ "$f" = /etc/zsh/zshrc ] && ! command -v zsh >/dev/null 2>&1; then
    echo "  · zsh not installed — skipping $f"
    return 0
  fi
  install -d -m 755 "$(dirname "$f")"
  [ -f "$f" ] || touch "$f"
  if grep -qF "$MARK" "$f"; then
    echo "  · $f — already wired"
    return 0
  fi
  { printf '\n'; snippet; } >>"$f"
  echo "  ✓ $f — wired"
}

if [ "$UNDO" = 0 ]; then
  echo "Creating \$HOME/$NAME:"
  made=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    user="${entry%%:*}"; home="${entry#*:}"
    [ "$home" = /etc/skel ] || [ -d "$home" ] || continue
    if [ -d "$home/$NAME" ]; then
      echo "  · $home/$NAME — exists"
      continue
    fi
    install -d -m 755 "$home/$NAME"
    if [ "$user" != root ]; then
      chown "$user:$(id -gn "$user" 2>/dev/null || echo "$user")" "$home/$NAME" || true
    fi
    echo "  ✓ $home/$NAME — created (owner: $user)"
    made=$((made + 1))
  done <<EOF
$(homes)
EOF
  [ "$made" = 0 ] && echo "  (nothing new to create)"
  echo
  echo "Wiring the login cd:"
else
  echo "Removing the login cd (directories are left untouched):"
fi

wire /etc/bash.bashrc
wire /etc/zsh/zshrc

echo
if [ "$UNDO" = 1 ]; then
  echo "Done. Reconnect and you will land in your home directory again."
else
  echo "Done. Reconnect (or run: exec \$SHELL -l) and you will land in \$HOME/$NAME."
  echo "Non-interactive commands — ssh host 'cmd', scp, rsync — are unaffected."
fi
