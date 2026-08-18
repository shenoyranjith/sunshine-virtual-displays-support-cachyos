#!/usr/bin/env bash
# Install the virtual-display integration for Sunshine.
#
# Supported boot paths:
#   * CachyOS/Arch with Limine + mkinitcpio
#   * Fedora/RHEL-family systems using grubby + dracut
#   * GRUB with mkinitcpio, dracut, or update-initramfs
#
# Inspect without changes: ./install.sh --check
# Install as root:        sudo ./install.sh
set -Eeuo pipefail

CHECK_ONLY=0
case "${1:-}" in
    --check) CHECK_ONLY=1 ;;
    '') ;;
    *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

if [ "$CHECK_ONLY" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

REPO="$(cd "$(dirname "$0")" && pwd)"
. "$REPO/scripts/vdisplay-platform.sh"

if [ "$CHECK_ONLY" = "1" ]; then
    TARGET_USER="${SUDO_USER:-$(id -un)}"
else
    TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
fi
[ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] || {
    echo "Cannot determine the desktop user; run with sudo or set SUDO_USER" >&2
    exit 1
}
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
UID_N="$(id -u "$TARGET_USER")"
[ -n "$USER_HOME" ] && [ "$USER_HOME" != "/" ] || { echo "Invalid user home" >&2; exit 1; }

INSTALL_DIR="${INSTALL_DIR:-$USER_HOME/.local/libexec/vdisplay}"
STATE_DIR="${STATE_DIR:-$USER_HOME/.local/share/vdisplay}"
CONF="$USER_HOME/.config/vdisplay.conf"
USER_UNIT_DIR="$USER_HOME/.config/systemd/user"
HOST_CONF="${HOST_CONF:-$USER_HOME/.config/sunshine/sunshine.conf}"
INSTALL_STATE=/etc/vdisplay-install.conf
REGEN_CONF=/etc/vdisplay-regen.conf
ROOT_LIBEXEC=/usr/local/libexec/vdisplay
REGEN_DIR=/var/lib/vdisplay
EDID_NAME="${EDID_NAME:-virtual-display.bin}"
[[ "$EDID_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
    echo "Invalid EDID_NAME=$EDID_NAME" >&2
    exit 2
}
EDID_DST="/usr/lib/firmware/edid/$EDID_NAME"
# This CachyOS fork is clone-first: replace the old virtual EDID by default,
# but retain it in the recovery journal so uninstall can restore it exactly.
REPLACE_EDID="${REPLACE_EDID:-1}"
EDID_SOURCE_EXPLICIT=0
EDID_SOURCE_FILE_EXPLICIT=0
EDID_IDENTITY_EXPLICIT=0
ALLOW_EDID_TRANSPORT_MISMATCH_EXPLICIT=0
[ "${EDID_SOURCE+x}" != x ] || EDID_SOURCE_EXPLICIT=1
[ "${EDID_SOURCE_FILE+x}" != x ] || EDID_SOURCE_FILE_EXPLICIT=1
[ "${EDID_IDENTITY+x}" != x ] || EDID_IDENTITY_EXPLICIT=1
[ "${ALLOW_EDID_TRANSPORT_MISMATCH+x}" != x ] || \
    ALLOW_EDID_TRANSPORT_MISMATCH_EXPLICIT=1
EDID_SOURCE="${EDID_SOURCE:-physical}"
EDID_SOURCE_FILE="${EDID_SOURCE_FILE:-}"
EDID_IDENTITY="${EDID_IDENTITY:-exact}"
ALLOW_EDID_TRANSPORT_MISMATCH="${ALLOW_EDID_TRANSPORT_MISMATCH:-0}"
DYNAMIC_EDID="${DYNAMIC_EDID:-1}"
BOOT_BACKEND_OVERRIDE="${BOOT_BACKEND:-auto}"
INITRAMFS_BACKEND_OVERRIDE="${INITRAMFS_BACKEND:-auto}"

case "$EDID_SOURCE" in
    physical|generated|file) ;;
    *) echo "Invalid EDID_SOURCE=$EDID_SOURCE (expected physical, generated, or file)" >&2; exit 2 ;;
esac
case "$EDID_IDENTITY" in
    exact|virtualized) ;;
    *) echo "Invalid EDID_IDENTITY=$EDID_IDENTITY (expected exact or virtualized)" >&2; exit 2 ;;
esac
case "$ALLOW_EDID_TRANSPORT_MISMATCH" in
    0|1) ;;
    *) echo "Invalid ALLOW_EDID_TRANSPORT_MISMATCH=$ALLOW_EDID_TRANSPORT_MISMATCH" >&2; exit 2 ;;
esac
case "$REPLACE_EDID:$DYNAMIC_EDID" in
    0:0|0:1|1:0|1:1) ;;
    *) echo "REPLACE_EDID and DYNAMIC_EDID must each be 0 or 1" >&2; exit 2 ;;
esac
if [ "$EDID_SOURCE" = "file" ] && [ -z "$EDID_SOURCE_FILE" ]; then
    echo "EDID_SOURCE_FILE is required when EDID_SOURCE=file" >&2
    exit 2
fi

say() { printf '\n=== %s ===\n' "$*"; }
as_user() {
    runuser -u "$TARGET_USER" -- env -i \
        HOME="$USER_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
        PATH=/usr/local/bin:/usr/bin:/bin "$@"
}
uctl() {
    runuser -u "$TARGET_USER" -- env -i \
        HOME="$USER_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
        PATH=/usr/local/bin:/usr/bin:/bin \
        XDG_RUNTIME_DIR="/run/user/$UID_N" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" \
        systemctl --user "$@"
}
die() { echo "ERROR: $*" >&2; exit 1; }

ensure_user_dir() {
    local path="$1"
    as_user /bin/bash --noprofile --norc -ceu '
        path=$1
        umask 077
        /usr/bin/mkdir -p -- "$path"
        [ -d "$path" ] && [ ! -L "$path" ] || {
            echo "refusing unsafe user directory: $path" >&2
            exit 1
        }
    ' _ "$path"
}

# Content arrives on stdin. All writes and the atomic rename happen after
# dropping privileges, so a user-controlled symlink can never redirect a root
# write. Existing directories keep their mode and ACLs.
write_user_file() {
    local target="$1" mode="$2"
    as_user /bin/bash --noprofile --norc -ceu '
        target=$1; mode=$2
        dir=${target%/*}; base=${target##*/}
        [ "$dir" != "$target" ] && [ -d "$dir" ] && [ ! -L "$dir" ] || {
            echo "refusing unsafe parent directory: $dir" >&2
            exit 1
        }
        umask 077
        tmp=$(/usr/bin/mktemp -- "$dir/.${base}.vdisplay.XXXXXX")
        cleanup() { /usr/bin/rm -f -- "$tmp"; }
        trap cleanup EXIT HUP INT TERM
        /usr/bin/cat > "$tmp"
        /usr/bin/chmod "$mode" "$tmp"
        /usr/bin/mv -fT -- "$tmp" "$target"
        tmp=
        trap - EXIT HUP INT TERM
    ' _ "$target" "$mode"
}

