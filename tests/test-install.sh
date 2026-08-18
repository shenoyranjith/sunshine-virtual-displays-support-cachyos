#!/usr/bin/env bash
# Rootless end-to-end smoke test. Bubblewrap overlays every mutable system path,
# so neither the host bootloader nor its system/user service managers are used.
set -Eeuo pipefail

command -v bwrap >/dev/null 2>&1 || { echo "install smoke test skipped (bwrap unavailable)"; exit 0; }

ROOT="$(mktemp -d /tmp/vdisplay-install-test.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
REPO="$(cd "$(dirname "$0")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file_has() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_absent() { [ ! -e "$1" ] || fail "$1 unexpectedly exists"; }

mkdir -p "$ROOT/etc/default" "$ROOT/etc/systemd/system" \
    "$ROOT/etc/limine-entry-tool.d" "$ROOT/etc/mkinitcpio.conf.d" \
    "$ROOT/home/tester/.config/systemd/user" "$ROOT/home/tester/.config/sunshine" \
    "$ROOT/home/tester/.local" "$ROOT/run/user/0" "$ROOT/sys/class/drm" \
    "$ROOT/sys/bus/pci/drivers/nvidia" "$ROOT/usr/local/bin" \
    "$ROOT/usr/lib/firmware" "$ROOT/var/lib" "$ROOT/opt/repo"
chmod 0700 "$ROOT/home/tester/.config"

cat > "$ROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
tester:x:0:0:Test User:/home/tester:/bin/bash
EOF
printf 'root:x:0:\n' > "$ROOT/etc/group"
printf 'passwd: files\ngroup: files\n' > "$ROOT/etc/nsswitch.conf"
printf 'ID=cachyos\nID_LIKE=arch\n' > "$ROOT/etc/os-release"
cat > "$ROOT/etc/default/limine" <<'EOF'
ESP_PATH=/boot
KERNEL_CMDLINE[default]+=" quiet rw root=UUID=test "
EOF
printf 'FILES=(/existing)\n' > "$ROOT/etc/mkinitcpio.conf"
printf 'quiet rw root=UUID=test\n' > "$ROOT/proc-cmdline"
cat > "$ROOT/home/tester/.config/sunshine/sunshine.conf" <<'EOF'
capture = kms
keep_me = yes
EOF

mkdir -p "$ROOT/sys/class/drm/card1/device" \
    "$ROOT/sys/class/drm/card1-HDMI-A-1" "$ROOT/sys/class/drm/card1-DP-1" \
    "$ROOT/sys/class/drm/card1-DP-3"
ln -s /sys/bus/pci/drivers/nvidia "$ROOT/sys/class/drm/card1/device/driver"
printf 'disconnected\n' > "$ROOT/sys/class/drm/card1-HDMI-A-1/status"
printf 'disconnected\n' > "$ROOT/sys/class/drm/card1-DP-1/status"
printf 'connected\n' > "$ROOT/sys/class/drm/card1-DP-3/status"

cat > "$ROOT/usr/local/bin/runuser" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
    case "$1" in
        -u) shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
exec "$@"
EOF
cat > "$ROOT/usr/local/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> /var/lib/vdisplay-test-trace
exit 0
EOF
cat > "$ROOT/usr/local/bin/limine-mkinitcpio" <<'EOF'
#!/usr/bin/env bash
printf 'limine-mkinitcpio\n' >> /var/lib/vdisplay-test-trace
exit 0
EOF
cat > "$ROOT/usr/local/bin/rm" <<'EOF'
#!/usr/bin/env bash
if [ -e /var/lib/vdisplay-test-fail-state-rm ]; then
    for arg in "$@"; do
        [ "$arg" != /etc/vdisplay-install.conf ] || exit 1
    done
fi
exec /usr/bin/rm "$@"
EOF
cat > "$ROOT/usr/local/bin/kscreen-doctor" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--json" ] || [ "${1:-}" = "-j" ]; then
    printf '%s\n' '{"outputs":[{"name":"HDMI-A-1","enabled":false,"priority":2},{"name":"DP-3","enabled":true,"priority":1}]}'
