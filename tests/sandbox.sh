#!/usr/bin/env bash
# A nested Hyprland to test against, parked where it cannot be stumbled into.
#
# It is an ordinary window of the running session, but it lives in the special
# workspace "sandbox". Special workspaces sit outside the desktop model --
# deskbinds.lua filters them out everywhere -- so no key reaches it and nothing
# shows it. It gets no frame callbacks while hidden and so never draws, but it
# keeps running: Lua timers fire, windows are placed and sized, and hyprctl
# answers. Tests read it that way rather than by looking at it.
#
#   ./tests/sandbox.sh start [config]     start it (default: this repo's hypr/)
#   ./tests/sandbox.sh hyprctl monitors -j
#   ./tests/sandbox.sh exec kitty         run something inside it
#   ./tests/sandbox.sh status
#   ./tests/sandbox.sh stop
#
# HYPR_SANDBOX=1 is set for it, which makes autostart.lua do nothing: hypridle
# would lock or suspend the *host* session from in here, and a second waybar or
# hyprpaper would fight the real ones.
#
# Beware of anything that reaches outside its own session. pkill and killall
# match every process on the machine, so bin/waybar-main run in here would take
# the host's bar down with it.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${XDG_RUNTIME_DIR:-/tmp}/hypr-sandbox.state"
WORKSPACE="special:sandbox"

# Signature and pid of every Hyprland that is up, one "sig pid" per line.
instances() {
    hyprctl instances -j 2>/dev/null |
        python3 -c 'import json,sys
for i in json.load(sys.stdin): print(i["instance"], i["pid"])' 2>/dev/null
}

saved_sig() { [ -f "$STATE" ] && cut -d" " -f1 "$STATE"; }
saved_pid() { [ -f "$STATE" ] && cut -d" " -f2 "$STATE"; }

running() {
    local pid
    pid="$(saved_pid)" || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

start() {
    if running; then
        echo "sandbox: already running (pid $(saved_pid))" >&2
        return 0
    fi

    local config="${1:-$REPO/hypr/hyprland.lua}"
    if [ ! -e "$config" ]; then
        echo "sandbox: no config at $config" >&2
        return 1
    fi

    local before
    before="$(instances | cut -d" " -f1)"

    # Started through the host's own exec dispatcher, because that is what can
    # put the window straight into the special workspace. Floating and fixed
    # size so it never re-tiles the columns of whatever desktop is in front.
    # The host config is lua, so its dispatch takes lua rather than a string.
    hyprctl dispatch "hl.dsp.exec_cmd(\"[workspace $WORKSPACE silent; float; size 1100 700; move 60 60] env HYPR_SANDBOX=1 Hyprland -c $config\")" >/dev/null || {
        echo "sandbox: the host session would not start it" >&2
        return 1
    }

    # Wait for a signature that was not there before, and remember it: the pid
    # is the only handle that cannot match anything else on the machine.
    local waited=0 line sig pid
    while [ "$waited" -lt 30 ]; do
        sleep 0.5
        waited=$((waited + 1))
        while read -r sig pid; do
            case " $before " in
                *" $sig "*) ;;
                *)
                    printf '%s %s\n' "$sig" "$pid" > "$STATE"
                    echo "sandbox: up, pid $pid"
                    return 0
                    ;;
            esac
        done < <(instances)
    done

    echo "sandbox: it never came up" >&2
    return 1
}

stop() {
    if ! running; then
        echo "sandbox: not running"
        rm -f "$STATE"
        return 0
    fi

    local pid
    pid="$(saved_pid)"
    kill "$pid" 2>/dev/null
    for _ in $(seq 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    kill -9 "$pid" 2>/dev/null
    rm -f "$STATE"
    echo "sandbox: stopped"
}

# hyprctl aimed at the sandbox rather than the session you are sitting in.
sandbox_hyprctl() {
    running || { echo "sandbox: not running" >&2; return 1; }
    HYPRLAND_INSTANCE_SIGNATURE="$(saved_sig)" hyprctl "$@"
}

case "${1:-}" in
    start)   shift; start "$@" ;;
    stop)    stop ;;
    restart) stop; start ;;
    status)
        if running; then
            echo "sandbox: running, pid $(saved_pid), signature $(saved_sig)"
            sandbox_hyprctl monitors -j |
                python3 -c 'import json,sys
for m in json.load(sys.stdin):
    print("  monitor", m["name"], str(m["width"]) + "x" + str(m["height"]))' 2>/dev/null
        else
            echo "sandbox: not running"
        fi
        ;;
    hyprctl) shift; sandbox_hyprctl "$@" ;;
    exec)
        shift
        sandbox_hyprctl dispatch "hl.dsp.exec_cmd(\"$*\")"
        ;;
    *)
        sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
        exit 1
        ;;
esac
