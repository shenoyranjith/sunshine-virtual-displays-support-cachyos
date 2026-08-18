#!/bin/bash
# global_prep_cmd "undo": restore the physical monitor when the client
# disconnects, release the inhibitor, and clear the streaming flag.
set -uo pipefail
. "$(dirname "$0")/vdisplay-common.sh"

exec 7>> "$VD_LIFECYCLE_LOCK"
flock 7 || exit 1

vd_log "DOWN restoring ${PHYS_OUTPUT}"

count="$(vd_flag_count)"
if [ "$count" -gt 1 ]; then
    sunshine_pid="$(vd_flag_value sunshine_pid 2>/dev/null || true)"
    mode_id="$(vd_flag_value mode_id 2>/dev/null || true)"
    vd_flag_set "$((count - 1))" "$sunshine_pid" "$mode_id" || exit 1
    vd_log "DOWN deferred; $((count - 1)) stream lease(s) remain"
    flock -u 7
    exit 0
fi

status=0
vd_restore_phys || status=$?
vd_inhibit_stop || true
rm -f "$VD_FLAG" || status=1                # watchdog may retry a failed restore
flock -u 7 || status=1
sleep 1
exit "$status"