fi
exit 0
EOF
for command_name in systemd-run kde-inhibit; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$ROOT/usr/local/bin/$command_name"
done
chmod +x "$ROOT/usr/local/bin"/*

run_sandbox() {
    bwrap --die-with-parent --unshare-user --uid 0 --gid 0 \
        --ro-bind / / --bind "$ROOT/etc" /etc --bind "$ROOT/home" /home \
        --bind "$ROOT/run" /run --bind "$ROOT/sys" /sys \
        --bind "$ROOT/usr/local" /usr/local \
        --bind "$ROOT/usr/lib/firmware" /usr/lib/firmware \
        --bind "$ROOT/var/lib" /var/lib --tmpfs /tmp --dev /dev --proc /proc \
        --ro-bind "$ROOT/proc-cmdline" /proc/cmdline \
        --bind "$ROOT/opt" /opt --ro-bind "$REPO" /opt/repo --chdir /opt/repo \
        /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/tmp \
        SUDO_USER=tester VIRT_OUTPUT=HDMI-A-1 PHYS_OUTPUT=DP-3 DRM_CARD=card1 \
        DYNAMIC_EDID=1 EDID_SOURCE=generated "$@"
}

# A connected connector is a real sink until proven otherwise. Reject both an
# explicit selection and an automatic selection recovered from the running
# command line when no trusted installation exists.
printf 'connected\n' > "$ROOT/sys/class/drm/card1-HDMI-A-1/status"
if run_sandbox /opt/repo/install.sh >/dev/null 2>&1; then
    fail "installer accepted a connected explicit virtual target"
fi
assert_absent "$ROOT/etc/vdisplay-install.conf"
printf 'quiet drm.edid_firmware=HDMI-A-1:edid/virtual-display.bin video=HDMI-A-1:e\n' \
    > "$ROOT/proc-cmdline"
if run_sandbox env -u VIRT_OUTPUT /opt/repo/install.sh >/dev/null 2>&1; then
    fail "installer accepted an automatically selected connected target without trusted state"
fi
assert_absent "$ROOT/etc/vdisplay-install.conf"
printf 'quiet rw root=UUID=test\n' > "$ROOT/proc-cmdline"
printf 'disconnected\n' > "$ROOT/sys/class/drm/card1-HDMI-A-1/status"

run_sandbox /opt/repo/install.sh >/dev/null
assert_file_has "$ROOT/etc/default/limine" '# BEGIN vdisplay kernel arguments'
assert_file_has "$ROOT/etc/mkinitcpio.conf.d/90-vdisplay.conf" 'virtual-display.bin'
[ -f "$ROOT/usr/lib/firmware/edid/virtual-display.bin" ] || fail "EDID was not installed"
[ -f "$ROOT/var/lib/vdisplay/source-edid.bin" ] || fail "source EDID was not snapshotted"
cmp -s "$ROOT/var/lib/vdisplay/source-edid.bin" \
    "$ROOT/usr/lib/firmware/edid/virtual-display.bin" || \
    fail "generated exact install diverged from its immutable source"
assert_file_has "$ROOT/home/tester/.config/sunshine/sunshine.conf" 'capture = kwin'
assert_file_has "$ROOT/home/tester/.config/sunshine/sunshine.conf" 'keep_me = yes'
[ "$(stat -c %a "$ROOT/home/tester/.config")" = 700 ] || fail "installer changed ~/.config mode"

# Model a successful regeneration that learned a new mode. A repeat install
# must derive from the immutable source plus the trusted learned-mode set,
# rather than silently reverting the firmware to its baseline.
printf '1600x900@75\n' > "$ROOT/var/lib/vdisplay/extra-modes.txt"
chmod 0600 "$ROOT/var/lib/vdisplay/extra-modes.txt"
python3 "$REPO/scripts/generate_edid.py" "$ROOT/derived-with-extra.bin" \
    --source-edid "$ROOT/var/lib/vdisplay/source-edid.bin" \
    --extra "$ROOT/var/lib/vdisplay/extra-modes.txt" --strict-extra >/dev/null
cp "$ROOT/derived-with-extra.bin" \
    "$ROOT/usr/lib/firmware/edid/virtual-display.bin"

# A repeat install must retain ownership and learned modes without another
# boot rebuild.
printf 'connected\n' > "$ROOT/sys/class/drm/card1-HDMI-A-1/status"
if run_sandbox /opt/repo/install.sh >/dev/null 2>&1; then
    fail "connected reinstall succeeded without an active forced mapping"
fi
printf 'quiet drm.edid_firmware=HDMI-A-1:edid/virtual-display.bin video=HDMI-A-1:e\n' \
    > "$ROOT/proc-cmdline"
run_sandbox /opt/repo/install.sh --check >/dev/null
run_sandbox /opt/repo/install.sh >/dev/null
cmp -s "$ROOT/derived-with-extra.bin" \
    "$ROOT/usr/lib/firmware/edid/virtual-display.bin" || \
    fail "repeat install discarded dynamically learned EDID modes"
[ "$(grep -c '^limine-mkinitcpio$' "$ROOT/var/lib/vdisplay-test-trace")" = 1 ] || \
    fail "repeat install rebuilt Limine/initramfs"
[ "$(grep -cF '# BEGIN vdisplay kernel arguments' "$ROOT/etc/default/limine")" = 1 ] || \
    fail "repeat install duplicated Limine arguments"

# A trusted reinstall still refuses to overwrite locally modified managed
# assets. Restoring the exact installed bytes makes the retry safe again.
cp -p "$ROOT/etc/vdisplay-regen.conf" "$ROOT/regen-conf.saved"
printf '# local edit\n' >> "$ROOT/etc/vdisplay-regen.conf"
if run_sandbox /opt/repo/install.sh >/dev/null 2>&1; then
    fail "reinstall overwrote a modified root asset"
fi
[ -f "$ROOT/etc/vdisplay-install.conf" ] || fail "failed reinstall discarded install state"
mv "$ROOT/regen-conf.saved" "$ROOT/etc/vdisplay-regen.conf"

unit="$ROOT/home/tester/.config/systemd/user/monitor-watchdog.service"
cp -p "$unit" "$ROOT/user-unit.saved"
printf '# local edit\n' >> "$unit"
if run_sandbox /opt/repo/install.sh >/dev/null 2>&1; then
    fail "reinstall overwrote a modified user unit"
fi
[ -f "$ROOT/etc/vdisplay-install.conf" ] || fail "unit collision discarded install state"
mv "$ROOT/user-unit.saved" "$unit"

run_sandbox /opt/repo/uninstall.sh >/dev/null
printf 'quiet rw root=UUID=test\n' > "$ROOT/proc-cmdline"
printf 'disconnected\n' > "$ROOT/sys/class/drm/card1-HDMI-A-1/status"
assert_file_has "$ROOT/etc/default/limine" 'root=UUID=test'
if grep -Fq 'drm.edid_firmware=' "$ROOT/etc/default/limine"; then
    fail "uninstall left installer-owned Limine arguments"
fi
assert_absent "$ROOT/etc/mkinitcpio.conf.d/90-vdisplay.conf"
assert_absent "$ROOT/usr/lib/firmware/edid/virtual-display.bin"
assert_file_has "$ROOT/home/tester/.config/sunshine/sunshine.conf" 'capture = kms'
assert_file_has "$ROOT/home/tester/.config/sunshine/sunshine.conf" 'keep_me = yes'
assert_absent "$ROOT/etc/vdisplay-install.conf"
[ "$(grep -c '^limine-mkinitcpio$' "$ROOT/var/lib/vdisplay-test-trace")" = 2 ] || \
    fail "uninstall did not rebuild Limine/initramfs exactly once"

# Explicit legacy preservation must remain repeatable without claiming an
# immutable source snapshot that was never created.
mkdir -p "$ROOT/usr/lib/firmware/edid"
python3 "$REPO/scripts/generate_edid.py" \
    "$ROOT/usr/lib/firmware/edid/virtual-display.bin" --interface hdmi >/dev/null
preserved_hash="$(sha256sum "$ROOT/usr/lib/firmware/edid/virtual-display.bin" | awk '{ print $1 }')"
run_sandbox env REPLACE_EDID=0 /opt/repo/install.sh >/dev/null
assert_file_has "$ROOT/etc/vdisplay-install.conf" 'EDID_MANAGED=0'
assert_absent "$ROOT/var/lib/vdisplay/source-edid.bin"
run_sandbox env REPLACE_EDID=0 /opt/repo/install.sh >/dev/null
[ "$(sha256sum "$ROOT/usr/lib/firmware/edid/virtual-display.bin" | awk '{ print $1 }')" = "$preserved_hash" ] || \
    fail "repeat REPLACE_EDID=0 install changed the external EDID"
run_sandbox /opt/repo/uninstall.sh >/dev/null
[ "$(sha256sum "$ROOT/usr/lib/firmware/edid/virtual-display.bin" | awk '{ print $1 }')" = "$preserved_hash" ] || \
    fail "uninstall removed an explicitly preserved external EDID"
rm "$ROOT/usr/lib/firmware/edid/virtual-display.bin"

# The clone-first default refuses a DisplayPort source on an HDMI target before
# installing any root asset. A same-transport physical clone is byte-exact and
# repeat installs continue using the immutable snapshot even if sysfs changes.
python3 "$REPO/scripts/generate_edid.py" \
    "$ROOT/sys/class/drm/card1-DP-3/edid" --interface displayport >/dev/null
cp "$ROOT/sys/class/drm/card1-DP-3/edid" "$ROOT/physical-original.bin"
if run_sandbox env EDID_SOURCE=physical /opt/repo/install.sh >/dev/null 2>&1; then
    fail "installer accepted a DP EDID for HDMI without explicit override"
fi
assert_absent "$ROOT/etc/vdisplay-install.conf"
assert_absent "$ROOT/usr/lib/firmware/edid/virtual-display.bin"
assert_absent "$ROOT/usr/local/libexec/vdisplay/generate_edid.py"
if grep -Fq 'drm.edid_firmware=' "$ROOT/etc/default/limine"; then
    fail "transport mismatch mutated boot configuration"
fi

# A same-transport target is still unsafe while administrator-managed Limine
# arguments map the same firmware filename to the legacy HDMI connector. The
# installer must refuse without deleting or rewriting that mapping.
sed -i 's| quiet rw root=UUID=test | quiet rw root=UUID=test drm.edid_firmware=HDMI-A-1:edid/virtual-display.bin video=HDMI-A-1:e |' \
    "$ROOT/etc/default/limine"
if run_sandbox env EDID_SOURCE=physical VIRT_OUTPUT=DP-1 \
    /opt/repo/install.sh >/dev/null 2>&1; then
    fail "installer accepted a conflicting persistent Limine EDID mapping"
fi
assert_file_has "$ROOT/etc/default/limine" \
    'drm.edid_firmware=HDMI-A-1:edid/virtual-display.bin'
assert_absent "$ROOT/etc/vdisplay-install.conf"
assert_absent "$ROOT/usr/lib/firmware/edid/virtual-display.bin"
sed -i \
    -e 's| drm.edid_firmware=HDMI-A-1:edid/virtual-display.bin||' \
    -e 's| video=HDMI-A-1:e||' "$ROOT/etc/default/limine"

run_sandbox env EDID_SOURCE=physical VIRT_OUTPUT=DP-1 \
    /opt/repo/install.sh >/dev/null
cmp -s "$ROOT/physical-original.bin" \
    "$ROOT/usr/lib/firmware/edid/virtual-display.bin" || \
    fail "physical exact clone was not installed byte-for-byte"
cmp -s "$ROOT/physical-original.bin" \
    "$ROOT/var/lib/vdisplay/source-edid.bin" || \
    fail "physical EDID snapshot was not byte-exact"
assert_file_has "$ROOT/etc/vdisplay-install.conf" 'EDID_SOURCE=physical'
assert_file_has "$ROOT/etc/vdisplay-install.conf" 'EDID_IDENTITY=exact'
snapshot_hash="$(sha256sum "$ROOT/var/lib/vdisplay/source-edid.bin" | awk '{ print $1 }')"
python3 "$REPO/scripts/generate_edid.py" \
    "$ROOT/sys/class/drm/card1-DP-3/edid" --interface displayport --name CHANGED >/dev/null
mv "$ROOT/sys/class/drm/card1-DP-3/edid" "$ROOT/physical-current-moved.bin"
printf 'disconnected\n' > "$ROOT/sys/class/drm/card1-DP-3/status"
run_sandbox env EDID_SOURCE=physical VIRT_OUTPUT=DP-1 \
    /opt/repo/install.sh >/dev/null
[ "$(sha256sum "$ROOT/var/lib/vdisplay/source-edid.bin" | awk '{ print $1 }')" = "$snapshot_hash" ] || \
    fail "repeat install recaptured instead of preserving immutable source"
cmp -s "$ROOT/physical-original.bin" \
    "$ROOT/usr/lib/firmware/edid/virtual-display.bin" || \
    fail "repeat install without its live monitor stopped using the immutable snapshot"
mv "$ROOT/physical-current-moved.bin" "$ROOT/sys/class/drm/card1-DP-3/edid"
printf 'connected\n' > "$ROOT/sys/class/drm/card1-DP-3/status"
run_sandbox /opt/repo/uninstall.sh >/dev/null
assert_absent "$ROOT/var/lib/vdisplay/source-edid.bin"

# A user-selected file follows the same snapshot and byte-equality rules. Use
# an HDMI dump here so the default transport guard remains active.
python3 "$REPO/scripts/generate_edid.py" "$ROOT/var/lib/source-hdmi.bin" \
    --interface hdmi >/dev/null
run_sandbox env EDID_SOURCE=file EDID_SOURCE_FILE=/var/lib/source-hdmi.bin \
    /opt/repo/install.sh >/dev/null
cmp -s "$ROOT/var/lib/source-hdmi.bin" \
    "$ROOT/usr/lib/firmware/edid/virtual-display.bin" || \
    fail "file exact clone was not installed byte-for-byte"
cmp -s "$ROOT/var/lib/source-hdmi.bin" \
    "$ROOT/var/lib/vdisplay/source-edid.bin" || \
    fail "file source snapshot was not byte-exact"
rm "$ROOT/var/lib/source-hdmi.bin"
run_sandbox env -u EDID_SOURCE -u EDID_SOURCE_FILE \
    /opt/repo/install.sh >/dev/null
cmp -s "$ROOT/var/lib/vdisplay/source-edid.bin" \
    "$ROOT/usr/lib/firmware/edid/virtual-display.bin" || \
    fail "repeat install required a deleted capture instead of its trusted snapshot"
run_sandbox /opt/repo/uninstall.sh >/dev/null

# Ambiguous/undefined source transports fail closed just like an explicit
# DP-to-HDMI mismatch; only the experimental override may bypass that guard.
python3 "$REPO/scripts/generate_edid.py" "$ROOT/var/lib/source-unknown.bin" \
    --interface hdmi >/dev/null
python3 - "$ROOT/var/lib/source-unknown.bin" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = bytearray(path.read_bytes())
data[20] = 0x80  # digital input, interface undefined
data[127] = 0
data[127] = (-sum(data[:127])) & 0xff
path.write_bytes(data)
PY
if run_sandbox env EDID_SOURCE=file \
    EDID_SOURCE_FILE=/var/lib/source-unknown.bin \
    /opt/repo/install.sh >/dev/null 2>&1; then
    fail "installer accepted an unknown EDID transport without an override"
fi
assert_absent "$ROOT/etc/vdisplay-install.conf"
assert_absent "$ROOT/usr/lib/firmware/edid/virtual-display.bin"

# The explicit escape hatch is journaled and permits an experimental
# cross-transport clone without weakening the safe default.
run_sandbox env EDID_SOURCE=physical ALLOW_EDID_TRANSPORT_MISMATCH=1 \
    /opt/repo/install.sh >/dev/null
cmp -s "$ROOT/sys/class/drm/card1-DP-3/edid" \
    "$ROOT/usr/lib/firmware/edid/virtual-display.bin" || \
    fail "explicit mismatch override did not retain exact source bytes"
assert_file_has "$ROOT/etc/vdisplay-install.conf" 'ALLOW_EDID_TRANSPORT_MISMATCH=1'
run_sandbox env -u ALLOW_EDID_TRANSPORT_MISMATCH -u EDID_SOURCE \
    /opt/repo/install.sh >/dev/null
cmp -s "$ROOT/sys/class/drm/card1-DP-3/edid" \
    "$ROOT/usr/lib/firmware/edid/virtual-display.bin" || \
    fail "repeat install forgot its journaled transport override"
run_sandbox /opt/repo/uninstall.sh >/dev/null

# A first install refuses an existing/symlinked owned filename before any root
# firmware or boot mutation.
printf 'sentinel\n' > "$ROOT/etc/config-sentinel"
ln -s /etc/config-sentinel "$ROOT/home/tester/.config/vdisplay.conf"
if run_sandbox /opt/repo/install.sh >/dev/null 2>&1; then
    fail "installer overwrote a colliding user config"
fi
assert_file_has "$ROOT/etc/config-sentinel" sentinel
assert_absent "$ROOT/usr/lib/firmware/edid/virtual-display.bin"
rm "$ROOT/home/tester/.config/vdisplay.conf"

# If the final install-state unlink fails, the EDID backup and platform helper
# remain available for a retry. Only a successful state unlink retires them.
mkdir -p "$ROOT/usr/lib/firmware/edid"
printf 'administrator EDID\n' > "$ROOT/usr/lib/firmware/edid/virtual-display.bin"
run_sandbox env REPLACE_EDID=1 /opt/repo/install.sh >/dev/null
backup="$ROOT/var/lib/vdisplay/backups/virtual-display.bin.pre-vdisplay"
[ -f "$backup" ] || fail "replacement install did not journal the original EDID"
# Model a process death after both boot mutations but before their ownership
# commits. Pending journals must be sufficient for uninstall recovery.
sed -i \
    -e 's/^KARGS_MANAGED=.*/KARGS_MANAGED=0/' \
    -e 's/^KARGS_PENDING=.*/KARGS_PENDING=1/' \
    -e 's/^KARGS_PENDING_ARGS=.*/KARGS_PENDING_ARGS=drm.edid_firmware=HDMI-A-1:edid\/virtual-display.bin\\ video=HDMI-A-1:e/' \
    -e 's/^INITRAMFS_CONFIG_MANAGED=.*/INITRAMFS_CONFIG_MANAGED=0/' \
    -e 's/^INITRAMFS_CONFIG_PENDING=.*/INITRAMFS_CONFIG_PENDING=1/' \
    "$ROOT/etc/vdisplay-install.conf"
touch "$ROOT/var/lib/vdisplay-test-fail-state-rm"
if run_sandbox /opt/repo/uninstall.sh >/dev/null 2>&1; then
    fail "uninstall ignored a failed install-state unlink"
fi
[ -f "$ROOT/etc/vdisplay-install.conf" ] || fail "failed state unlink lost recovery metadata"
[ -f "$backup" ] || fail "failed state unlink deleted the EDID backup"
[ -f "$ROOT/usr/local/libexec/vdisplay/vdisplay-platform.sh" ] || \
    fail "failed state unlink deleted the recovery helper"
assert_absent "$ROOT/etc/mkinitcpio.conf.d/90-vdisplay.conf"
if grep -Fq 'drm.edid_firmware=' "$ROOT/etc/default/limine"; then
    fail "pending boot journal did not remove interrupted kernel arguments"
fi
rm "$ROOT/var/lib/vdisplay-test-fail-state-rm"
run_sandbox /opt/repo/uninstall.sh >/dev/null
assert_absent "$ROOT/etc/vdisplay-install.conf"
assert_absent "$backup"
assert_file_has "$ROOT/usr/lib/firmware/edid/virtual-display.bin" 'administrator EDID'

echo "install smoke test passed"
