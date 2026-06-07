#!/bin/bash
# =============================================================================
# Virtual-display + monitor-watchdog installer (reference, DRAFT).
#
# Replicates the full setup on a fresh machine:
#   * forced-virtual display on a spare connector + custom EDID
#   * kernel args (drm.edid_firmware + video=:e) and initramfs rebuild
#   * client-adaptive resolution prep scripts (global_prep_cmd)
#   * dynamic EDID-regen watcher (system .path -> regenerates EDID on new modes)
#   * monitor-watchdog (user service: keep physical monitor primary when idle)
#   * configures ~/.config/sunshine/sunshine.conf (capture/output_name/prep_cmd)
#
# Run as root:   sudo ./install.sh
# Overrides:     VIRT_OUTPUT=DP-2 PHYS_OUTPUT=HDMI-A-1 PHYS_MODE=5120x1440@240 \
#                  HOST_CONF=~/.config/sunshine/sunshine.conf sudo -E ./install.sh
#
# Tested only on Nobara/Fedora 43 + KDE Plasma 6 Wayland + NVIDIA proprietary.
# =============================================================================
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0"; exit 1; }

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
[ -n "$TARGET_USER" ] || { echo "Cannot determine target user; set SUDO_USER"; exit 1; }
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
UID_N="$(id -u "$TARGET_USER")"
REPO="$(cd "$(dirname "$0")" && pwd)"

INSTALL_DIR="${INSTALL_DIR:-$USER_HOME/.local/bin}"
STATE_DIR="${STATE_DIR:-$USER_HOME/.local/share/vdisplay}"
CONF="$USER_HOME/.config/vdisplay.conf"
USER_UNIT_DIR="$USER_HOME/.config/systemd/user"
HOST_CONF="${HOST_CONF:-$USER_HOME/.config/sunshine/sunshine.conf}"
EDID_NAME="virtual-display.bin"
EDID_DST="/usr/lib/firmware/edid/$EDID_NAME"

