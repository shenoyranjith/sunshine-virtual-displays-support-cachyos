#!/bin/bash
# global_prep_cmd "undo": restore the physical monitor when the client
# disconnects, release the inhibitor, and clear the streaming flag.
. "$(dirname "$0")/vdisplay-common.sh"

vd_log "DOWN restoring ${PHYS_OUTPUT}"
rm -f "$VD_FLAG"                            # let any display watchdog resume

vd_inhibit_stop
vd_restore_phys
sleep 1
