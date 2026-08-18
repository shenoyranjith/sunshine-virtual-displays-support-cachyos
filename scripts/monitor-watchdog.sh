#!/usr/bin/env bash
# Reaffirm the desktop monitor as primary (and keep the stream output disabled)
# whenever NO stream is active. That stream output may be a firmware virtual
# connector or a real sink that stays plugged in (STREAM_MODE=physical). While a
# stream is active the watchdog does nothing; the global_prep_cmd owns the layout.
#
# Why this exists: a physical monitor often keeps HPD asserted in standby, so
# /sys/.../status always reads "connected" and can't be used as the signal. And
# the compositor (kscreen) may restore the last (streaming) layout across boots,
# leaving the desktop monitor disabled. This watchdog corrects that at idle.
#
# Reads the same config as the prep scripts (~/.config/vdisplay.conf).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/vdisplay-common.sh"
INTERVAL="${WATCHDOG_INTERVAL:-5}"

_uid="$(id -u)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$_uid}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export DISPLAY="${DISPLAY:-:0}"

log() { echo "$(date '+%F %T') $*"; }

stream_active() {                       # 0 = streaming, 1 = idle
    local sunshine_pid
    [ -f "$VD_FLAG" ] || return 1
    sunshine_pid="$(vd_flag_value sunshine_pid 2>/dev/null || true)"
    [ -n "$sunshine_pid" ] || return 0
    vd_sunshine_pid_alive "$sunshine_pid" && return 0
    log "discarding stale stream lease (Sunshine pid $sunshine_pid is gone)"
    rm -f "$VD_FLAG"
    vd_inhibit_stop || true
    return 1
}

layout_is_idle() { # 0 idle, 1 layout needs restore, 2 query failure
    local single=false json status
    [ "$SINGLE_DISPLAY" = "1" ] && single=true
    json="$(kscreen-doctor -j 2>/dev/null)" || return 2
    jq -e --arg physical "$PHYS_OUTPUT" --arg virtual "$VIRT_OUTPUT" \
        --argjson single "$single" \
        'if (.outputs | type) != "array" then error("missing outputs") else
           (any(.outputs[]; .name == $physical and .enabled == true and .priority == 1)) and
           (if $single then
                (any(.outputs[]; .name == $virtual and .enabled == true) | not)
            else
                ((any(.outputs[]; .name == $virtual) | not) or
                 any(.outputs[]; .name == $virtual and .enabled == true and .priority == 2))
            end)
         end' >/dev/null 2>&1 <<< "$json"
    status=$?
    [ "$status" -le 1 ] || return 2
    return "$status"
}

monitor_watchdog_main() {
    log "watchdog: keep $PHYS_OUTPUT primary when no stream (stream=$VIRT_OUTPUT, ${INTERVAL}s)"
    exec 7>> "$VD_LIFECYCLE_LOCK"

    while true; do
        if flock -n 7; then
            if stream_active; then
                :   # stream active: leave the layout to the prep_cmd
            elif layout_is_idle; then
                :
            else
                status=$?
                if [ "$status" = "1" ]; then
                    log "no stream & $PHYS_OUTPUT not primary -> restoring"
                    vd_restore_phys || log "restore failed; will retry"
                else
                    log "KScreen layout query failed; leaving outputs unchanged"
                fi
            fi
            flock -u 7
        fi
        sleep "$INTERVAL"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    monitor_watchdog_main "$@"
fi