say() { printf '\n=== %s ===\n' "$*"; }
as_user() { runuser -u "$TARGET_USER" -- "$@"; }
uctl()   { runuser -u "$TARGET_USER" -- env XDG_RUNTIME_DIR="/run/user/$UID_N" \
             DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" systemctl --user "$@"; }

# --- detect connectors -------------------------------------------------------
say "Detecting DRM connectors"
detect() {  # $1 = wanted status; prints first match's connector name
    for p in /sys/class/drm/card*-*/status; do
        [ -r "$p" ] && [ "$(cat "$p")" = "$1" ] || continue
        basename "$(dirname "$p")" | sed 's/^card[0-9]*-//'; return 0
    done
}
VIRT_OUTPUT="${VIRT_OUTPUT:-$(detect disconnected || true)}"
PHYS_OUTPUT="${PHYS_OUTPUT:-$(detect connected || true)}"
PHYS_MODE="${PHYS_MODE:-}"
[ -n "$VIRT_OUTPUT" ] || { echo "No free connector; set VIRT_OUTPUT="; exit 1; }
[ -n "$PHYS_OUTPUT" ] || { echo "No connected monitor; set PHYS_OUTPUT="; exit 1; }
echo "  virtual  -> $VIRT_OUTPUT (forced, custom EDID)"
echo "  physical -> $PHYS_OUTPUT (restored when idle)  mode=${PHYS_MODE:-preferred}"

# --- install scripts ---------------------------------------------------------
say "Installing scripts to $INSTALL_DIR"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "$INSTALL_DIR" "$STATE_DIR" \
    "$USER_HOME/.config" "$USER_UNIT_DIR"
for f in generate_edid.py pick-mode.py vdisplay-common.sh vdisplay-up.sh \
         vdisplay-down.sh monitor-watchdog.sh; do
    install -m0755 -o "$TARGET_USER" -g "$TARGET_USER" "$REPO/scripts/$f" "$INSTALL_DIR/$f"
done

# --- per-host config ---------------------------------------------------------
say "Writing $CONF"
cat > "$CONF" <<EOF
VIRT_OUTPUT="$VIRT_OUTPUT"
PHYS_OUTPUT="$PHYS_OUTPUT"
PHYS_MODE="$PHYS_MODE"
BACKEND="kscreen"
SINGLE_DISPLAY=1
INHIBIT=1
STATE_DIR="$STATE_DIR"
EOF
chown "$TARGET_USER:$TARGET_USER" "$CONF"

# --- EDID --------------------------------------------------------------------
say "Generating + installing EDID"
as_user python3 "$INSTALL_DIR/generate_edid.py" "$STATE_DIR/virtual-edid.bin"
install -D -m0644 "$STATE_DIR/virtual-edid.bin" "$EDID_DST"
echo "  -> $EDID_DST"

# --- kernel args -------------------------------------------------------------
say "Setting kernel args"
KARGS="drm.edid_firmware=${VIRT_OUTPUT}:edid/${EDID_NAME} video=${VIRT_OUTPUT}:e"
if command -v grubby >/dev/null 2>&1; then
    grubby --update-kernel=ALL --args="$KARGS"; echo "  grubby: all kernels"
elif [ -f /etc/default/grub ]; then
    grep -q "drm.edid_firmware=${VIRT_OUTPUT}" /etc/default/grub || \
        sed -i "s|\(GRUB_CMDLINE_LINUX_DEFAULT=\"\)|\1${KARGS} |" /etc/default/grub
    command -v update-grub >/dev/null 2>&1 && update-grub || \
        { command -v grub-mkconfig >/dev/null 2>&1 && grub-mkconfig -o /boot/grub/grub.cfg; }
    echo "  /etc/default/grub updated"
else
    echo "  !! Unknown bootloader. Add to cmdline manually: $KARGS"
fi

# --- initramfs ---------------------------------------------------------------
say "Rebuilding initramfs"
if   command -v dracut           >/dev/null 2>&1; then dracut --force --install "$EDID_DST"
elif command -v mkinitcpio       >/dev/null 2>&1; then
    grep -q "$EDID_DST" /etc/mkinitcpio.conf 2>/dev/null || \
        sed -i "s|^FILES=(|FILES=($EDID_DST |" /etc/mkinitcpio.conf
    mkinitcpio -P
elif command -v update-initramfs >/dev/null 2>&1; then update-initramfs -u
else echo "  !! No known initramfs tool"; fi

# --- dynamic EDID-regen watcher (system) ------------------------------------
say "Installing EDID-regen watcher (system)"
install -m0755 "$REPO/scripts/edid-regen.sh" /usr/local/sbin/vdisplay-edid-regen.sh
cat > /etc/vdisplay-regen.conf <<EOF
TARGET_USER=$TARGET_USER
STATE_DIR=$STATE_DIR
GENERATOR=$INSTALL_DIR/generate_edid.py
EDID_DST=$EDID_DST
EOF
sed "s|@STATE_DIR@|$STATE_DIR|" "$REPO/systemd/system/vdisplay-edid-regen.path.in" \
    > /etc/systemd/system/vdisplay-edid-regen.path
sed "s|@REGEN@|/usr/local/sbin/vdisplay-edid-regen.sh|" \
    "$REPO/systemd/system/vdisplay-edid-regen.service.in" \
    > /etc/systemd/system/vdisplay-edid-regen.service
touch "$STATE_DIR/pending-modes.txt"; chown "$TARGET_USER:$TARGET_USER" "$STATE_DIR/pending-modes.txt"
systemctl daemon-reload
systemctl enable --now vdisplay-edid-regen.path

# --- monitor-watchdog (user) -------------------------------------------------
say "Installing monitor-watchdog (user service)"
sed "s|@INSTALL_DIR@|$INSTALL_DIR|" "$REPO/systemd/user/monitor-watchdog.service.in" \
    > "$USER_UNIT_DIR/monitor-watchdog.service"
chown -R "$TARGET_USER:$TARGET_USER" "$USER_UNIT_DIR"
uctl daemon-reload || true
uctl enable --now monitor-watchdog.service || \
    echo "  (could not enable now; it will start with the next graphical session)"

# --- host config -------------------------------------------------------------
say "Configuring $HOST_CONF"
if [ -f "$HOST_CONF" ]; then
    cp "$HOST_CONF" "$HOST_CONF.bak.$(date +%s)"
    set_key() {  # idempotent key = value
        grep -v "^[[:space:]]*$1[[:space:]]*=" "$HOST_CONF" > "$HOST_CONF.tmp" || true
        echo "$1 = $2" >> "$HOST_CONF.tmp"
        mv "$HOST_CONF.tmp" "$HOST_CONF"
    }
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$(dirname "$HOST_CONF")"
    set_key capture kwin
    set_key output_name "$VIRT_OUTPUT"
    set_key global_prep_cmd "[{\"do\":\"$INSTALL_DIR/vdisplay-up.sh\",\"undo\":\"$INSTALL_DIR/vdisplay-down.sh\"}]"
    chown "$TARGET_USER:$TARGET_USER" "$HOST_CONF"
    echo "  patched (backup saved); restart the host to apply"
else
    echo "  host config not found. Add these once the host has run:"
    echo "    capture = kwin"
    echo "    output_name = $VIRT_OUTPUT"
    echo "    global_prep_cmd = [{\"do\":\"$INSTALL_DIR/vdisplay-up.sh\",\"undo\":\"$INSTALL_DIR/vdisplay-down.sh\"}]"
fi

cat <<EOF

=== DONE: reboot required (kernel args + initramfs) ===
After reboot:
  * the forced virtual output ($VIRT_OUTPUT) should expose the EDID modes
  * monitor-watchdog keeps $PHYS_OUTPUT primary while idle
  * connecting a client switches to $VIRT_OUTPUT at the client's resolution
Verify:  kscreen-doctor -o | grep -A20 $VIRT_OUTPUT
EOF
