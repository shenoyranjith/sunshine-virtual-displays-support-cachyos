#!/bin/bash
# Triggered as root (systemd .path watcher) when the host queues a client mode
# that is not in the virtual-display EDID. Merges new modes, regenerates and
# installs the EDID, rebuilds the initramfs, and flags that a reboot is needed.
#
# Config written by install.sh at /etc/vdisplay-regen.conf:
#   TARGET_USER, STATE_DIR, GENERATOR, EDID_DST
set -uo pipefail

CONF=/etc/vdisplay-regen.conf
[ -f "$CONF" ] && . "$CONF"
: "${TARGET_USER:?}" "${STATE_DIR:?}" "${GENERATOR:?}" "${EDID_DST:?}"

PENDING="$STATE_DIR/pending-modes.txt"
EXTRA="$STATE_DIR/extra-modes.txt"
SRC="$STATE_DIR/virtual-edid.bin"
LOG="$STATE_DIR/regen.log"
UID_N="$(id -u "$TARGET_USER")"

exec >>"$LOG" 2>&1
echo "=== $(date -Is) regen triggered ==="
[ -f "$PENDING" ] || { echo "no pending file"; exit 0; }

touch "$EXTRA"; chown "$TARGET_USER:" "$EXTRA" 2>/dev/null || true
mapfile -t WANT < <(grep -oE '[0-9]+x[0-9]+@[0-9.]+' "$PENDING" | sort -u)
NEW=0
for m in "${WANT[@]:-}"; do
    [ -z "$m" ] && continue
    grep -qxF "$m" "$EXTRA" || { echo "$m" >> "$EXTRA"; NEW=$((NEW+1)); echo "queued: $m"; }
done
: > "$PENDING"; chown "$TARGET_USER:" "$PENDING" 2>/dev/null || true
[ "$NEW" -eq 0 ] && { echo "no new modes"; exit 0; }

if ! runuser -u "$TARGET_USER" -- python3 "$GENERATOR" "$SRC" --extra "$EXTRA"; then
    echo "ERROR: generator failed"; exit 1
fi
SZ=$(stat -c%s "$SRC"); echo "regenerated: $SZ bytes"
[ $((SZ % 128)) -eq 0 ] || { echo "ERROR: bad EDID size"; exit 1; }

install -D -m0644 "$SRC" "$EDID_DST"
if   command -v dracut          >/dev/null 2>&1; then dracut --force --install "$EDID_DST"
elif command -v mkinitcpio      >/dev/null 2>&1; then mkinitcpio -P
elif command -v update-initramfs>/dev/null 2>&1; then update-initramfs -u
else echo "WARN: no known initramfs tool; EDID may not load early"; fi

date -Is > "$STATE_DIR/reboot-needed"; chown "$TARGET_USER:" "$STATE_DIR/reboot-needed" 2>/dev/null || true
runuser -u "$TARGET_USER" -- env \
    XDG_RUNTIME_DIR="/run/user/$UID_N" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" \
    notify-send -u critical "Virtual display EDID updated" \
    "$NEW new mode(s) baked. Reboot to enable them." 2>/dev/null || true
echo "done: $NEW new mode(s); reboot required"
