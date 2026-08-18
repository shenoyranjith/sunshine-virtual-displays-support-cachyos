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
: "${STREAM_MODE:=virtual}"
: "${DYNAMIC_EDID:=0}"
: "${PENDING_FILE:=$STATE_DIR/pending-modes.txt}"
: "${PENDING_LOCK:=$STATE_DIR/pending-modes.lock}"
mkdir -p "$STATE_DIR"

# "stream active" flag for any external display watchdog. Kept in XDG_RUNTIME_DIR
# (tmpfs) so a reboot/shutdown mid-stream cannot leave it stale; gone next boot.
VD_FLAG="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vdisplay.flag"
VD_LIFECYCLE_LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vdisplay.lock"

# graphical-session env (uid-portable so it works from the host's user service)
_uid="$(id -u)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$_uid}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
export DISPLAY="${DISPLAY:-:0}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[1]:-$0}")" && pwd)"

vd_log() { echo "$(date -Is) $*" >> "$STATE_DIR/requests.log"; }

vd_flag_count() {
    local count=0
    if [ -f "$VD_FLAG" ]; then
        count="$(sed -n 's/^count=\([0-9][0-9]*\)$/\1/p' "$VD_FLAG" | head -n1)"
        [ -n "$count" ] || count=1
    fi
    printf '%s\n' "$count"
}

vd_flag_value() {
    local key="$1"
    [ -f "$VD_FLAG" ] || return 1
    sed -n "s/^${key}=//p" "$VD_FLAG" | head -n1
}

vd_find_sunshine_pid() {
    local pid="$PPID" comm next steps=0
    while [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] && [ "$steps" -lt 12 ]; do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        case "${comm,,}" in
            *sunshine*|*apollo*) printf '%s\n' "$pid"; return 0 ;;
        esac
        next="$(awk '/^PPid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null || true)"
        [ -n "$next" ] || break
        pid="$next"
        steps=$((steps + 1))
    done
    return 1
}

vd_sunshine_pid_alive() {
    local pid="$1" comm
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    case "${comm,,}" in
        *sunshine*|*apollo*) return 0 ;;
    esac
    return 1
}

vd_flag_set() {
    local count="$1" sunshine_pid="${2:-}" mode_id="${3:-}" tmp
    tmp="$(mktemp "${VD_FLAG}.XXXXXX")" || return 1
    {
        printf 'count=%s\nupdated=%s\n' "$count" "$(date -Is)"
        [ -z "$sunshine_pid" ] || printf 'sunshine_pid=%s\n' "$sunshine_pid"
        [ -z "$mode_id" ] || printf 'mode_id=%s\n' "$mode_id"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0600 "$tmp"
    mv -fT "$tmp" "$VD_FLAG"
}

# Print "<mode-id>\n<EXACT|FALLBACK>" for the requested W H FPS.
vd_pick_mode() {
    case "$BACKEND" in
        kscreen) python3 "$_SCRIPT_DIR/pick-mode.py" "$VIRT_OUTPUT" "$1" "$2" "$3" ;;
        *) echo ""; echo "FALLBACK" ;;
    esac
}

# Return 0 when present, 1 when definitely absent, and 2 when KScreen/jq could
# not answer. Callers must not treat a query failure as a disconnected output.
vd_output_present() {
    local json status
    json="$(kscreen-doctor --json 2>/dev/null)" || return 2
    jq -e --arg name "$1" \
        'if (.outputs | type) != "array" then error("missing outputs")
         else any(.outputs[]; .name == $name) end' \
        >/dev/null 2>&1 <<< "$json"
    status=$?
    [ "$status" -le 1 ] || return 2
    return "$status"
}

# Same tri-state contract, but require the output to be enabled.
vd_output_enabled() {
    local json status
    json="$(kscreen-doctor --json 2>/dev/null)" || return 2
    jq -e --arg name "$1" \
        'if (.outputs | type) != "array" then error("missing outputs")
         else any(.outputs[]; .name == $name and .enabled == true) end' \
        >/dev/null 2>&1 <<< "$json"
    status=$?
    [ "$status" -le 1 ] || return 2
    return "$status"
}

# Bring up the virtual output at the chosen mode; single-display if configured.
# The virtual-output change is its own atomic call so it cannot be poisoned by
# the physical output being absent. Any requested layout change must succeed.
vd_apply_virtual() {   # $1 = mode id (may be empty)
    local mode_id="$1"
    case "$BACKEND" in
        kscreen)
            local a=(output."$VIRT_OUTPUT".enable)
            [ -n "$mode_id" ] && a+=(output."$VIRT_OUTPUT".mode."$mode_id")
            a+=(output."$VIRT_OUTPUT".priority.1 output."$VIRT_OUTPUT".position.0,0)
            kscreen-doctor "${a[@]}" >> "$STATE_DIR/requests.log" 2>&1 || return 1
            vd_output_enabled "$VIRT_OUTPUT" || {
                local status=$?
                vd_log "virtual output did not become enabled (query status=$status)"
                return 1
            }
            if vd_output_present "$PHYS_OUTPUT"; then
                if [ "$SINGLE_DISPLAY" = "1" ]; then
                    kscreen-doctor output."$PHYS_OUTPUT".disable >> "$STATE_DIR/requests.log" 2>&1 || return 1
                else
                    kscreen-doctor output."$PHYS_OUTPUT".priority.2 >> "$STATE_DIR/requests.log" 2>&1 || return 1
                fi
            else
                local status=$?
                [ "$status" = "1" ] || return "$status"
            fi ;;
        *) echo "BACKEND=$BACKEND not implemented (kscreen only for now)" >&2; return 2 ;;
    esac
}

# Restore the physical monitor first, then change the virtual output in a
# separate transaction. A missing virtual connector must never prevent the
# physical display from coming back.
vd_restore_phys() {
    case "$BACKEND" in
        kscreen)
            if vd_output_present "$PHYS_OUTPUT"; then
                local a=(output."$PHYS_OUTPUT".enable)
                [ -n "${PHYS_MODE:-}" ] && a+=(output."$PHYS_OUTPUT".mode."$PHYS_MODE")
                a+=(output."$PHYS_OUTPUT".priority.1)
                kscreen-doctor "${a[@]}" >> "$STATE_DIR/requests.log" 2>&1 || return 1
                vd_output_enabled "$PHYS_OUTPUT" || {
                    vd_log "physical output did not become enabled"
                    return 1
                }
                if vd_output_present "$VIRT_OUTPUT"; then
                    if [ "$SINGLE_DISPLAY" = "1" ]; then
                        kscreen-doctor output."$VIRT_OUTPUT".disable >> "$STATE_DIR/requests.log" 2>&1 || return 1
                    else
                        kscreen-doctor output."$VIRT_OUTPUT".priority.2 >> "$STATE_DIR/requests.log" 2>&1 || return 1
                    fi
                else
                    local status=$?
                    [ "$status" = "1" ] || return "$status"
                fi
            else
                local status=$?
                vd_log "physical output unavailable (query status=$status); leaving virtual enabled"
                return 1
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
        kde-inhibit --power --screenSaver sleep infinity >/dev/null 2>&1 || {
            vd_log "failed to start KDE idle inhibitor"
            return 1
        }
}

vd_inhibit_stop() {
    systemctl --user stop vdisplay-inhibit.service 2>/dev/null || true
    systemctl --user reset-failed vdisplay-inhibit.service 2>/dev/null || true
}