write_root_file() {
    local target="$1" mode="$2" dir base tmp owner permissions
    dir="$(dirname "$target")"; base="$(basename "$target")"
    [ -d "$dir" ] && [ ! -L "$dir" ] || die "unsafe root directory: $dir"
    owner="$(stat -c %u "$dir")" || die "cannot inspect $dir"
    permissions=$((8#$(stat -c %a "$dir")))
    [ "$owner" = "0" ] && (( (permissions & 8#022) == 0 )) || \
        die "root output directory is writable by another user: $dir"
    tmp="$(mktemp -- "$dir/.${base}.vdisplay.XXXXXX")"
    trap 'rm -f -- "$tmp"' RETURN
    cat > "$tmp"
    chmod "$mode" "$tmp"
    mv -fT -- "$tmp" "$target"
    tmp=""
    trap - RETURN
}

safe_root_config() {
    local file="$1" owner mode permissions
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    owner="$(stat -c %u "$file" 2>/dev/null)" || return 1
    mode="$(stat -c %a "$file" 2>/dev/null)" || return 1
    [ "$owner" = "0" ] || return 1
    permissions=$((8#$mode))
    (( (permissions & 8#022) == 0 ))
}

safe_root_dir() {
    local dir="$1" owner mode permissions
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    owner="$(stat -c %u "$dir" 2>/dev/null)" || return 1
    mode="$(stat -c %a "$dir" 2>/dev/null)" || return 1
    [ "$owner" = "0" ] || return 1
    permissions=$((8#$mode))
    (( (permissions & 8#022) == 0 ))
}

ensure_root_dir() {
    local dir="$1" mode="$2"
    if [ -e "$dir" ]; then
        safe_root_dir "$dir" || die "unsafe root directory: $dir"
    else
        install -d -m"$mode" -o root -g root "$dir"
        safe_root_dir "$dir" || die "could not create safe root directory: $dir"
    fi
}

root_asset_path_allowed() {
    case "$1" in
        /usr/local/libexec/vdisplay/generate_edid.py|\
        /usr/local/libexec/vdisplay/vdisplay-platform.sh|\
        /etc/vdisplay-regen.conf|\
        /etc/systemd/system/vdisplay-edid-regen.path|\
        /etc/systemd/system/vdisplay-edid-regen.service|\
        /usr/local/sbin/vdisplay-edid-regen.sh) return 0 ;;
        *) return 1 ;;
    esac
}

script_asset_name_allowed() {
    case "$1" in
        generate_edid.py|pick-mode.py|vdisplay-common.sh|vdisplay-up.sh|\
        vdisplay-down.sh|monitor-watchdog.sh) return 0 ;;
        *) return 1 ;;
    esac
}

validate_hash_manifest() {
    local manifest="$1" kind="$2" key hash extra seen=""
    while read -r key hash extra; do
        [ -n "$key" ] || continue
        [ -z "$extra" ] && [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || \
            die "invalid $kind hash metadata in $INSTALL_STATE"
        case "$kind" in
            root) root_asset_path_allowed "$key" || die "invalid root asset in $INSTALL_STATE: $key" ;;
            script) script_asset_name_allowed "$key" || die "invalid script asset in $INSTALL_STATE: $key" ;;
        esac
        case $'\n'"$seen"$'\n' in
            *$'\n'"$key"$'\n'*) die "duplicate $kind asset in $INSTALL_STATE: $key" ;;
        esac
        seen+="${seen:+$'\n'}$key"
    done <<< "$manifest"
}

manifest_hash_for() {
    local wanted="$1" manifest="$2" key hash extra
    while read -r key hash extra; do
        if [ "$key" = "$wanted" ]; then
            printf '%s\n' "$hash"
            return 0
        fi
    done <<< "$manifest"
    return 1
}

verify_prior_root_asset() {
    local path="$1" expected actual
    if [ -e "$path" ] || [ -L "$path" ]; then
        expected="$(manifest_hash_for "$path" "$PRIOR_INSTALLED_ROOT_ASSET_HASHES")" || \
            die "$path exists without trusted ownership metadata"
        safe_root_config "$path" || die "unsafe previously installed root asset: $path"
        actual="$(sha256sum "$path" | awk '{ print $1 }')"
        [ "$actual" = "$expected" ] || die "previously installed root asset was modified: $path"
    fi
}

verify_prior_user_asset() {
    local path="$1" expected="$2" label="$3" actual
    if [ -e "$path" ] || [ -L "$path" ]; then
        [ -n "$expected" ] || die "$path exists without trusted ownership metadata"
        [ -f "$path" ] && [ ! -L "$path" ] || die "unsafe previously installed $label: $path"
        actual="$(as_user sha256sum "$path" | awk '{ print $1 }')"
        [ "$actual" = "$expected" ] || die "previously installed $label was modified: $path"
    fi
}

record_root_asset() {
    local path="$1" hash key old_hash extra updated=""
    hash="$(sha256sum "$path" | awk '{ print $1 }')"
    while read -r key old_hash extra; do
        [ -n "$key" ] || continue
        [ "$key" = "$path" ] && continue
        updated+="${updated:+$'\n'}$key $old_hash"
    done <<< "$INSTALLED_ROOT_ASSET_HASHES"
    INSTALLED_ROOT_ASSET_HASHES="${updated}${updated:+$'\n'}$path $hash"
}

PRIOR_EDID_MANAGED=0
PRIOR_EDID_BACKUP=""
PRIOR_EDID_DST=""
PRIOR_EDID_SOURCE=""
PRIOR_EDID_SOURCE_REF=""
PRIOR_EDID_SOURCE_HASH=""
PRIOR_EDID_IDENTITY=""
PRIOR_EDID_SOURCE_INTERFACE=""
PRIOR_EDID_TARGET_INTERFACE=""
PRIOR_EDID_SOURCE_SNAPSHOT=""
PRIOR_ALLOW_EDID_TRANSPORT_MISMATCH=""
PRIOR_BOOT_BACKEND=""
PRIOR_VIRT_OUTPUT=""
PRIOR_EDID_NAME=""
PRIOR_KARGS_MANAGED=0
PRIOR_KARGS_ADDED=""
PRIOR_KARGS_PENDING=0
PRIOR_KARGS_PENDING_ARGS=""
PRIOR_INITRAMFS_BACKEND=""
PRIOR_INITRAMFS_CONFIG_MANAGED=0
PRIOR_INITRAMFS_CONFIG_PENDING=0
PRIOR_SUNSHINE_PATCHED=0
SUN_CAPTURE_OLD_LINES=""
SUN_OUTPUT_OLD_LINES=""
SUN_PREP_OLD_LINES=""
SUN_CAPTURE_INSTALLED_VALUE=""
SUN_OUTPUT_INSTALLED_VALUE=""
SUN_PREP_INSTALLED_VALUE=""
PRIOR_INSTALLED_SCRIPT_HASHES=""
PRIOR_INSTALLED_ROOT_ASSET_HASHES=""
PRIOR_INSTALLED_USER_UNIT_HASH=""
HAVE_PRIOR_INSTALL_STATE=0
read_install_state() {
    local name="$1"
    bash -c '. "$1"; name=$2; printf "%s" "${!name-}"' _ "$INSTALL_STATE" "$name"
}
if { [ "$CHECK_ONLY" != "1" ] || [ "$(id -u)" -eq 0 ]; } && \
   safe_root_config "$INSTALL_STATE"; then
    HAVE_PRIOR_INSTALL_STATE=1
    PRIOR_EDID_MANAGED="$(read_install_state EDID_MANAGED)"
    PRIOR_EDID_BACKUP="$(read_install_state EDID_BACKUP)"
    PRIOR_EDID_DST="$(read_install_state EDID_DST)"
    PRIOR_EDID_SOURCE="$(read_install_state EDID_SOURCE)"
    PRIOR_EDID_SOURCE_REF="$(read_install_state EDID_SOURCE_REF)"
    PRIOR_EDID_SOURCE_HASH="$(read_install_state EDID_SOURCE_HASH)"
    PRIOR_EDID_IDENTITY="$(read_install_state EDID_IDENTITY)"
    PRIOR_EDID_SOURCE_INTERFACE="$(read_install_state EDID_SOURCE_INTERFACE)"
    PRIOR_EDID_TARGET_INTERFACE="$(read_install_state EDID_TARGET_INTERFACE)"
    PRIOR_EDID_SOURCE_SNAPSHOT="$(read_install_state EDID_SOURCE_SNAPSHOT)"
    PRIOR_ALLOW_EDID_TRANSPORT_MISMATCH="$(read_install_state ALLOW_EDID_TRANSPORT_MISMATCH)"
    PRIOR_BOOT_BACKEND="$(read_install_state BOOT_BACKEND)"
    PRIOR_VIRT_OUTPUT="$(read_install_state VIRT_OUTPUT)"
    PRIOR_EDID_NAME="$(read_install_state EDID_NAME)"
    PRIOR_KARGS_MANAGED="$(read_install_state KARGS_MANAGED)"
    PRIOR_KARGS_ADDED="$(read_install_state KARGS_ADDED)"
    PRIOR_KARGS_PENDING="$(read_install_state KARGS_PENDING)"
    PRIOR_KARGS_PENDING_ARGS="$(read_install_state KARGS_PENDING_ARGS)"
    PRIOR_INITRAMFS_BACKEND="$(read_install_state INITRAMFS_BACKEND)"
    PRIOR_INITRAMFS_CONFIG_MANAGED="$(read_install_state INITRAMFS_CONFIG_MANAGED)"
    PRIOR_INITRAMFS_CONFIG_PENDING="$(read_install_state INITRAMFS_CONFIG_PENDING)"
    PRIOR_SUNSHINE_PATCHED="$(read_install_state SUNSHINE_PATCHED)"
    SUN_CAPTURE_OLD_LINES="$(read_install_state SUN_CAPTURE_OLD_LINES)"
    SUN_OUTPUT_OLD_LINES="$(read_install_state SUN_OUTPUT_OLD_LINES)"
    SUN_PREP_OLD_LINES="$(read_install_state SUN_PREP_OLD_LINES)"
    SUN_CAPTURE_INSTALLED_VALUE="$(read_install_state SUN_CAPTURE_INSTALLED_VALUE)"
    SUN_OUTPUT_INSTALLED_VALUE="$(read_install_state SUN_OUTPUT_INSTALLED_VALUE)"
    SUN_PREP_INSTALLED_VALUE="$(read_install_state SUN_PREP_INSTALLED_VALUE)"
    PRIOR_INSTALLED_SCRIPT_HASHES="$(read_install_state INSTALLED_SCRIPT_HASHES)"
    PRIOR_INSTALLED_ROOT_ASSET_HASHES="$(read_install_state INSTALLED_ROOT_ASSET_HASHES)"
    PRIOR_INSTALLED_USER_UNIT_HASH="$(read_install_state INSTALLED_USER_UNIT_HASH)"
fi
: "${PRIOR_KARGS_PENDING:=0}" "${PRIOR_KARGS_PENDING_ARGS:=}"
: "${PRIOR_INITRAMFS_CONFIG_PENDING:=0}"
: "${PRIOR_INSTALLED_SCRIPT_HASHES:=}" "${PRIOR_INSTALLED_ROOT_ASSET_HASHES:=}"
: "${PRIOR_INSTALLED_USER_UNIT_HASH:=}"
: "${PRIOR_EDID_SOURCE:=}" "${PRIOR_EDID_SOURCE_REF:=}" "${PRIOR_EDID_SOURCE_HASH:=}"
: "${PRIOR_EDID_IDENTITY:=}" "${PRIOR_EDID_SOURCE_INTERFACE:=}"
: "${PRIOR_EDID_TARGET_INTERFACE:=}" "${PRIOR_EDID_SOURCE_SNAPSHOT:=}"
: "${PRIOR_ALLOW_EDID_TRANSPORT_MISMATCH:=}"
if [ "$HAVE_PRIOR_INSTALL_STATE" = "1" ] && [ -n "$PRIOR_EDID_SOURCE" ]; then
    if [ "$EDID_SOURCE_EXPLICIT" != "1" ]; then
        EDID_SOURCE="$PRIOR_EDID_SOURCE"
    fi
    if [ "$EDID_IDENTITY_EXPLICIT" != "1" ] && [ -n "$PRIOR_EDID_IDENTITY" ]; then
        EDID_IDENTITY="$PRIOR_EDID_IDENTITY"
    fi
    if [ "$EDID_SOURCE" = file ] && [ "$EDID_SOURCE_FILE_EXPLICIT" != "1" ]; then
        EDID_SOURCE_FILE="$PRIOR_EDID_SOURCE_REF"
    fi
    if [ "$ALLOW_EDID_TRANSPORT_MISMATCH_EXPLICIT" != "1" ] && \
       [ -n "$PRIOR_ALLOW_EDID_TRANSPORT_MISMATCH" ]; then
        ALLOW_EDID_TRANSPORT_MISMATCH="$PRIOR_ALLOW_EDID_TRANSPORT_MISMATCH"
    fi
fi
case "$EDID_SOURCE:$EDID_IDENTITY" in
    physical:exact|physical:virtualized|generated:exact|generated:virtualized|\
    file:exact|file:virtualized) ;;
    *) die "invalid EDID source policy in prior installation" ;;
esac
[ "$EDID_SOURCE" != file ] || [ -n "$EDID_SOURCE_FILE" ] || \
    die "prior file EDID source has no path provenance"
case "$ALLOW_EDID_TRANSPORT_MISMATCH" in
    0|1) ;;
    *) die "invalid transport-override policy in prior installation" ;;
esac
case "$PRIOR_KARGS_PENDING:$PRIOR_INITRAMFS_CONFIG_PENDING" in
    0:0) ;;
    0:1|1:0|1:1)
        die "a previous installation was interrupted during boot configuration; run sudo ./uninstall.sh first"
        ;;
    *) die "invalid pending-operation metadata in $INSTALL_STATE" ;;
esac
[ -z "$PRIOR_EDID_DST" ] || [ "$PRIOR_EDID_DST" = "$EDID_DST" ] || \
    [ "$PRIOR_EDID_MANAGED" != "1" ] || \
    die "EDID_NAME changed while the prior EDID is installer-owned; uninstall first"
[ "$PRIOR_EDID_DST" = "$EDID_DST" ] || {
    PRIOR_EDID_MANAGED=0
    PRIOR_EDID_BACKUP=""
}
validate_connector() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid DRM connector: $1"
}

read_connector_config() {
    local key="$1" value=""
    [ -r "$CONF" ] || return 1
    if [ "$CHECK_ONLY" = "1" ]; then
        value="$(sed -n \
            -e "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\"\([A-Za-z0-9._-]*\)\"[[:space:]]*$/\1/p" \
            -e "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\([A-Za-z0-9._-]*\)[[:space:]]*$/\1/p" \
            "$CONF" | head -n1)"
    else
        value="$(as_user sed -n \
            -e "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\"\([A-Za-z0-9._-]*\)\"[[:space:]]*$/\1/p" \
            -e "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\([A-Za-z0-9._-]*\)[[:space:]]*$/\1/p" \
            "$CONF" | head -n1)"
    fi
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

