#!/usr/bin/env bash
# z - tmux session/window manager with arrow-key selection
# - Outside tmux: manages sessions
# - Inside tmux:  manages windows of the current session
# Usage: just type `z`

set -e

if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is not installed. Install it first:"
    echo "  Debian/Ubuntu: apt install tmux"
    echo "  Fedora/RHEL:   dnf install tmux"
    echo "  macOS:         brew install tmux"
    exit 1
fi

DIM=$'\033[2;37m'
RESET=$'\033[0m'

# Detect mode based on whether we're inside tmux
if [ -n "$TMUX" ]; then
    MODE="window"
    UNIT="window"
    UNITS="windows"
else
    MODE="session"
    UNIT="session"
    UNITS="sessions"
fi

# The shell tmux should run inside new sessions/windows
USER_SHELL="${SHELL:-/bin/bash}"

# Build a shell command that cd's into a directory then execs the user's shell.
# Uses single-quote escaping to survive paths with spaces or special chars.
build_cd_exec() {
    local dir="$1"
    # Escape single quotes in the path: ' becomes '\''
    local escaped="${dir//\'/\'\\\'\'}"
    echo "cd '$escaped' && exec '$USER_SHELL'"
}

# ----- Arrow-key menu helper -----
# Usage: select_menu "Title" DISABLED_FLAGS option1 option2 ...
select_menu() {
    local title="$1"
    local disabled_str="$2"
    shift 2
    local options=("$@")
    local count=${#options[@]}
    local current=0
    local key rest i

    local -a disabled
    if [ -z "$disabled_str" ]; then
        for ((i=0; i<count; i++)); do disabled[i]=0; done
    else
        read -ra disabled <<< "$disabled_str"
        for ((i=${#disabled[@]}; i<count; i++)); do disabled[i]=0; done
    fi

    for ((i=0; i<count; i++)); do
        if [ "${disabled[i]}" -eq 0 ]; then
            current=$i
            break
        fi
    done

    move_cursor() {
        local direction=$1
        local steps=0
        while [ $steps -lt $count ]; do
            current=$((current + direction))
            [ $current -lt 0 ] && current=$((count - 1))
            [ $current -ge $count ] && current=0
            if [ "${disabled[current]}" -eq 0 ]; then
                return
            fi
            ((steps++))
        done
    }

    render_option() {
        local idx=$1
        if [ "${disabled[idx]}" -eq 1 ]; then
            if [ "$idx" -eq "$current" ]; then
                echo "  ${DIM}> ${options[$idx]} (disabled)${RESET}"
            else
                echo "  ${DIM}  ${options[$idx]} (disabled)${RESET}"
            fi
        else
            if [ "$idx" -eq "$current" ]; then
                echo "  > ${options[$idx]}"
            else
                echo "    ${options[$idx]}"
            fi
        fi
    }

    tput civis
    trap 'tput cnorm; stty echo' EXIT INT TERM
    stty -echo

    echo ""
    echo "  $title"
    echo "  $(printf '%*s' ${#title} '' | tr ' ' '-')"
    for ((i=0; i<count; i++)); do
        render_option $i
    done
    echo ""
    echo "  (up/down to move, Enter to select, q or Esc to quit)"

    while true; do
        IFS= read -rsn1 key

        if [[ "$key" == $'\x1b' ]]; then
            rest=""
            read -rsn2 -t 0.05 rest || true
            if [ -z "$rest" ]; then
                tput cnorm
                stty echo
                trap - EXIT INT TERM
                return 1
            fi
            key="$rest"
        fi

        case "$key" in
            '[A'|'k') move_cursor -1 ;;
            '[B'|'j') move_cursor 1 ;;
            '')
                if [ "${disabled[current]}" -eq 1 ]; then continue; fi
                SELECTED_INDEX=$current
                SELECTED_VALUE="${options[$current]}"
                tput cnorm
                stty echo
                trap - EXIT INT TERM
                return 0
                ;;
            'q'|'Q')
                tput cnorm
                stty echo
                trap - EXIT INT TERM
                return 1
                ;;
        esac

        tput cuu $((count + 2))
        for ((i=0; i<count; i++)); do
            tput el
            render_option $i
        done
        tput el; echo ""
        tput el; echo "  (up/down to move, Enter to select, q or Esc to quit)"
    done
}

