#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(mktemp -d /tmp/vdisplay-platform-test.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/etc/default" "$ROOT/etc/limine-entry-tool.d" \
    "$ROOT/etc/mkinitcpio.conf.d" "$ROOT/etc/dracut.conf.d" "$ROOT/boot/grub"

TRACE="$ROOT/trace"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$VD_TEST_TRACE"\n' \
    > "$ROOT/bin/limine-mkinitcpio"
chmod +x "$ROOT/bin/limine-mkinitcpio"

export VD_TEST_TRACE="$TRACE"
export VD_OS_RELEASE="$ROOT/os-release"
export VD_LIMINE_DEFAULT="$ROOT/etc/default/limine"
export VD_LIMINE_DROPIN="$ROOT/etc/limine-entry-tool.d/90-vdisplay.conf"
export VD_GRUB_DEFAULT="$ROOT/etc/default/grub"
export VD_GRUB_OUTPUT="$ROOT/boot/grub/grub.cfg"
export VD_MKINITCPIO_CONF="$ROOT/etc/mkinitcpio.conf"
export VD_MKINITCPIO_DROPIN="$ROOT/etc/mkinitcpio.conf.d/90-vdisplay.conf"
export VD_DRACUT_DROPIN="$ROOT/etc/dracut.conf.d/90-vdisplay.conf"
export VD_LIMINE_CMD="$ROOT/bin/limine-mkinitcpio"
export VD_MKINITCPIO_CMD="$ROOT/bin/mkinitcpio"