connector_from_cmdline() {
    local arg value
    [ -r /proc/cmdline ] || return 1
    for arg in $(</proc/cmdline); do
        case "$arg" in
            drm.edid_firmware=*:edid/"$EDID_NAME")
                value="${arg#drm.edid_firmware=}"
                value="${value%%:*}"
                validate_connector "$value"
                printf '%s\n' "$value"
                return 0
                ;;
        esac
    done
    return 1
}

cmdline_has_edid_mapping() {
    local connector="$1" edid_name="$2" arg value entry
    local -a entries=()
    [ -r /proc/cmdline ] || return 1
    for arg in $(</proc/cmdline); do
        case "$arg" in
            drm.edid_firmware=*)
                value="${arg#drm.edid_firmware=}"
                IFS=, read -r -a entries <<< "$value"
                for entry in "${entries[@]}"; do
                    [ "$entry" = "$connector:edid/$edid_name" ] && return 0
                done
                ;;
        esac
    done
    return 1
}

cmdline_has_force_enable() {
    local connector="$1" arg
    [ -r /proc/cmdline ] || return 1
    for arg in $(</proc/cmdline); do
        [ "$arg" = "video=$connector:e" ] && return 0
    done
    return 1
}

sunshine_drm_card() {
    local adapter render path
    [ -r "$HOST_CONF" ] || return 1
    if [ "$CHECK_ONLY" = "1" ]; then
        adapter="$(sed -n 's/^[[:space:]]*adapter_name[[:space:]]*=[[:space:]]*//p' "$HOST_CONF" | tail -n1)"
    else
        adapter="$(as_user sed -n 's/^[[:space:]]*adapter_name[[:space:]]*=[[:space:]]*//p' "$HOST_CONF" | tail -n1)"
    fi
    adapter="${adapter%\"}"; adapter="${adapter#\"}"
    [ -n "$adapter" ] || return 1
    render="$(basename "$adapter")"
    for path in "/sys/class/drm/$render/device/drm"/card[0-9]*; do
        [ -e "$path" ] || continue
        basename "$path"
        return 0
    done
    return 1
}

card_for_connector() {
    local connector="$1" preferred="${2:-}" path found=""
    if [ -n "$preferred" ] && [ -e "/sys/class/drm/$preferred-$connector/status" ]; then
        printf '%s\n' "$preferred"
        return 0
    fi
    for path in /sys/class/drm/card[0-9]*-"$connector"/status; do
        [ -e "$path" ] || continue
        if [ -n "$found" ]; then
            die "connector $connector exists on multiple DRM cards; set DRM_CARD=cardN"
        fi
        found="$(basename "$(dirname "$path")")"
        found="${found%%-$connector}"
    done
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

preferred_gpu_card() {
    local path driver driver_path vendor
    for path in /sys/class/drm/card[0-9]*; do
        [ -d "$path/device" ] || continue
        driver_path="$(readlink -f "$path/device/driver" 2>/dev/null || true)"
        driver="${driver_path##*/}"
        vendor="$(cat "$path/device/vendor" 2>/dev/null || true)"
        if [ "$driver" = "nvidia" ] || [ "$vendor" = "0x10de" ]; then
            basename "$path"
            return 0
        fi
    done
    return 1
}

detect_connector() {
    local card="$1" wanted="$2" exclude="${3:-}" path name
    for path in /sys/class/drm/"$card"-*/status; do
        [ -r "$path" ] && [ "$(<"$path")" = "$wanted" ] || continue
        name="$(basename "$(dirname "$path")")"
        name="${name#"$card"-}"
        [ "$name" = "$exclude" ] && continue
        case "$name" in Virtual-*|Writeback-*) continue ;; esac
        printf '%s\n' "$name"
        return 0
    done
    return 1
}

connector_edid_interface() {
    case "$1" in
        DP-*|eDP-*) printf '%s\n' displayport ;;
        HDMI-A-*|HDMI-B-*) printf '%s\n' hdmi ;;
        DVI-*) printf '%s\n' dvi ;;
        *) printf '%s\n' unknown ;;
    esac
}

normalize_edid_interface() {
    case "${1,,}" in
        displayport|display-port|dp) printf '%s\n' displayport ;;
        hdmi|hdmi-a|hdmi-b) printf '%s\n' hdmi ;;
        dvi|dvi-i|dvi-d|dvi-a) printf '%s\n' dvi ;;
        *) printf '%s\n' unknown ;;
    esac
}

# EDID sysfs attributes intentionally report st_size=0. Read until EOF and
# validate the bytes afterwards instead of trusting file metadata.
read_edid_content() {
    local source="$1" destination="$2"
    dd if="$source" of="$destination" bs=32768 count=2 status=none || \
        die "could not read EDID content from $source"
    [ -s "$destination" ] || die "EDID source returned no data: $source"
}

# EDID_SOURCE_FILE may live in a user-controlled directory. Open it after
# dropping privileges so a rename race can never make root disclose or copy a
# file the desktop user could not read. The timeout also bounds a FIFO/device
# swap between the metadata check and open.
read_user_edid_content() {
    local source="$1" destination="$2"
    if [ "$CHECK_ONLY" = "1" ]; then
        timeout 5 dd if="$source" of="$destination" bs=32768 count=2 status=none || \
            die "could not read EDID_SOURCE_FILE as $TARGET_USER: $source"
    else
        as_user timeout 5 dd if="$source" bs=32768 count=2 status=none > "$destination" || \
            die "could not read EDID_SOURCE_FILE as $TARGET_USER: $source"
    fi
    [ -s "$destination" ] || die "EDID_SOURCE_FILE returned no data: $source"
}

inspect_edid() {
    local path="$1" inspection
    inspection="$(python3 "$REPO/scripts/generate_edid.py" --inspect-source "$path")" || \
        die "invalid EDID structure: $path"
    jq -e '.bytes >= 128 and .blocks >= 1 and (.interface | type == "string")' \
        >/dev/null <<< "$inspection" || die "invalid EDID inspection result for $path"
    printf '%s\n' "$inspection"
}

persistent_kernel_arg_text() {
    local backend="$1" file
    case "$backend" in
        limine)
            while IFS= read -r file; do
                [ -f "$file" ] || continue
                [ ! -L "$file" ] || die "unsafe symlinked Limine configuration: $file"
                cat -- "$file"
            done < <(vd_limine_config_files)
            ;;
        grub)
            [ -f "$VD_GRUB_DEFAULT" ] && cat -- "$VD_GRUB_DEFAULT"
            ;;
        grubby)
            grubby --info=ALL
            ;;
        *) return 1 ;;
    esac
}

