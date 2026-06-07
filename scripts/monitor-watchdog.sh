#!/usr/bin/env bash
# Reaffirm the physical monitor as primary (and keep the virtual streaming output
# disabled) whenever NO stream is active. While a stream is active it
# does nothing; the global_prep_cmd owns the display layout then.
#
# Why this exists: a physical monitor often keeps HPD asserted in standby, so
# /sys/.../status always reads "connected" and can't be used as the signal. And
# the compositor (kscreen) may restore the last (streaming) layout across boots,
# leaving the physical monitor disabled. This watchdog corrects that at idle.
#
# Reads the same config as the prep scripts (~/.config/vdisplay.conf).
set -u

: "${VDISPLAY_CONF:=$HOME/.config/vdisplay.conf}"
[ -f "$VDISPLAY_CONF" ] && . "$VDISPLAY_CONF"
: "${PHYS_OUTPUT:?set PHYS_OUTPUT in $VDISPLAY_CONF}"
: "${VIRT_OUTPUT:?set VIRT_OUTPUT in $VDISPLAY_CONF}"
: "${PHYS_MODE:=}"
INTERVAL="${WATCHDOG_INTERVAL:-5}"

_uid="$(id -u)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$_uid}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export DISPLAY="${DISPLAY:-:0}"

# Same flag the prep scripts use; in tmpfs so it can't survive a reboot.
FLAG="$XDG_RUNTIME_DIR/vdisplay.flag"
UDP_LO=47998; UDP_HI=48010   # host video/control/audio ports (fallback signal)

log() { echo "$(date '+%F %T') $*"; }

stream_active() {                       # 0 = streaming, 1 = idle
    [ -f "$FLAG" ] && return 0          # primary signal (no false negatives)
    ss -uan 2>/dev/null | awk -v lo="$UDP_LO" -v hi="$UDP_HI" '
        NR>1 { n=split($4,a,":"); p=a[n]+0; if (p>=lo && p<=hi) f=1 }
        END { exit !f }'                # fallback: UDP ports
}

phys_is_primary() {                     # 0 = physical enabled & priority 1
    kscreen-doctor -j 2>/dev/null \
        | jq -e --arg n "$PHYS_OUTPUT" \
            '.outputs[] | select(.name==$n) | select(.enabled==true and .priority==1)' \
        >/dev/null 2>&1
}

log "watchdog: keep $PHYS_OUTPUT primary when no stream (virtual=$VIRT_OUTPUT, ${INTERVAL}s)"

while true; do
    if stream_active; then
        :   # stream active: leave the layout to the prep_cmd
    elif ! phys_is_primary; then
        log "no stream & $PHYS_OUTPUT not primary -> restoring (disabling $VIRT_OUTPUT)"
        a=(output."$PHYS_OUTPUT".enable)
        [ -n "$PHYS_MODE" ] && a+=(output."$PHYS_OUTPUT".mode."$PHYS_MODE")
        a+=(output."$PHYS_OUTPUT".priority.1 output."$VIRT_OUTPUT".disable)
        kscreen-doctor "${a[@]}"
    fi
    sleep "$INTERVAL"
done
