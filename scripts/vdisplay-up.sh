#!/bin/bash
# global_prep_cmd "do": put the virtual display at the client's
# requested resolution/fps (closest if not exact), make it the streamed output,
# hold a DPMS/idle inhibitor, and queue any unlisted mode for EDID regeneration.
set -euo pipefail
. "$(dirname "$0")/vdisplay-common.sh"

W="${SUNSHINE_CLIENT_WIDTH:-1920}"
H="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS:-60}"

[[ "$W" =~ ^[0-9]+$ ]] && [[ "$H" =~ ^[0-9]+$ ]] &&
    [[ "$FPS" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        vd_log "UP rejected invalid client mode ${W}x${H}@${FPS}"
        exit 2
    }

exec 7>> "$VD_LIFECYCLE_LOCK"
flock 7
PREVIOUS_COUNT="$(vd_flag_count)"
ACTIVE_MODE="$(vd_flag_value mode_id 2>/dev/null || true)"
STORED_SUNSHINE_PID="$(vd_flag_value sunshine_pid 2>/dev/null || true)"
CURRENT_SUNSHINE_PID="$(vd_find_sunshine_pid || true)"

# Sunshine may have crashed before it could run the undo command. Do not let a
# newly started Sunshine process inherit that dead lease: it would either be
# rejected as a conflicting stream or be torn down by the watchdog moments
# after starting.
if [ "$PREVIOUS_COUNT" -gt 0 ] && [ -n "$STORED_SUNSHINE_PID" ]; then
    STALE_LEASE=0
    vd_sunshine_pid_alive "$STORED_SUNSHINE_PID" || STALE_LEASE=1
    if [ -n "$CURRENT_SUNSHINE_PID" ] &&
       [ "$CURRENT_SUNSHINE_PID" != "$STORED_SUNSHINE_PID" ]; then
        STALE_LEASE=1
    fi
    if [ "$STALE_LEASE" = "1" ]; then
        vd_log "UP discarded stale lease from Sunshine pid $STORED_SUNSHINE_PID"
        rm -f "$VD_FLAG"
        vd_inhibit_stop || true
        PREVIOUS_COUNT=0
        ACTIVE_MODE=""
        STORED_SUNSHINE_PID=""
    fi
fi

SUNSHINE_PID="${CURRENT_SUNSHINE_PID:-$STORED_SUNSHINE_PID}"

vd_log "UP req=${W}x${H}@${FPS} hdr=${SUNSHINE_CLIENT_HDR:-?}"

PICK_OUTPUT="$(vd_pick_mode "$W" "$H" "$FPS")"
mapfile -t PICK <<< "$PICK_OUTPUT"
MODEID="${PICK[0]}"
MATCH="${PICK[1]:-FALLBACK}"
[ -n "$MODEID" ] || {
    vd_log "  -> no usable mode for $VIRT_OUTPUT"
    flock -u 7
    exit 1
}
vd_log "  -> mode_id=${MODEID} match=${MATCH}"

queue_requested_mode() {
    [ "$MATCH" != "EXACT" ] && [ "$DYNAMIC_EDID" = "1" ] || return 0
    local queue_ok=0
    if { exec 8>> "$PENDING_LOCK"; } 2>/dev/null && flock 8; then
        if printf '%sx%s@%s\n' "$W" "$H" "$FPS" >> "$PENDING_FILE"; then
            queue_ok=1
        fi
        flock -u 8 || true
    fi
    if [ "$queue_ok" = "1" ]; then
        vd_log "  -> queued ${W}x${H}@${FPS} for EDID regen"
    else
        vd_log "  -> WARN unable to queue ${W}x${H}@${FPS}"
    fi
}

# One compositor output cannot serve two different modes concurrently. Reuse
# an identical active layout, but reject a conflicting second stream before it
# can alter the first stream's mode or inhibitor.
if [ "$PREVIOUS_COUNT" -gt 0 ]; then
    if [ -z "$ACTIVE_MODE" ] || [ "$ACTIVE_MODE" != "$MODEID" ]; then
        vd_log "UP rejected concurrent mode ${MODEID}; active mode is ${ACTIVE_MODE:-unknown}"
        flock -u 7
        exit 3
    fi
    vd_flag_set "$((PREVIOUS_COUNT + 1))" "$SUNSHINE_PID" "$MODEID"
    queue_requested_mode
    flock -u 7
    sleep 1
    exit 0
fi

rollback() {
    local status=$?
    trap - ERR
    set +e
    vd_log "UP failed status=$status; rolling back"
    vd_restore_phys
    vd_inhibit_stop
    rm -f "$VD_FLAG"
    flock -u 7
    exit "$status"
}
trap rollback ERR
vd_flag_set 1 "$SUNSHINE_PID" "$MODEID"

vd_inhibit_start
vd_apply_virtual "$MODEID"

# Queue only after the display transaction succeeds. Regeneration is
# best-effort and must never turn a successful stream launch into a failure.
queue_requested_mode

trap - ERR
flock -u 7
sleep 1
