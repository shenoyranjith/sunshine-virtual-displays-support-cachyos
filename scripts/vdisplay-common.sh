#!/bin/bash
# Shared helpers for the virtual-display prep scripts.
# Sourced by vdisplay-up.sh and vdisplay-down.sh.

: "${VDISPLAY_CONF:=$HOME/.config/vdisplay.conf}"
[ -f "$VDISPLAY_CONF" ] && . "$VDISPLAY_CONF"

: "${VIRT_OUTPUT:?set VIRT_OUTPUT in $VDISPLAY_CONF}"
: "${PHYS_OUTPUT:?set PHYS_OUTPUT in $VDISPLAY_CONF}"
: "${BACKEND:=kscreen}"
: "${SINGLE_DISPLAY:=1}"
: "${INHIBIT:=1}"
: "${STATE_DIR:=$HOME/.local/share/vdisplay}"
mkdir -p "$STATE_DIR"

# "stream active" flag for any external display watchdog. Kept in XDG_RUNTIME_DIR
# (tmpfs) so a reboot/shutdown mid-stream cannot leave it stale; gone next boot.
VD_FLAG="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vdisplay.flag"

# graphical-session env (uid-portable so it works from the host's user service)
_uid="$(id -u)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$_uid}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export DISPLAY="${DISPLAY:-:0}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"

vd_log() { echo "$(date -Is) $*" >> "$STATE_DIR/requests.log"; }

# Print "<mode-id>\n<EXACT|FALLBACK>" for the requested W H FPS.
vd_pick_mode() {
    case "$BACKEND" in
        kscreen) python3 "$_SCRIPT_DIR/pick-mode.py" "$VIRT_OUTPUT" "$1" "$2" "$3" ;;
        *) echo ""; echo "FALLBACK" ;;
    esac
}

# True iff `$1` is currently a present output (connected or not). Used so we
# don't reference a missing output inside an atomic kscreen-doctor call — KWin
# rejects the whole transaction in that case, silently dropping the mode change
# we actually cared about (see also: virtual output stuck at a prior mode).
vd_output_present() {
    kscreen-doctor --json 2>/dev/null | grep -q "\"name\": *\"$1\""
}

# Bring up the virtual output at the chosen mode; single-display if configured.
# The virtual-output change is its own atomic call so it cannot be poisoned by
# the physical output being absent; the phys disable/priority is best-effort.
vd_apply_virtual() {   # $1 = mode id (may be empty)
    local mode_id="$1"
    case "$BACKEND" in
        kscreen)
            local a=(output."$VIRT_OUTPUT".enable)
            [ -n "$mode_id" ] && a+=(output."$VIRT_OUTPUT".mode."$mode_id")
            a+=(output."$VIRT_OUTPUT".priority.1 output."$VIRT_OUTPUT".position.0,0)
            kscreen-doctor "${a[@]}" >> "$STATE_DIR/requests.log" 2>&1
            if vd_output_present "$PHYS_OUTPUT"; then
                if [ "$SINGLE_DISPLAY" = "1" ]; then
                    kscreen-doctor output."$PHYS_OUTPUT".disable >> "$STATE_DIR/requests.log" 2>&1 || true
                else
                    kscreen-doctor output."$PHYS_OUTPUT".priority.2 >> "$STATE_DIR/requests.log" 2>&1 || true
                fi
            fi ;;
        *) echo "BACKEND=$BACKEND not implemented (kscreen only for now)" >&2; return 2 ;;
    esac
}

# Restore the physical monitor when the stream ends. If the physical output
# isn't currently present, fall back to just disabling the virtual one so the
# next vd_apply_virtual gets a clean slate.
vd_restore_phys() {
    case "$BACKEND" in
        kscreen)
            if vd_output_present "$PHYS_OUTPUT"; then
                local a=(output."$PHYS_OUTPUT".enable)
                [ -n "${PHYS_MODE:-}" ] && a+=(output."$PHYS_OUTPUT".mode."$PHYS_MODE")
                a+=(output."$PHYS_OUTPUT".priority.1)
                if [ "$SINGLE_DISPLAY" = "1" ]; then
                    a+=(output."$VIRT_OUTPUT".disable)
                else
                    a+=(output."$VIRT_OUTPUT".priority.2)
                fi
                kscreen-doctor "${a[@]}" >> "$STATE_DIR/requests.log" 2>&1
            else
                kscreen-doctor output."$VIRT_OUTPUT".disable >> "$STATE_DIR/requests.log" 2>&1 || true
            fi ;;
        *) echo "BACKEND=$BACKEND not implemented" >&2; return 2 ;;
    esac
}

vd_inhibit_start() {
    [ "$INHIBIT" = "1" ] || return 0
    systemctl --user stop vdisplay-inhibit.service 2>/dev/null || true
    systemctl --user reset-failed vdisplay-inhibit.service 2>/dev/null || true
    systemd-run --user --collect --unit=vdisplay-inhibit \
        --description="Stream inhibit (DPMS/sleep)" \
        kde-inhibit --power --screenSaver sleep infinity >/dev/null 2>&1 || true
}

vd_inhibit_stop() {
    systemctl --user stop vdisplay-inhibit.service 2>/dev/null || true
    systemctl --user reset-failed vdisplay-inhibit.service 2>/dev/null || true
}
