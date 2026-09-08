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
#   ./tests/sandbox.sh keys -k Tab        press keys at it (wtype arguments)
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
SESSION="${XDG_RUNTIME_DIR:-/tmp}/hypr-sandbox-session"
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
    # HYPR_SESSION points the nested instance's session file (hypr/session.lua)
    # at a scratch path. Without it the sandbox writes down its own desktops and
    # windows as *the* session, and the next real login puts the sandbox back.
    # That happened. session.lua refuses to write the default path under
    # HYPR_SANDBOX=1 as well, so this is the second of two locks.
    #
    # Note that the environment here is the host compositor's, not this shell's:
    # the nested instance is started through the host's exec dispatcher, so
    # exporting a variable before running this script does not reach it.
    hyprctl dispatch "hl.dsp.exec_cmd(\"[workspace $WORKSPACE silent; float; size 1100 700; move 60 60] env HYPR_SANDBOX=1 HYPR_SESSION=$SESSION Hyprland -c $config\")" >/dev/null || {
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

# The nested instance's own Wayland socket, which nothing reports: `hyprctl
# instances` knows only the IPC signature, and /proc/<pid>/environ holds the
# *host* value the sandbox inherited, not the one it went on to create.
#
# So ask the sandbox itself. Hyprland exports WAYLAND_DISPLAY to the processes
# it launches, so a shell started inside it can print the value. exec_raw
# rather than exec_cmd because only exec_raw hands the string to a shell, so
# the redirect is interpreted -- exec_cmd would pass ">" to printenv as an
# argument.
#
# Cached, because every keypress would otherwise pay for a round trip.
wayland_display() {
    local cache="${XDG_RUNTIME_DIR:-/tmp}/hypr-sandbox-wayland"

    if [ -s "$cache" ]; then
        local cached
        cached="$(cat "$cache")"
        # Still valid only while that socket is there; a restarted sandbox gets
        # a new one and the old name would silently address the host.
        if [ -S "${XDG_RUNTIME_DIR:-/tmp}/$cached" ]; then
            printf '%s' "$cached"
            return 0
        fi
    fi

    local out="${XDG_RUNTIME_DIR:-/tmp}/hypr-sandbox-wayland.probe"
    rm -f "$out"
    sandbox_hyprctl dispatch "hl.dsp.exec_raw(\"printenv WAYLAND_DISPLAY > $out\")" >/dev/null || return 1

    local waited=0
    while [ "$waited" -lt 30 ]; do
        if [ -s "$out" ]; then
            tr -d '\n' < "$out" > "$cache"
            rm -f "$out"
            cat "$cache"
            return 0
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    echo "sandbox: it never said which wayland socket it made" >&2
    return 1
}

# Press keys at the sandbox. Arguments are wtype's:
#
#   ./tests/sandbox.sh keys -M super -k g -m super   # SUPER + G
#   ./tests/sandbox.sh keys -k h                     # h
#
# This is the only way to test a bind that enters or leaves a submap. No
# physical key reaches the sandbox -- it lives in a special workspace precisely
# so none can -- but wtype is a *client* of the nested compositor, and a
# virtual keyboard goes through the same input path as a real one: Hyprland's
# applyConfigToKeyboard defaults allow_binds to true, so binds do fire. The
# host session never sees any of it.
#
# Two things to know before believing a result:
#
# Binds only match at all because input.lua turns on resolve_binds_by_sym
# under HYPR_SANDBOX. Hyprland otherwise resolves a bind's keysym through the
# config's *layout*, which does not match the keymap wtype invents, so keys
# arrive at clients correctly while every bind stays silent.
#
# Throw the first keypress away. Each invocation is a new client and so a new
# virtual keyboard, and the first key on a fresh one lands before Hyprland has
# finished applying the keyboard config, so it resolves to the wrong symbol.
# `keys -k F13` first, then measure.
#
# A modifier needs both halves, in one invocation. wtype's -M/-m set the
# modifier *state* without pressing any key, while -P/-p press the key without
# touching the state; a real keyboard does both at once. Anything testing a
# shifted bind, or what happens when a modifier is merely reached for, wants:
#
#   keys -M shift -P Shift_L -k Tab -p Shift_L -m shift
#
# Splitting that across two invocations proves nothing: each one is its own
# keyboard, and the first is destroyed -- releasing whatever it held -- before
# the second runs. Using only -M hides bugs about the key event (a mode being
# cancelled by reaching for SHIFT); using only -P hides bugs about the state
# (SHIFT+Tab matching the plain Tab bind).
keys() {
    running || { echo "sandbox: not running" >&2; return 1; }

    local wd
    wd="$(wayland_display)" || return 1

    WAYLAND_DISPLAY="$wd" wtype "$@"
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
    keys)    shift; keys "$@" ;;
    *)
        sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
        exit 1
        ;;
esac