# Print connector names already persistently mapped to this firmware filename,
# excluding the connector selected for this installation.
persistent_edid_mapping_conflicts() {
    local backend="$1" desired="$2" edid_name="$3"
    persistent_kernel_arg_text "$backend" | awk -v desired="$desired" -v name="$edid_name" '
        /^[[:space:]]*#/ { next }
        {
            line=$0
            while (match(line, /drm[.]edid_firmware=[^[:space:]"\047;]+/)) {
                token=substr(line, RSTART, RLENGTH)
                sub(/^drm[.]edid_firmware=/, "", token)
                count=split(token, entries, ",")
                suffix=":edid/" name
                for (i=1; i<=count; i++) {
                    entry=entries[i]
                    if (length(entry) > length(suffix) &&
                        substr(entry, length(entry)-length(suffix)+1) == suffix) {
                        connector=substr(entry, 1, length(entry)-length(suffix))
                        if (connector != desired) print connector
                    }
                }
                line=substr(line, RSTART + RLENGTH)
            }
        }
    ' | sort -u
}

write_root_config() {
    local target="$1" var dir base tmp
    shift
    dir="$(dirname "$target")"; base="$(basename "$target")"
    safe_root_dir "$dir" || die "unsafe root config directory: $dir"
    umask 077
    tmp="$(mktemp -- "$dir/.${base}.vdisplay.XXXXXX")"
    trap 'rm -f -- "$tmp"' RETURN
    for var in "$@"; do
        printf '%s=%q\n' "$var" "${!var}" >> "$tmp"
    done
    chmod 0600 "$tmp"
    mv -fT -- "$tmp" "$target"
    tmp=""
    trap - RETURN
}

# Detect everything that could fail before changing the system.
say "Preflight"
DISTRO_FAMILY="$(vd_detect_distro_family)"
BOOT_BACKEND="$(vd_detect_boot_backend "$BOOT_BACKEND_OVERRIDE")" || die "set BOOT_BACKEND explicitly"
INITRAMFS_BACKEND="$(vd_detect_initramfs_backend "$BOOT_BACKEND" "$INITRAMFS_BACKEND_OVERRIDE")" || \
    die "set INITRAMFS_BACKEND explicitly"

required=(python3 install sed grep awk systemctl systemd-run runuser kscreen-doctor kde-inhibit jq mktemp flock sha256sum dd cmp wc readlink timeout)
missing=()
for command_name in "${required[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing commands: ${missing[*]}" >&2
    if [ "$DISTRO_FAMILY" = "arch" ]; then
        echo "CachyOS packages normally needed: python libkscreen kde-cli-tools jq systemd util-linux limine-mkinitcpio-hook" >&2
    fi
    exit 1
fi
case "$BOOT_BACKEND" in
    limine) command -v "$VD_LIMINE_CMD" >/dev/null 2>&1 || die "missing $VD_LIMINE_CMD" ;;
    grubby) command -v grubby >/dev/null 2>&1 || die "missing grubby" ;;
    grub) [ -f "$VD_GRUB_DEFAULT" ] || die "missing $VD_GRUB_DEFAULT" ;;
esac
case "$INITRAMFS_BACKEND" in
    limine) command -v "$VD_LIMINE_CMD" >/dev/null 2>&1 || die "missing $VD_LIMINE_CMD" ;;
    mkinitcpio) { [ -x "$VD_MKINITCPIO_CMD" ] || command -v mkinitcpio >/dev/null 2>&1; } || die "missing mkinitcpio" ;;
    dracut) command -v "$VD_DRACUT_CMD" >/dev/null 2>&1 || die "missing dracut" ;;
    update-initramfs) command -v "$VD_UPDATE_INITRAMFS_CMD" >/dev/null 2>&1 || die "missing update-initramfs" ;;
esac
printf '  distro=%s bootloader=%s initramfs=%s\n' "$DISTRO_FAMILY" "$BOOT_BACKEND" "$INITRAMFS_BACKEND"

for user_input in "$CONF" "$HOST_CONF"; do
    if [ -e "$user_input" ] || [ -L "$user_input" ]; then
        [ -f "$user_input" ] && [ ! -L "$user_input" ] || die "refusing unsafe user config: $user_input"
        if [ "$CHECK_ONLY" = "1" ]; then
            [ -r "$user_input" ] || die "cannot read $user_input"
        else
            as_user /usr/bin/test -r "$user_input" || die "$TARGET_USER cannot read $user_input"
        fi
    fi
done

say "Detecting DRM connectors"
SUNSHINE_CARD="$(sunshine_drm_card || true)"
VIRT_OUTPUT="${VIRT_OUTPUT:-$(read_connector_config VIRT_OUTPUT || true)}"
[ -n "$VIRT_OUTPUT" ] || VIRT_OUTPUT="$(connector_from_cmdline || true)"
PHYS_OUTPUT="${PHYS_OUTPUT:-$(read_connector_config PHYS_OUTPUT || true)}"
PHYS_MODE="${PHYS_MODE:-}"

DRM_CARD="${DRM_CARD:-}"
[ -n "$DRM_CARD" ] || {
    if [ -n "$VIRT_OUTPUT" ]; then
        DRM_CARD="$(card_for_connector "$VIRT_OUTPUT" "$SUNSHINE_CARD" || true)"
    fi
}
[ -n "$DRM_CARD" ] || DRM_CARD="$SUNSHINE_CARD"
[ -n "$DRM_CARD" ] || DRM_CARD="$(preferred_gpu_card || true)"
[ -n "$DRM_CARD" ] || die "could not select a DRM card; set DRM_CARD=cardN"
DRM_CARD="$(basename "$DRM_CARD")"
[[ "$DRM_CARD" =~ ^card[0-9]+$ ]] || die "invalid DRM_CARD=$DRM_CARD"
[ -d "/sys/class/drm/$DRM_CARD" ] || die "$DRM_CARD does not exist"

[ -n "$VIRT_OUTPUT" ] || VIRT_OUTPUT="$(detect_connector "$DRM_CARD" disconnected || true)"
[ -n "$PHYS_OUTPUT" ] || PHYS_OUTPUT="$(detect_connector "$DRM_CARD" connected "$VIRT_OUTPUT" || true)"
[ -n "$VIRT_OUTPUT" ] || die "no spare connector found on $DRM_CARD; set VIRT_OUTPUT="
[ -n "$PHYS_OUTPUT" ] || die "no physical monitor found on $DRM_CARD; set PHYS_OUTPUT="
validate_connector "$VIRT_OUTPUT"
validate_connector "$PHYS_OUTPUT"
[ "$VIRT_OUTPUT" != "$PHYS_OUTPUT" ] || die "virtual and physical connectors must differ"
[ -e "/sys/class/drm/$DRM_CARD-$VIRT_OUTPUT/status" ] || die "$VIRT_OUTPUT is not on $DRM_CARD"
[ -e "/sys/class/drm/$DRM_CARD-$PHYS_OUTPUT/status" ] || die "$PHYS_OUTPUT is not on $DRM_CARD"

VIRT_STATUS="$(<"/sys/class/drm/$DRM_CARD-$VIRT_OUTPUT/status")"
if [ "$VIRT_STATUS" != disconnected ]; then
    TRUSTED_FORCED_VIRTUAL=0
    if [ "$VIRT_STATUS" = connected ] && [ "$HAVE_PRIOR_INSTALL_STATE" = "1" ] && \
       [ "$PRIOR_EDID_MANAGED" = "1" ] && \
       [ "$PRIOR_VIRT_OUTPUT" = "$VIRT_OUTPUT" ] && \
       [ "$PRIOR_EDID_NAME" = "$EDID_NAME" ] && \
       [ "$PRIOR_EDID_DST" = "$EDID_DST" ] && \
       cmdline_has_edid_mapping "$VIRT_OUTPUT" "$EDID_NAME" && \
       cmdline_has_force_enable "$VIRT_OUTPUT"; then
        TRUSTED_FORCED_VIRTUAL=1
    fi
    if [ "$TRUSTED_FORCED_VIRTUAL" != "1" ]; then
        die "$VIRT_OUTPUT is currently $VIRT_STATUS; a new virtual target must be disconnected. Capture any source EDID first, unplug the target cable, and retry. For a trusted existing installation whose forced connector is active, run --check with sudo so install state can be verified."
    fi
    echo "WARN: accepting connected $VIRT_OUTPUT because trusted install state and the running firmware override match; ensure no physical sink is attached" >&2
fi

DRIVER_PATH="$(readlink -f "/sys/class/drm/$DRM_CARD/device/driver" 2>/dev/null || true)"
DRIVER="${DRIVER_PATH##*/}"
printf '  GPU card  -> %s (driver=%s)\n' "$DRM_CARD" "${DRIVER:-unknown}"
if [ "$VIRT_STATUS" = disconnected ]; then
    printf '  virtual   -> %s (disconnected)\n' "$VIRT_OUTPUT"
else
    printf '  virtual   -> %s (trusted forced connection)\n' "$VIRT_OUTPUT"
fi
printf '  physical  -> %s (mode=%s)\n' "$PHYS_OUTPUT" "${PHYS_MODE:-preferred}"

# Resolve and validate the EDID source only after both connectors have been
# proven to belong to the selected DRM card. All work here is confined to
# temporary files, so a bad source or transport mismatch fails before any
# installation path is mutated.
EDID_TARGET_INTERFACE="$(connector_edid_interface "$VIRT_OUTPUT")"
EDID_SOURCE_INTERFACE=""
EDID_SOURCE_REF=""
EDID_SOURCE_HASH=""
EDID_SOURCE_SNAPSHOT="$REGEN_DIR/source-edid.bin"
EDID_SOURCE_CANDIDATE="$(mktemp /tmp/vdisplay-source-edid.XXXXXX)"
EDID_RENDERED_CANDIDATE="$(mktemp /tmp/vdisplay-rendered-edid.XXXXXX)"
cleanup_edid_candidates() {
    rm -f -- "$EDID_SOURCE_CANDIDATE" "$EDID_RENDERED_CANDIDATE"
}
trap cleanup_edid_candidates EXIT HUP INT TERM