# ----- Listing helpers -----

list_items() {
    if [ "$MODE" = "session" ]; then
        tmux ls -F '#S' 2>/dev/null || true
    else
        tmux list-windows -F '#I: #W' 2>/dev/null || true
    fi
}

count_items() {
    list_items | grep -c . || true
}

item_id() {
    local line="$1"
    if [ "$MODE" = "session" ]; then
        echo "$line"
    else
        echo "${line%%:*}"
    fi
}

# ----- Action handlers -----

action_attach() {
    local items
    mapfile -t items < <(list_items)
    if [ "${#items[@]}" -eq 0 ]; then
        return
    fi
    if ! select_menu "Switch to $UNIT" "" "${items[@]}"; then
        return
    fi
    local id
    id=$(item_id "$SELECTED_VALUE")
    if [ "$MODE" = "session" ]; then
        clear
        tmux attach -t "$id"
    else
        tmux select-window -t "$id"
        exit 0
    fi
}

action_new() {
    echo ""
    read -rp "  New $UNIT name (blank to cancel): " name
    if [ -z "$name" ]; then
        return
    fi

    local cd_exec
    cd_exec=$(build_cd_exec "$PWD")

    if [ "$MODE" = "session" ]; then
        if tmux has-session -t "$name" 2>/dev/null; then
            clear
            tmux attach -t "$name"
        else
            clear
            # -c sets tmux's idea of starting dir; the cd-exec wrapper guarantees
            # we end up there even if rc files try to cd elsewhere.
            tmux new -s "$name" -c "$PWD" "$cd_exec"
        fi
    else
        tmux new-window -n "$name" -c "$PWD" "$cd_exec"
        exit 0
    fi
}

action_kill() {
    local items
    mapfile -t items < <(list_items)
    if [ "${#items[@]}" -eq 0 ]; then
        return
    fi
    if ! select_menu "Kill which $UNIT?" "" "${items[@]}"; then
        return
    fi
    local id
    id=$(item_id "$SELECTED_VALUE")
    if [ "$MODE" = "session" ]; then
        tmux kill-session -t "$id"
    else
        tmux kill-window -t "$id"
    fi
}

action_rename() {
    local items
    mapfile -t items < <(list_items)
    if [ "${#items[@]}" -eq 0 ]; then
        return
    fi
    if ! select_menu "Rename which $UNIT?" "" "${items[@]}"; then
        return
    fi
    local id
    id=$(item_id "$SELECTED_VALUE")
    echo ""
    read -rp "  New name (blank to cancel): " newname
    if [ -z "$newname" ]; then
        return
    fi
    if [ "$MODE" = "session" ]; then
        tmux rename-session -t "$id" "$newname"
    else
        tmux rename-window -t "$id" "$newname"
    fi
}

# ----- Main loop -----
main() {
    local title
    if [ "$MODE" = "session" ]; then
        title="tmux session manager"
    else
        local current_session
        current_session=$(tmux display-message -p '#S')
        title="tmux window manager — session: $current_session"
    fi

    local main_options=(
        "Switch to existing $UNIT"
        "Create new $UNIT"
        "Rename a $UNIT"
        "Kill a $UNIT"
        "Quit"
    )

    while true; do
        clear

        local n
        n=$(count_items)
        local disabled_flags
        if [ "$n" -eq 0 ]; then
            disabled_flags="1 0 1 1 0"
        else
            disabled_flags="0 0 0 0 0"
        fi

        if ! select_menu "$title" "$disabled_flags" "${main_options[@]}"; then
            exit 0
        fi

        case "$SELECTED_INDEX" in
            0) action_attach ;;
            1) action_new ;;
            2) action_rename ;;
            3) action_kill ;;
            4) exit 0 ;;
        esac
    done
}

main
