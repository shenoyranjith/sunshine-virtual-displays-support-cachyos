#!/bin/bash
# =============================================================================
# Reverts install.sh: removes kernel args, EDID, systemd units, scripts, config,
# and restores the host config. Run as root:  sudo ./uninstall.sh
# =============================================================================
set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0"; exit 1; }

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
[ -n "$TARGET_USER" ] || { echo "Cannot determine target user; set SUDO_USER"; exit 1; }
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
UID_N="$(id -u "$TARGET_USER")"
CONF="$USER_HOME/.config/vdisplay.conf"
REGEN_CONF=/etc/vdisplay-regen.conf
HOST_CONF="${HOST_CONF:-$USER_HOME/.config/sunshine/sunshine.conf}"

say()  { printf '\n=== %s ===\n' "$*"; }
uctl() { runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="/run/user/$UID_N" \
           DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" systemctl --user "$@"; }

# discover what was installed
VIRT_OUTPUT=""; STATE_DIR="$USER_HOME/.local/share/vdisplay"
INSTALL_DIR="$USER_HOME/.local/bin"; EDID_DST=""
[ -f "$CONF" ] && . "$CONF" || true
if [ -f "$REGEN_CONF" ]; then
    . "$REGEN_CONF" || true
    [ -n "${GENERATOR:-}" ] && INSTALL_DIR="$(dirname "$GENERATOR")"
fi
EDID_DST="${EDID_DST:-/usr/lib/firmware/edid/virtual-display.bin}"
EDID_NAME="$(basename "$EDID_DST")"

# --- user service ------------------------------------------------------------
say "Removing monitor-watchdog (user)"
uctl disable --now monitor-watchdog.service 2>/dev/null || true
rm -f "$USER_HOME/.config/systemd/user/monitor-watchdog.service"
uctl daemon-reload 2>/dev/null || true

# --- system services ---------------------------------------------------------
say "Removing EDID-regen watcher (system)"
systemctl disable --now vdisplay-edid-regen.path 2>/dev/null || true
systemctl disable --now vdisplay-edid-regen.service 2>/dev/null || true
rm -f /etc/systemd/system/vdisplay-edid-regen.path \
      /etc/systemd/system/vdisplay-edid-regen.service \
      /usr/local/sbin/vdisplay-edid-regen.sh "$REGEN_CONF"
systemctl daemon-reload 2>/dev/null || true

# --- kernel args -------------------------------------------------------------
say "Removing kernel args"
if [ -n "$VIRT_OUTPUT" ]; then
    KARGS="drm.edid_firmware=${VIRT_OUTPUT}:edid/${EDID_NAME} video=${VIRT_OUTPUT}:e"
    if command -v grubby >/dev/null 2>&1; then
        grubby --update-kernel=ALL --remove-args="$KARGS" || true
        echo "  grubby: removed from all kernels"
    elif [ -f /etc/default/grub ]; then
        sed -i "s| *${KARGS}||g" /etc/default/grub || true
        command -v update-grub >/dev/null 2>&1 && update-grub || \
            { command -v grub-mkconfig >/dev/null 2>&1 && grub-mkconfig -o /boot/grub/grub.cfg; }
        echo "  /etc/default/grub cleaned"
    fi
else
    echo "  !! VIRT_OUTPUT unknown (no config); remove drm.edid_firmware/video= args by hand"
fi

# --- EDID + initramfs --------------------------------------------------------
say "Removing EDID + rebuilding initramfs"
rm -f "$EDID_DST"
if   command -v dracut           >/dev/null 2>&1; then dracut --force
elif command -v mkinitcpio       >/dev/null 2>&1; then mkinitcpio -P
elif command -v update-initramfs >/dev/null 2>&1; then update-initramfs -u; fi

# --- scripts + state ---------------------------------------------------------
say "Removing installed scripts + config"
for f in generate_edid.py pick-mode.py vdisplay-common.sh vdisplay-up.sh \
         vdisplay-down.sh monitor-watchdog.sh; do
    rm -f "$INSTALL_DIR/$f"
done
rm -f "$CONF"
rm -rf "$STATE_DIR"
rm -f "/run/user/$UID_N/vdisplay.flag"

# --- host config -------------------------------------------------------------
say "Restoring host config"
if [ -f "$HOST_CONF" ]; then
    BAK="$(ls -1t "$HOST_CONF".bak.* 2>/dev/null | head -1 || true)"
    if [ -n "$BAK" ]; then
        cp "$BAK" "$HOST_CONF"; chown "$TARGET_USER:$TARGET_USER" "$HOST_CONF"
        echo "  restored from $BAK"
    else
        # at least strip the prep_cmd (points at now-deleted scripts -> would break startup)
        grep -vE '^[[:space:]]*(global_prep_cmd|output_name|capture)[[:space:]]*=' \
            "$HOST_CONF" > "$HOST_CONF.tmp" || true
        mv "$HOST_CONF.tmp" "$HOST_CONF"; chown "$TARGET_USER:$TARGET_USER" "$HOST_CONF"
        echo "  no backup found; stripped capture/output_name/global_prep_cmd"
    fi
fi

cat <<EOF

=== UNINSTALL DONE: reboot recommended ===
Kernel args + initramfs were reverted; reboot to drop the virtual connector.
Note: the EDID-regen watcher and watchdog are gone; restart the host so it
re-reads its config.
EOF