# shellcheck source=../scripts/vdisplay-platform.sh
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/vdisplay-platform.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "expected '$2', got '$1'"; }
assert_file_has() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_file_lacks() { ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly contains: $2"; }
assert_absent() { [ ! -e "$1" ] || fail "$1 unexpectedly exists"; }

printf 'ID=cachyos\nID_LIKE=arch\n' > "$VD_OS_RELEASE"
printf 'ESP_PATH=/boot\nKERNEL_CMDLINE[default]+=" quiet rw root=UUID=test "\n' > "$VD_LIMINE_DEFAULT"
printf 'FILES=(/existing)\n' > "$VD_MKINITCPIO_CONF"

assert_eq "$(vd_detect_distro_family)" arch
assert_eq "$(vd_detect_boot_backend auto)" limine
assert_eq "$(vd_detect_initramfs_backend limine auto)" limine

# Limine gets a marked append in its highest-priority persistent config. A
# reinstall retains ownership without changing the file or its mtime.
vd_install_kernel_args limine DP-2 virtual-display.bin
assert_eq "$VD_KARGS_MANAGED" 1
assert_eq "$VD_KARGS_CHANGED" 1
assert_file_has "$VD_LIMINE_DEFAULT" 'drm.edid_firmware=DP-2:edid/virtual-display.bin'
assert_file_has "$VD_LIMINE_DEFAULT" 'video=DP-2:e'
touch -d @1000000000 "$VD_LIMINE_DEFAULT"
vd_install_kernel_args limine DP-2 virtual-display.bin
assert_eq "$VD_KARGS_MANAGED" 1
assert_eq "$VD_KARGS_CHANGED" 0
assert_eq "$(stat -c %Y "$VD_LIMINE_DEFAULT")" 1000000000
assert_eq "$(grep -cF "$VD_LIMINE_BEGIN" "$VD_LIMINE_DEFAULT")" 1
vd_remove_kernel_args limine DP-2 virtual-display.bin 1
assert_eq "$VD_KARGS_CHANGED" 1
assert_file_has "$VD_LIMINE_DEFAULT" 'root=UUID=test'
assert_file_lacks "$VD_LIMINE_DEFAULT" 'drm.edid_firmware='
vd_remove_kernel_args limine DP-2 virtual-display.bin 1
assert_eq "$VD_KARGS_CHANGED" 0

# A highest-priority replacement is preserved and gets the same managed append.
printf 'KERNEL_CMDLINE[default]=quiet splash\n' > "$VD_LIMINE_DEFAULT"
vd_install_kernel_args limine DP-2 virtual-display.bin
assert_file_has "$VD_LIMINE_DEFAULT" "$VD_LIMINE_BEGIN"
assert_absent "$VD_LIMINE_DROPIN"
vd_remove_kernel_args limine DP-2 virtual-display.bin 1
assert_file_has "$VD_LIMINE_DEFAULT" 'KERNEL_CMDLINE[default]=quiet splash'
assert_file_lacks "$VD_LIMINE_DEFAULT" 'drm.edid_firmware='

# Existing administrator-owned arguments are detected and preserved.
printf 'KERNEL_CMDLINE[default]+=quiet drm.edid_firmware=DP-2:edid/virtual-display.bin video=DP-2:e\n' \
    > "$VD_LIMINE_DEFAULT"
vd_install_kernel_args limine DP-2 virtual-display.bin
assert_eq "$VD_KARGS_MANAGED" 0
assert_eq "$VD_KARGS_CHANGED" 0
assert_absent "$VD_LIMINE_DROPIN"
vd_remove_kernel_args limine DP-2 virtual-display.bin 0
assert_file_has "$VD_LIMINE_DEFAULT" 'video=DP-2:e'

# A display-only Limine config is unsafe because it suppresses inherited boot
# arguments; it must fail without changing either file.
printf 'ESP_PATH=/boot\n' > "$VD_LIMINE_DEFAULT"
printf '# admin file\nADMIN_SENTINEL=keep\n' > "$VD_LIMINE_DROPIN"
cp "$VD_LIMINE_DEFAULT" "$ROOT/limine.before"
cp "$VD_LIMINE_DROPIN" "$ROOT/dropin.before"
if vd_install_kernel_args limine DP-2 virtual-display.bin 2>/dev/null; then
    fail "Limine install without a persistent base unexpectedly succeeded"
fi
assert_eq "$VD_KARGS_MANAGED" 0
assert_eq "$VD_KARGS_CHANGED" 0
cmp -s "$ROOT/limine.before" "$VD_LIMINE_DEFAULT" || fail "unsafe base was modified"
cmp -s "$ROOT/dropin.before" "$VD_LIMINE_DROPIN" || fail "admin Limine drop-in was modified"

printf 'KERNEL_CMDLINE[default]+="   "\n' > "$VD_LIMINE_DEFAULT"
if vd_install_kernel_args limine DP-2 virtual-display.bin 2>/dev/null; then
    fail "empty Limine base unexpectedly succeeded"
fi
assert_eq "$VD_KARGS_CHANGED" 0

cat > "$VD_LIMINE_DEFAULT" <<EOF
KERNEL_CMDLINE[default]+=""
$VD_LIMINE_BEGIN
KERNEL_CMDLINE[default]+=" drm.edid_firmware=DP-2:edid/virtual-display.bin video=DP-2:e "
$VD_LIMINE_END
EOF
if vd_install_kernel_args limine DP-2 virtual-display.bin 2>/dev/null; then
    fail "installer-only Limine block was accepted as a persistent base"
fi
assert_eq "$VD_KARGS_CHANGED" 0

# A malformed marker must fail without consuming the administrator's tail.
cat > "$VD_LIMINE_DEFAULT" <<EOF
KERNEL_CMDLINE[default]+=" quiet rw root=UUID=test "
$VD_LIMINE_BEGIN
ADMIN_TAIL=keep
EOF
cp "$VD_LIMINE_DEFAULT" "$ROOT/malformed.before"
if vd_install_kernel_args limine DP-2 virtual-display.bin 2>/dev/null; then
    fail "malformed Limine marker unexpectedly succeeded"
fi
cmp -s "$ROOT/malformed.before" "$VD_LIMINE_DEFAULT" || fail "malformed file was modified"
if vd_remove_kernel_args limine DP-2 virtual-display.bin 1 2>/dev/null; then
    fail "malformed Limine marker removal unexpectedly succeeded"
fi
cmp -s "$ROOT/malformed.before" "$VD_LIMINE_DEFAULT" || fail "failed removal modified malformed file"
cat > "$VD_LIMINE_DEFAULT" <<EOF
KERNEL_CMDLINE[default]+=" quiet rw root=UUID=test "
$VD_LIMINE_END
ADMIN_TAIL=keep
EOF
cp "$VD_LIMINE_DEFAULT" "$ROOT/end-only.before"
if vd_remove_kernel_args limine DP-2 virtual-display.bin 1 2>/dev/null; then
    fail "end-only Limine marker removal unexpectedly succeeded"
fi
cmp -s "$ROOT/end-only.before" "$VD_LIMINE_DEFAULT" || fail "end-only marker file was modified"

# A colliding administrator Limine drop-in stays untouched; the safe managed
# block goes in /etc/default/limine instead.
printf 'KERNEL_CMDLINE[default]+=" quiet rw root=UUID=test "\n' > "$VD_LIMINE_DEFAULT"
vd_install_kernel_args limine DP-2 virtual-display.bin
cmp -s "$ROOT/dropin.before" "$VD_LIMINE_DROPIN" || fail "admin Limine drop-in was modified"
vd_remove_kernel_args limine DP-2 virtual-display.bin 1
cmp -s "$ROOT/dropin.before" "$VD_LIMINE_DROPIN" || fail "admin Limine drop-in was removed"
rm -f "$VD_LIMINE_DROPIN"

# mkinitcpio uses an additive, marked drop-in and preserves the main FILES array.
vd_install_initramfs_config limine /usr/lib/firmware/edid/virtual-display.bin
assert_eq "$VD_INITRAMFS_CONFIG_MANAGED" 1
assert_eq "$VD_INITRAMFS_CONFIG_CHANGED" 1
assert_file_has "$VD_MKINITCPIO_DROPIN" 'FILES+=(/usr/lib/firmware/edid/virtual-display.bin)'
touch -d @1000000000 "$VD_MKINITCPIO_DROPIN"
vd_install_initramfs_config limine /usr/lib/firmware/edid/virtual-display.bin
assert_eq "$VD_INITRAMFS_CONFIG_MANAGED" 1
assert_eq "$VD_INITRAMFS_CONFIG_CHANGED" 0
assert_eq "$(stat -c %Y "$VD_MKINITCPIO_DROPIN")" 1000000000
vd_remove_initramfs_config limine 1
assert_eq "$VD_INITRAMFS_CONFIG_CHANGED" 1
assert_absent "$VD_MKINITCPIO_DROPIN"
vd_remove_initramfs_config limine 1
assert_eq "$VD_INITRAMFS_CONFIG_CHANGED" 0
assert_file_has "$VD_MKINITCPIO_CONF" 'FILES=(/existing)'

# Mutation failures are surfaced so uninstall cannot discard its recovery
# journal while a managed fragment remains.
vd_install_initramfs_config limine /usr/lib/firmware/edid/virtual-display.bin
chmod 0555 "$(dirname "$VD_MKINITCPIO_DROPIN")"
if vd_remove_initramfs_config limine 1 2>/dev/null; then
    chmod 0755 "$(dirname "$VD_MKINITCPIO_DROPIN")"
    fail "permission-denied initramfs removal unexpectedly succeeded"
fi
chmod 0755 "$(dirname "$VD_MKINITCPIO_DROPIN")"
assert_file_has "$VD_MKINITCPIO_DROPIN" "$VD_FRAGMENT_MARKER"
vd_remove_initramfs_config limine 1

printf 'FILES=(/existing /usr/lib/firmware/edid/virtual-display.bin)\n' > "$VD_MKINITCPIO_CONF"
vd_install_initramfs_config limine /usr/lib/firmware/edid/virtual-display.bin
assert_eq "$VD_INITRAMFS_CONFIG_MANAGED" 0
assert_eq "$VD_INITRAMFS_CONFIG_CHANGED" 0
assert_absent "$VD_MKINITCPIO_DROPIN"

# An administrator-owned colliding filename is never overwritten.
printf '# admin sentinel\nFILES+=(/somewhere/else)\n' > "$VD_MKINITCPIO_DROPIN"
printf 'FILES=(/existing)\n' > "$VD_MKINITCPIO_CONF"
cp "$VD_MKINITCPIO_DROPIN" "$ROOT/mkinitcpio.before"
if vd_install_initramfs_config limine /usr/lib/firmware/edid/virtual-display.bin 2>/dev/null; then
    fail "colliding mkinitcpio drop-in unexpectedly succeeded"
fi
assert_eq "$VD_INITRAMFS_CONFIG_MANAGED" 0
assert_eq "$VD_INITRAMFS_CONFIG_CHANGED" 0
cmp -s "$ROOT/mkinitcpio.before" "$VD_MKINITCPIO_DROPIN" || fail "admin mkinitcpio drop-in was modified"

vd_rebuild_initramfs limine
[ -s "$TRACE" ] || fail "Limine rebuild command was not invoked"

echo "platform tests passed"