USE_PRIOR_EDID_SNAPSHOT=0
if [ "$HAVE_PRIOR_INSTALL_STATE" = "1" ] && \
   [ "$PRIOR_EDID_MANAGED" = "1" ] && [ -n "$PRIOR_EDID_SOURCE_HASH" ]; then
    [ "$PRIOR_EDID_SOURCE" = "$EDID_SOURCE" ] && \
        [ "$PRIOR_EDID_IDENTITY" = "$EDID_IDENTITY" ] && \
        [ "$PRIOR_EDID_TARGET_INTERFACE" = "$EDID_TARGET_INTERFACE" ] || \
        die "EDID source, identity, or target transport changed; uninstall first"
    case "$EDID_SOURCE" in
        physical)
            EDID_SOURCE_REF="/sys/class/drm/$DRM_CARD-$PHYS_OUTPUT/edid"
            ;;
        file)
            if [ "$EDID_SOURCE_FILE_EXPLICIT" = "1" ]; then
                [ ! -L "$EDID_SOURCE_FILE" ] || \
                    die "EDID_SOURCE_FILE must not be a symlink"
                as_user test -f "$EDID_SOURCE_FILE" || \
                    die "EDID_SOURCE_FILE must be a regular file readable by $TARGET_USER"
                EDID_SOURCE_FILE="$(as_user readlink -f -- "$EDID_SOURCE_FILE")" || \
                    die "could not resolve EDID_SOURCE_FILE as $TARGET_USER"
                EDID_SOURCE_REF="$EDID_SOURCE_FILE"
            else
                EDID_SOURCE_REF="$PRIOR_EDID_SOURCE_REF"
                EDID_SOURCE_FILE="$EDID_SOURCE_REF"
            fi
            ;;
        generated)
            case "$EDID_TARGET_INTERFACE" in
                displayport|hdmi) ;;
                *) die "generated EDIDs do not support target connector type: $VIRT_OUTPUT" ;;
            esac
            EDID_SOURCE_REF="generated:$EDID_TARGET_INTERFACE"
            ;;
    esac
    [ "$PRIOR_EDID_SOURCE_REF" = "$EDID_SOURCE_REF" ] || \
        die "EDID source path changed; uninstall first"
    [ "$PRIOR_EDID_SOURCE_SNAPSHOT" = "$EDID_SOURCE_SNAPSHOT" ] || \
        die "invalid EDID snapshot provenance in $INSTALL_STATE"
    safe_root_config "$EDID_SOURCE_SNAPSHOT" || \
        die "trusted EDID source snapshot is missing or unsafe"
    [ "$(sha256sum "$EDID_SOURCE_SNAPSHOT" | awk '{ print $1 }')" = "$PRIOR_EDID_SOURCE_HASH" ] || \
        die "immutable EDID source snapshot was modified"
    read_edid_content "$EDID_SOURCE_SNAPSHOT" "$EDID_SOURCE_CANDIDATE"
    USE_PRIOR_EDID_SNAPSHOT=1
else
    if [ -e "$EDID_SOURCE_SNAPSHOT" ] || [ -L "$EDID_SOURCE_SNAPSHOT" ]; then
        die "$EDID_SOURCE_SNAPSHOT exists without trusted source provenance"
    fi
    case "$EDID_SOURCE" in
        physical)
            EDID_SOURCE_REF="/sys/class/drm/$DRM_CARD-$PHYS_OUTPUT/edid"
            [ -r "$EDID_SOURCE_REF" ] || \
                die "physical EDID is unreadable: $EDID_SOURCE_REF"
            [ "$(<"/sys/class/drm/$DRM_CARD-$PHYS_OUTPUT/status")" = connected ] || \
                die "physical EDID source is not connected: $PHYS_OUTPUT"
            read_edid_content "$EDID_SOURCE_REF" "$EDID_SOURCE_CANDIDATE"
            ;;
        file)
            [ ! -L "$EDID_SOURCE_FILE" ] || \
                die "EDID_SOURCE_FILE must not be a symlink"
            if [ "$CHECK_ONLY" = "1" ]; then
                [ -f "$EDID_SOURCE_FILE" ] || \
                    die "EDID_SOURCE_FILE must be a regular file"
                EDID_SOURCE_FILE="$(readlink -f -- "$EDID_SOURCE_FILE")" || \
                    die "could not resolve EDID_SOURCE_FILE"
            else
                as_user test -f "$EDID_SOURCE_FILE" || \
                    die "EDID_SOURCE_FILE must be a regular file readable by $TARGET_USER"
                EDID_SOURCE_FILE="$(as_user readlink -f -- "$EDID_SOURCE_FILE")" || \
                    die "could not resolve EDID_SOURCE_FILE as $TARGET_USER"
            fi
            [ -n "$EDID_SOURCE_FILE" ] || die "could not resolve EDID_SOURCE_FILE"
            EDID_SOURCE_REF="$EDID_SOURCE_FILE"
            read_user_edid_content "$EDID_SOURCE_REF" "$EDID_SOURCE_CANDIDATE"
            ;;
        generated)
            case "$EDID_TARGET_INTERFACE" in
                displayport|hdmi) ;;
                *) die "generated EDIDs do not support target connector type: $VIRT_OUTPUT" ;;
            esac
            EDID_SOURCE_REF="generated:$EDID_TARGET_INTERFACE"
            python3 "$REPO/scripts/generate_edid.py" "$EDID_SOURCE_CANDIDATE" \
                --interface "$EDID_TARGET_INTERFACE" || \
                die "could not generate baseline EDID"
            ;;
    esac
fi

EDID_SOURCE_INSPECTION="$(inspect_edid "$EDID_SOURCE_CANDIDATE")"
EDID_SOURCE_INTERFACE="$(jq -r '.interface' <<< "$EDID_SOURCE_INSPECTION")"
EDID_SOURCE_INTERFACE="$(normalize_edid_interface "$EDID_SOURCE_INTERFACE")"
EDID_SOURCE_HASH="$(sha256sum "$EDID_SOURCE_CANDIDATE" | awk '{ print $1 }')"
if [ "$USE_PRIOR_EDID_SNAPSHOT" = "1" ]; then
    [ "$EDID_SOURCE_HASH" = "$PRIOR_EDID_SOURCE_HASH" ] || \
        die "EDID snapshot hash changed while reading it"
    [ -z "$PRIOR_EDID_SOURCE_INTERFACE" ] || \
        [ "$EDID_SOURCE_INTERFACE" = "$PRIOR_EDID_SOURCE_INTERFACE" ] || \
        die "EDID snapshot transport metadata changed"
fi

if [ "$EDID_SOURCE" != generated ] && \
   { [ "$EDID_SOURCE_INTERFACE" = unknown ] || \
     [ "$EDID_TARGET_INTERFACE" = unknown ] || \
     [ "$EDID_SOURCE_INTERFACE" != "$EDID_TARGET_INTERFACE" ]; }; then
    if [ "$ALLOW_EDID_TRANSPORT_MISMATCH" != "1" ]; then
        die "EDID transport is not a known match: source is $EDID_SOURCE_INTERFACE but $VIRT_OUTPUT is $EDID_TARGET_INTERFACE; use a known same-transport dump or explicitly set ALLOW_EDID_TRANSPORT_MISMATCH=1"
    fi
    echo "WARN: explicitly allowing $EDID_SOURCE_INTERFACE EDID on $EDID_TARGET_INTERFACE connector $VIRT_OUTPUT" >&2
fi

INSTALL_EXTRA_MODES=""
if [ "$USE_PRIOR_EDID_SNAPSHOT" = "1" ] && \
   { [ -e "$REGEN_DIR/extra-modes.txt" ] || [ -L "$REGEN_DIR/extra-modes.txt" ]; }; then
    safe_root_config "$REGEN_DIR/extra-modes.txt" || \
        die "unsafe learned-mode provenance: $REGEN_DIR/extra-modes.txt"
    if [ -s "$REGEN_DIR/extra-modes.txt" ]; then
        INSTALL_EXTRA_MODES="$REGEN_DIR/extra-modes.txt"
    fi
fi

render_args=("$EDID_RENDERED_CANDIDATE" --source-edid "$EDID_SOURCE_CANDIDATE")
[ "$EDID_IDENTITY" != virtualized ] || render_args+=(--virtualize-identity)
[ -z "$INSTALL_EXTRA_MODES" ] || render_args+=(--extra "$INSTALL_EXTRA_MODES" --strict-extra)
python3 "$REPO/scripts/generate_edid.py" "${render_args[@]}" || die "could not prepare selected EDID"
inspect_edid "$EDID_RENDERED_CANDIDATE" >/dev/null
if [ "$EDID_IDENTITY" = exact ] && [ -z "$INSTALL_EXTRA_MODES" ]; then
    cmp -s "$EDID_SOURCE_CANDIDATE" "$EDID_RENDERED_CANDIDATE" || \
        die "exact EDID mode did not preserve the source bytes"
fi

if command -v edid-decode >/dev/null 2>&1; then
    SOURCE_EDID_CONFORMANT=0
    edid-decode --check "$EDID_SOURCE_CANDIDATE" >/dev/null 2>&1 && \
        SOURCE_EDID_CONFORMANT=1
    if ! edid-decode --check "$EDID_RENDERED_CANDIDATE" >/dev/null 2>&1; then
        if [ "$EDID_SOURCE" = generated ] || [ "$SOURCE_EDID_CONFORMANT" = "1" ]; then
            die "selected EDID introduced an edid-decode conformity failure"
        fi
        echo "WARN: OEM/source EDID is structurally valid but fails edid-decode --check; preserving its bytes and capabilities" >&2
    fi
fi
printf '  EDID       -> source=%s identity=%s interface=%s target=%s hash=%s\n' \
    "$EDID_SOURCE" "$EDID_IDENTITY" "$EDID_SOURCE_INTERFACE" \
    "$EDID_TARGET_INTERFACE" "$EDID_SOURCE_HASH"

if [ "$PRIOR_KARGS_MANAGED" = "1" ] &&
   { [ "$PRIOR_BOOT_BACKEND" != "$BOOT_BACKEND" ] ||
     [ "$PRIOR_VIRT_OUTPUT" != "$VIRT_OUTPUT" ] ||
     [ "$PRIOR_EDID_NAME" != "$EDID_NAME" ]; }; then
    die "bootloader, connector, or EDID identity changed while kernel arguments are installer-owned; uninstall first"
