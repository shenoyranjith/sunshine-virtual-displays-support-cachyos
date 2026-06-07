#!/bin/bash
# global_prep_cmd "do": put the virtual display at the client's
# requested resolution/fps (closest if not exact), make it the streamed output,
# hold a DPMS/idle inhibitor, and queue any unlisted mode for EDID regeneration.
. "$(dirname "$0")/vdisplay-common.sh"

W="${SUNSHINE_CLIENT_WIDTH:-1920}"
H="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS:-60}"

vd_log "UP req=${W}x${H}@${FPS} hdr=${SUNSHINE_CLIENT_HDR:-?}"
touch "$VD_FLAG"                            # tell any display watchdog to stand down

mapfile -t PICK < <(vd_pick_mode "$W" "$H" "$FPS")
MODEID="${PICK[0]}"
MATCH="${PICK[1]:-FALLBACK}"
vd_log "  -> mode_id=${MODEID} match=${MATCH}"

if [ "$MATCH" != "EXACT" ]; then
    echo "${W}x${H}@${FPS}" >> "$STATE_DIR/pending-modes.txt"   # -> EDID regen
    vd_log "  -> queued ${W}x${H}@${FPS} for EDID regen"
fi

vd_inhibit_start
vd_apply_virtual "$MODEID"
sleep 1