fi
if [ "$PRIOR_INITRAMFS_CONFIG_MANAGED" = "1" ] &&
   { [ "$PRIOR_INITRAMFS_BACKEND" != "$INITRAMFS_BACKEND" ] ||
     [ "$PRIOR_EDID_DST" != "$EDID_DST" ]; }; then
    die "initramfs backend or EDID identity changed while its drop-in is installer-owned; uninstall first"
fi

vd_preflight_kernel_args "$BOOT_BACKEND" || die "bootloader configuration is not safe to edit"
PERSISTENT_EDID_CONFLICTS="$(persistent_edid_mapping_conflicts \
    "$BOOT_BACKEND" "$VIRT_OUTPUT" "$EDID_NAME")" || \
    die "could not inspect persistent boot arguments for EDID conflicts"
if [ -n "$PERSISTENT_EDID_CONFLICTS" ]; then
    conflict_list="$(tr '\n' ' ' <<< "$PERSISTENT_EDID_CONFLICTS")"
    conflict_list="${conflict_list% }"
    die "persistent boot configuration already maps $EDID_NAME to another connector ($conflict_list); migrate or remove that administrator setting before targeting $VIRT_OUTPUT"
fi
vd_preflight_initramfs_config "$INITRAMFS_BACKEND" "$EDID_DST" || \
    die "initramfs configuration is not safe to edit"

[ ! -L "$EDID_DST" ] || die "refusing symlinked EDID destination: $EDID_DST"
[ ! -e "$EDID_DST" ] || [ -f "$EDID_DST" ] || die "EDID destination is not a regular file: $EDID_DST"
if [ -f "$EDID_DST" ] && [ "$REPLACE_EDID" = "1" ] && \
   [ "$PRIOR_EDID_MANAGED" != "1" ]; then
    planned_backup="$REGEN_DIR/backups/$EDID_NAME.pre-vdisplay"
    if [ -e "$planned_backup" ] || [ -L "$planned_backup" ]; then
        [ "$PRIOR_EDID_BACKUP" = "$planned_backup" ] && safe_root_config "$planned_backup" || \
            die "$planned_backup exists without trusted backup provenance"
    fi
fi

EDID_CONFORMITY=""
if [ -f "$EDID_DST" ] && command -v edid-decode >/dev/null 2>&1 &&
   ! edid-decode --check "$EDID_DST" >/dev/null 2>&1; then
    EDID_CONFORMITY="existing blob fails edid-decode --check"
    echo "WARN: existing $EDID_DST fails edid-decode --check" >&2
fi

if [ "$CHECK_ONLY" = "1" ]; then
    if [ -f "$EDID_DST" ] && [ "$REPLACE_EDID" = "1" ]; then
        EDID_STATUS="present (will be replaced if selected bytes differ)"
    elif [ -f "$EDID_DST" ]; then
        EDID_STATUS="present (will be preserved)"
    else
        EDID_STATUS="missing (selected EDID will be installed)"
    fi
    [ -z "$EDID_CONFORMITY" ] || EDID_STATUS="$EDID_STATUS; $EDID_CONFORMITY"
    cat <<EOF

Preflight passed; no changes were made.
EDID: $EDID_DST — $EDID_STATUS
Source: $EDID_SOURCE ($EDID_SOURCE_INTERFACE), identity=$EDID_IDENTITY, target=$EDID_TARGET_INTERFACE
Run sudo ./install.sh to install with this selection.
EOF
    exit 0
fi

for user_path in "$INSTALL_DIR" "$STATE_DIR" "$CONF" "$USER_UNIT_DIR" "$HOST_CONF"; do
    case "$user_path" in
        "$USER_HOME"/*) ;;
        *) die "user path must stay below $USER_HOME: $user_path" ;;
    esac
done

SCRIPT_FILES=(generate_edid.py pick-mode.py vdisplay-common.sh vdisplay-up.sh \
    vdisplay-down.sh monitor-watchdog.sh)
if [ "$HAVE_PRIOR_INSTALL_STATE" = "1" ]; then
    validate_hash_manifest "$PRIOR_INSTALLED_SCRIPT_HASHES" script
    validate_hash_manifest "$PRIOR_INSTALLED_ROOT_ASSET_HASHES" root
    while read -r owned_path expected_hash extra; do
        [ -n "$owned_path" ] || continue
        verify_prior_root_asset "$owned_path"
    done <<< "$PRIOR_INSTALLED_ROOT_ASSET_HASHES"
    for file in "${SCRIPT_FILES[@]}"; do
        expected_hash="$(manifest_hash_for "$file" "$PRIOR_INSTALLED_SCRIPT_HASHES" || true)"
        verify_prior_user_asset "$INSTALL_DIR/$file" "$expected_hash" "script"
    done
    verify_prior_user_asset "$USER_UNIT_DIR/monitor-watchdog.service" \
        "$PRIOR_INSTALLED_USER_UNIT_HASH" "user unit"

    # Files about to be replaced must be listed even if an older state omitted
    # them from its manifest. This keeps a reinstall from claiming collisions.
    verify_prior_root_asset "$ROOT_LIBEXEC/generate_edid.py"
    verify_prior_root_asset "$ROOT_LIBEXEC/vdisplay-platform.sh"
    if [ "$DYNAMIC_EDID" = "1" ]; then
        verify_prior_root_asset "$REGEN_CONF"
        verify_prior_root_asset /etc/systemd/system/vdisplay-edid-regen.path
        verify_prior_root_asset /etc/systemd/system/vdisplay-edid-regen.service
        verify_prior_root_asset /usr/local/sbin/vdisplay-edid-regen.sh
    fi
fi

if [ -e "$HOST_CONF" ]; then
    [ -f "$HOST_CONF" ] && [ ! -L "$HOST_CONF" ] || die "refusing unsafe Sunshine config: $HOST_CONF"
    as_user /usr/bin/test -w "$HOST_CONF" || die "$TARGET_USER cannot update $HOST_CONF"
fi

if [ "$HAVE_PRIOR_INSTALL_STATE" != "1" ] && [ "$DYNAMIC_EDID" = "1" ]; then
    for owned_path in /etc/vdisplay-regen.conf \
        /etc/systemd/system/vdisplay-edid-regen.path \
        /etc/systemd/system/vdisplay-edid-regen.service \
        /usr/local/sbin/vdisplay-edid-regen.sh; do
        [ ! -e "$owned_path" ] && [ ! -L "$owned_path" ] || \
            die "$owned_path already exists without trusted install metadata"
    done
fi
if [ "$HAVE_PRIOR_INSTALL_STATE" != "1" ]; then
    [ ! -e "$INSTALL_STATE" ] && [ ! -L "$INSTALL_STATE" ] || \
        die "$INSTALL_STATE exists without trusted install metadata"
    for owned_path in "$ROOT_LIBEXEC/generate_edid.py" "$ROOT_LIBEXEC/vdisplay-platform.sh"; do
        [ ! -e "$owned_path" ] && [ ! -L "$owned_path" ] || \
            die "$owned_path already exists without trusted install metadata"
    done
fi

say "Installing user scripts"
ensure_user_dir "$USER_HOME/.config"
ensure_user_dir "$USER_HOME/.local"
ensure_user_dir "$INSTALL_DIR"
ensure_user_dir "$STATE_DIR"
ensure_user_dir "$USER_HOME/.config/systemd"
ensure_user_dir "$USER_UNIT_DIR"
if [ "$HAVE_PRIOR_INSTALL_STATE" != "1" ]; then
    for owned_path in "$CONF" "$USER_UNIT_DIR/monitor-watchdog.service"; do
        [ ! -e "$owned_path" ] && [ ! -L "$owned_path" ] || \
            die "$owned_path already exists; move it aside before installing"
    done
    for file in generate_edid.py pick-mode.py vdisplay-common.sh vdisplay-up.sh \
                vdisplay-down.sh monitor-watchdog.sh; do
        [ ! -e "$INSTALL_DIR/$file" ] && [ ! -L "$INSTALL_DIR/$file" ] || \
            die "$INSTALL_DIR/$file already exists; refusing to overwrite it"
    done
fi
for file in "${SCRIPT_FILES[@]}"; do
    write_user_file "$INSTALL_DIR/$file" 0755 < "$REPO/scripts/$file"
done
INSTALLED_SCRIPT_HASHES=""
for file in "${SCRIPT_FILES[@]}"; do
    file_hash="$(as_user sha256sum "$INSTALL_DIR/$file" | awk '{ print $1 }')"
    INSTALLED_SCRIPT_HASHES+="${INSTALLED_SCRIPT_HASHES:+$'\n'}$file $file_hash"
done
ensure_root_dir /usr/local/libexec 0755
ensure_root_dir "$ROOT_LIBEXEC" 0755
write_root_file "$ROOT_LIBEXEC/generate_edid.py" 0755 < "$REPO/scripts/generate_edid.py"
write_root_file "$ROOT_LIBEXEC/vdisplay-platform.sh" 0755 < "$REPO/scripts/vdisplay-platform.sh"
INSTALLED_ROOT_ASSET_HASHES="$PRIOR_INSTALLED_ROOT_ASSET_HASHES"
record_root_asset "$ROOT_LIBEXEC/generate_edid.py"
record_root_asset "$ROOT_LIBEXEC/vdisplay-platform.sh"
INSTALLED_USER_UNIT_HASH="$PRIOR_INSTALLED_USER_UNIT_HASH"

PLATFORM_HELPER="$ROOT_LIBEXEC/vdisplay-platform.sh"
PENDING_FILE=""
PENDING_LOCK=""
SUNSHINE_PATCHED="$PRIOR_SUNSHINE_PATCHED"
KARGS_MANAGED=0
KARGS_CHANGED=0
KARGS_ADDED=""
KARGS_PENDING=0
KARGS_PENDING_ARGS=""
if [ "$PRIOR_BOOT_BACKEND" = "$BOOT_BACKEND" ] &&
   [ "$PRIOR_VIRT_OUTPUT" = "$VIRT_OUTPUT" ] && [ "$PRIOR_EDID_NAME" = "$EDID_NAME" ]; then
    KARGS_MANAGED="$PRIOR_KARGS_MANAGED"
    KARGS_ADDED="$PRIOR_KARGS_ADDED"
fi
INITRAMFS_CONFIG_MANAGED=0
INITRAMFS_CONFIG_CHANGED=0
INITRAMFS_CONFIG_PENDING=0
if [ "$PRIOR_INITRAMFS_BACKEND" = "$INITRAMFS_BACKEND" ] &&
   [ "$PRIOR_EDID_DST" = "$EDID_DST" ]; then
    INITRAMFS_CONFIG_MANAGED="$PRIOR_INITRAMFS_CONFIG_MANAGED"
fi

# The selected source replaces an old EDID by default. An explicit
# REPLACE_EDID=0 retains the legacy preservation behavior.
EDID_MANAGED=0
EDID_CHANGED=0
EDID_BACKUP="$PRIOR_EDID_BACKUP"
persist_install_state() {
    write_root_config "$INSTALL_STATE" TARGET_USER USER_HOME TARGET_GROUP INSTALL_DIR STATE_DIR \
        CONF USER_UNIT_DIR HOST_CONF REGEN_DIR EDID_NAME EDID_DST EDID_MANAGED EDID_BACKUP \
        EDID_SOURCE EDID_SOURCE_REF EDID_SOURCE_HASH EDID_IDENTITY \
        EDID_SOURCE_INTERFACE EDID_TARGET_INTERFACE EDID_SOURCE_SNAPSHOT \
        ALLOW_EDID_TRANSPORT_MISMATCH \
        VIRT_OUTPUT PHYS_OUTPUT DRM_CARD BOOT_BACKEND INITRAMFS_BACKEND KARGS_MANAGED \
        KARGS_ADDED KARGS_PENDING KARGS_PENDING_ARGS INITRAMFS_CONFIG_MANAGED \
        INITRAMFS_CONFIG_PENDING PLATFORM_HELPER DYNAMIC_EDID PENDING_FILE \
        PENDING_LOCK SUNSHINE_PATCHED SUN_CAPTURE_OLD_LINES SUN_OUTPUT_OLD_LINES \
        SUN_PREP_OLD_LINES SUN_CAPTURE_INSTALLED_VALUE SUN_OUTPUT_INSTALLED_VALUE \
        SUN_PREP_INSTALLED_VALUE INSTALLED_SCRIPT_HASHES INSTALLED_ROOT_ASSET_HASHES \
        INSTALLED_USER_UNIT_HASH
}
if [ -f "$EDID_DST" ] && [ "$REPLACE_EDID" != "1" ]; then
    if [ "$PRIOR_EDID_MANAGED" = "1" ]; then
        say "Reusing installer-owned EDID"
        EDID_MANAGED=1
        if [ -z "$PRIOR_EDID_SOURCE_HASH" ]; then
            echo "  dynamic regeneration disabled: this legacy installation has no immutable source snapshot"
            DYNAMIC_EDID=0
        fi
    else
        say "Preserving existing EDID"
        echo "  $EDID_DST already exists; it will not be overwritten"
        # No immutable baseline was installed, so do not journal provenance
        # for the temporary preflight candidate as if a snapshot existed.
        EDID_SOURCE_HASH=""
        EDID_SOURCE_SNAPSHOT=""
        if [ "$DYNAMIC_EDID" = "1" ]; then
            echo "  dynamic regeneration disabled because the existing EDID is externally managed"
            DYNAMIC_EDID=0
        fi
    fi
    persist_install_state
else
    say "Snapshotting source and installing EDID"
    EDID_MANAGED=1
    ensure_root_dir /var/lib 0755
    ensure_root_dir "$REGEN_DIR" 0755
    if [ -f "$EDID_DST" ] && [ "$PRIOR_EDID_MANAGED" != "1" ]; then
        ensure_root_dir "$REGEN_DIR/backups" 0700
        EDID_BACKUP="$REGEN_DIR/backups/$EDID_NAME.pre-vdisplay"
        if [ ! -f "$EDID_BACKUP" ]; then
            write_root_file "$EDID_BACKUP" 0600 < "$EDID_DST"
        fi
    fi
    if [ "$USE_PRIOR_EDID_SNAPSHOT" != "1" ]; then
        write_root_file "$EDID_SOURCE_SNAPSHOT" 0600 < "$EDID_SOURCE_CANDIDATE"
    fi
    safe_root_config "$EDID_SOURCE_SNAPSHOT" || die "could not create safe EDID source snapshot"
    [ "$(sha256sum "$EDID_SOURCE_SNAPSHOT" | awk '{ print $1 }')" = "$EDID_SOURCE_HASH" ] || \
        die "EDID source snapshot did not preserve the validated bytes"

    # Journal the immutable source and backup/removal plan before replacing the
    # firmware file. A crash can therefore be reversed by uninstall.sh.
    persist_install_state
    write_user_file "$STATE_DIR/virtual-edid.bin" 0600 < "$EDID_RENDERED_CANDIDATE"
    ensure_root_dir /usr/lib/firmware 0755
    ensure_root_dir /usr/lib/firmware/edid 0755
    if [ ! -f "$EDID_DST" ] || ! cmp -s "$EDID_RENDERED_CANDIDATE" "$EDID_DST"; then
        write_root_file "$EDID_DST" 0644 < "$EDID_RENDERED_CANDIDATE"
        EDID_CHANGED=1
    else
        echo "  selected EDID is unchanged"
    fi
    persist_install_state
fi

say "Configuring bootloader and initramfs"
desired_edid_arg="drm.edid_firmware=${VIRT_OUTPUT}:edid/${EDID_NAME}"
desired_force_arg="video=${VIRT_OUTPUT}:e"
KARGS_PENDING_ARGS="$KARGS_ADDED"
if [ "$BOOT_BACKEND" = "grubby" ]; then
    grubby_info="$(grubby --info=ALL)"
    for kernel_arg in "$desired_edid_arg" "$desired_force_arg"; do
        if ! grep -Fqw -- "$kernel_arg" <<< "$grubby_info"; then
            case " $KARGS_PENDING_ARGS " in
                *" $kernel_arg "*) ;;
                *) KARGS_PENDING_ARGS="${KARGS_PENDING_ARGS:+$KARGS_PENDING_ARGS }$kernel_arg" ;;
            esac
        fi
    done
else
    # Marker-based removal does not use this argument list, but retaining the
    # intended values makes the recovery record self-describing.
    for kernel_arg in "$desired_edid_arg" "$desired_force_arg"; do
        case " $KARGS_PENDING_ARGS " in
            *" $kernel_arg "*) ;;
            *) KARGS_PENDING_ARGS="${KARGS_PENDING_ARGS:+$KARGS_PENDING_ARGS }$kernel_arg" ;;
        esac
    done
fi
KARGS_PENDING=1
persist_install_state
vd_install_kernel_args "$BOOT_BACKEND" "$VIRT_OUTPUT" "$EDID_NAME"
KARGS_MANAGED="$VD_KARGS_MANAGED"
KARGS_CHANGED="$VD_KARGS_CHANGED"
KARGS_ADDED="$VD_KARGS_ADDED"
if [ "$BOOT_BACKEND" = "grubby" ] && [ "$PRIOR_BOOT_BACKEND" = "$BOOT_BACKEND" ] &&
   [ "$PRIOR_VIRT_OUTPUT" = "$VIRT_OUTPUT" ] && [ "$PRIOR_EDID_NAME" = "$EDID_NAME" ] &&
   [ "$PRIOR_KARGS_MANAGED" = "1" ]; then
    KARGS_MANAGED=1
    merged_args=""
    for kernel_arg in $PRIOR_KARGS_ADDED $KARGS_ADDED; do
        case " $merged_args " in
            *" $kernel_arg "*) ;;
            *) merged_args="${merged_args:+$merged_args }$kernel_arg" ;;
        esac
    done
    KARGS_ADDED="$merged_args"
fi
KARGS_PENDING=0
KARGS_PENDING_ARGS=""
persist_install_state
INITRAMFS_CONFIG_PENDING=1
persist_install_state
vd_install_initramfs_config "$INITRAMFS_BACKEND" "$EDID_DST"
INITRAMFS_CONFIG_MANAGED="$VD_INITRAMFS_CONFIG_MANAGED"
INITRAMFS_CONFIG_CHANGED="$VD_INITRAMFS_CONFIG_CHANGED"
INITRAMFS_CONFIG_PENDING=0
persist_install_state

BOOT_CHANGED=0
[ "$KARGS_CHANGED" = "1" ] && BOOT_CHANGED=1
[ "$INITRAMFS_CONFIG_CHANGED" = "1" ] && BOOT_CHANGED=1
[ "$EDID_CHANGED" = "1" ] && BOOT_CHANGED=1

# Persist ownership before running expensive boot tooling. If that step fails,
# uninstall still has enough trusted metadata to reverse completed mutations.
persist_install_state

if [ "$BOOT_CHANGED" = "1" ]; then
    vd_rebuild_initramfs "$INITRAMFS_BACKEND"
    vd_refresh_bootloader "$BOOT_BACKEND"
else
    echo "  existing kernel arguments, EDID, and initramfs configuration retained"
fi

# Root-owned queue directory: the user may write the regular pending file but
# cannot replace it with a symlink consumed by the root service.
if [ "$DYNAMIC_EDID" = "1" ]; then
    say "Installing dynamic EDID regeneration"
    ensure_root_dir /var/lib 0755
    ensure_root_dir "$REGEN_DIR" 0755
    PENDING_FILE="$REGEN_DIR/pending-modes.txt"
    PENDING_LOCK="$REGEN_DIR/pending-modes.lock"
    [ -e "$PENDING_FILE" ] || install -m0644 -o "$TARGET_USER" -g "$TARGET_GROUP" /dev/null "$PENDING_FILE"
    [ -e "$PENDING_LOCK" ] || install -m0600 -o "$TARGET_USER" -g "$TARGET_GROUP" /dev/null "$PENDING_LOCK"
    [ -f "$PENDING_FILE" ] && [ ! -L "$PENDING_FILE" ] || die "unsafe pending-mode path"
    [ -f "$PENDING_LOCK" ] && [ ! -L "$PENDING_LOCK" ] || die "unsafe pending-mode lock"
    chown "$TARGET_USER:$TARGET_GROUP" "$PENDING_FILE" "$PENDING_LOCK"
    chmod 0644 "$PENDING_FILE"
    chmod 0600 "$PENDING_LOCK"

    write_root_config "$REGEN_CONF" TARGET_USER USER_HOME STATE_DIR REGEN_DIR PENDING_FILE \
        PENDING_LOCK PLATFORM_HELPER INITRAMFS_BACKEND EDID_DST EDID_NAME \
        EDID_SOURCE EDID_SOURCE_HASH EDID_IDENTITY EDID_SOURCE_INTERFACE \
        EDID_TARGET_INTERFACE EDID_SOURCE_SNAPSHOT
    ensure_root_dir /usr/local/sbin 0755
    write_root_file /usr/local/sbin/vdisplay-edid-regen.sh 0755 < "$REPO/scripts/edid-regen.sh"
    sed "s|@PENDING_FILE@|$PENDING_FILE|" "$REPO/systemd/system/vdisplay-edid-regen.path.in" \
        | write_root_file /etc/systemd/system/vdisplay-edid-regen.path 0644
    sed -e "s|@REGEN@|/usr/local/sbin/vdisplay-edid-regen.sh|" \
        -e "s|@PENDING_FILE@|$PENDING_FILE|" \
        "$REPO/systemd/system/vdisplay-edid-regen.service.in" \
        | write_root_file /etc/systemd/system/vdisplay-edid-regen.service 0644
    record_root_asset "$REGEN_CONF"
    record_root_asset /usr/local/sbin/vdisplay-edid-regen.sh
    record_root_asset /etc/systemd/system/vdisplay-edid-regen.path
    record_root_asset /etc/systemd/system/vdisplay-edid-regen.service
    persist_install_state
    systemctl daemon-reload
    systemctl enable --now vdisplay-edid-regen.path vdisplay-edid-regen.service
else
    if manifest_hash_for /etc/systemd/system/vdisplay-edid-regen.path \
        "$INSTALLED_ROOT_ASSET_HASHES" >/dev/null; then
        systemctl disable --now vdisplay-edid-regen.path 2>/dev/null || true
    fi
    if manifest_hash_for /etc/systemd/system/vdisplay-edid-regen.service \
        "$INSTALLED_ROOT_ASSET_HASHES" >/dev/null; then
        systemctl disable --now vdisplay-edid-regen.service 2>/dev/null || true
    fi
fi

say "Writing $CONF"
BACKEND=kscreen
SINGLE_DISPLAY=1
INHIBIT=1
{
    for config_var in VIRT_OUTPUT PHYS_OUTPUT PHYS_MODE BACKEND SINGLE_DISPLAY \
        INHIBIT STATE_DIR DYNAMIC_EDID PENDING_FILE PENDING_LOCK; do
        printf '%s=%q\n' "$config_var" "${!config_var}"
    done
} | write_user_file "$CONF" 0600

say "Installing monitor watchdog"
escaped_install_dir="${INSTALL_DIR//\\/\\\\}"
escaped_install_dir="${escaped_install_dir//&/\\&}"
escaped_install_dir="${escaped_install_dir//|/\\|}"
sed "s|@INSTALL_DIR@|$escaped_install_dir|" "$REPO/systemd/user/monitor-watchdog.service.in" \
    | write_user_file "$USER_UNIT_DIR/monitor-watchdog.service" 0644
INSTALLED_USER_UNIT_HASH="$(as_user sha256sum "$USER_UNIT_DIR/monitor-watchdog.service" | awk '{ print $1 }')"
persist_install_state
uctl daemon-reload || true
uctl enable monitor-watchdog.service || echo "  could not enable user unit now"
uctl start monitor-watchdog.service || echo "  it will start with the next graphical session"

say "Configuring Sunshine"
desired_capture=kwin
desired_output="$VIRT_OUTPUT"
desired_prep="$(python3 -c 'import json,sys; print(json.dumps([{"do":sys.argv[1],"undo":sys.argv[2]}],separators=(",",":")))' \
    "$INSTALL_DIR/vdisplay-up.sh" "$INSTALL_DIR/vdisplay-down.sh")"
if [ -f "$HOST_CONF" ]; then
    sunshine_lines() {
        local key="$1"
        as_user /usr/bin/awk -v key="$key" '
            $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { print }
        ' "$HOST_CONF"
    }
    sunshine_current_value() {
        local key="$1"
        as_user /usr/bin/awk -v key="$key" '
            $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { count++; line=$0 }
            END {
                if (count != 1) exit 1
                sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
                sub("[[:space:]]*$", "", line)
                print line
            }
        ' "$HOST_CONF"
    }
    patch_sunshine() {
        local capture_apply="$1" output_apply="$2" prep_apply="$3"
        local capture_value="$4" output_value="$5" prep_value="$6"
        as_user /bin/bash --noprofile --norc -ceu '
            file=$1; ca=$2; oa=$3; pa=$4; cv=$5; ov=$6; pv=$7
            [ -f "$file" ] && [ ! -L "$file" ] || exit 1
            dir=${file%/*}; base=${file##*/}
            umask 077
            tmp=$(/usr/bin/mktemp -- "$dir/.${base}.vdisplay.XXXXXX")
            cleanup() { /usr/bin/rm -f -- "$tmp"; }
            trap cleanup EXIT HUP INT TERM
            /usr/bin/awk -v ca="$ca" -v oa="$oa" -v pa="$pa" '\''
                ca && $0 ~ /^[[:space:]]*capture[[:space:]]*=/ { next }
                oa && $0 ~ /^[[:space:]]*output_name[[:space:]]*=/ { next }
                pa && $0 ~ /^[[:space:]]*global_prep_cmd[[:space:]]*=/ { next }
                { print }
            '\'' "$file" > "$tmp"
            [ "$ca" = 0 ] || /usr/bin/printf "capture = %s\n" "$cv" >> "$tmp"
            [ "$oa" = 0 ] || /usr/bin/printf "output_name = %s\n" "$ov" >> "$tmp"
            [ "$pa" = 0 ] || /usr/bin/printf "global_prep_cmd = %s\n" "$pv" >> "$tmp"
            /usr/bin/chmod --reference="$file" "$tmp"
            /usr/bin/mv -fT -- "$tmp" "$file"
            tmp=
            trap - EXIT HUP INT TERM
        ' _ "$HOST_CONF" "$capture_apply" "$output_apply" "$prep_apply" \
            "$capture_value" "$output_value" "$prep_value"
    }

    capture_apply=1; output_apply=1; prep_apply=1

    if [ "$PRIOR_SUNSHINE_PATCHED" = "1" ]; then
        current="$(sunshine_current_value capture || true)"
        if [ "$current" != "$SUN_CAPTURE_INSTALLED_VALUE" ]; then
            capture_apply=0
            echo "  preserving user-edited capture setting"
        fi
        current="$(sunshine_current_value output_name || true)"
        if [ "$current" != "$SUN_OUTPUT_INSTALLED_VALUE" ]; then
            output_apply=0
            echo "  preserving user-edited output_name setting"
        fi
        current="$(sunshine_current_value global_prep_cmd || true)"
        if [ "$current" != "$SUN_PREP_INSTALLED_VALUE" ]; then
            prep_apply=0
            echo "  preserving user-edited global_prep_cmd setting"
        fi
    else
        SUN_CAPTURE_OLD_LINES="$(sunshine_lines capture)"
        SUN_OUTPUT_OLD_LINES="$(sunshine_lines output_name)"
        SUN_PREP_OLD_LINES="$(sunshine_lines global_prep_cmd)"
    fi

    if [ "$capture_apply" = "1" ]; then SUN_CAPTURE_INSTALLED_VALUE="$desired_capture"; fi
    if [ "$output_apply" = "1" ]; then SUN_OUTPUT_INSTALLED_VALUE="$desired_output"; fi
    if [ "$prep_apply" = "1" ]; then SUN_PREP_INSTALLED_VALUE="$desired_prep"; fi
    SUNSHINE_PATCHED=1
    # Journal originals and intended values before the atomic user-side rename.
    persist_install_state
    patch_sunshine "$capture_apply" "$output_apply" "$prep_apply" \
        "$desired_capture" "$desired_output" "$desired_prep"
    echo "  patched; restart Sunshine to apply"
else
    echo "  $HOST_CONF not found. After Sunshine creates it, add:"
    echo "    capture = $desired_capture"
    echo "    output_name = $desired_output"
    echo "    global_prep_cmd = $desired_prep"
fi

persist_install_state

cat <<EOF

=== DONE ===
Platform: $DISTRO_FAMILY / $BOOT_BACKEND / $INITRAMFS_BACKEND
Display:  $PHYS_OUTPUT -> $VIRT_OUTPUT while streaming
EDID:     $([ "$EDID_MANAGED" = 1 ] && echo "installed from $EDID_SOURCE ($EDID_IDENTITY)" || echo preserved)
$( [ "$BOOT_CHANGED" = 1 ] && echo "Reboot required for boot/initramfs changes." || echo "No boot configuration changes were needed." )
EOF
