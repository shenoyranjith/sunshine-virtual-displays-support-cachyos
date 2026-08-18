#!/usr/bin/env bash
# Revert resources owned by install.sh without deleting pre-existing EDID,
# boot configuration, or Sunshine settings. Run as root: sudo ./uninstall.sh
set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0" >&2; exit 1; }

INSTALL_STATE=/etc/vdisplay-install.conf

safe_root_file() {
    local file="$1" owner mode permissions
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    owner="$(stat -c %u "$file" 2>/dev/null)" || return 1
    mode="$(stat -c %a "$file" 2>/dev/null)" || return 1
    [ "$owner" = "0" ] || return 1
    permissions=$((8#$mode))
    (( (permissions & 8#022) == 0 ))
}

atomic_restore_root_file() {
    local source="$1" target="$2" mode="$3" dir base tmp owner dir_mode permissions
    safe_root_file "$source" || return 1
    dir="$(dirname "$target")"; base="$(basename "$target")"
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    owner="$(stat -c %u "$dir" 2>/dev/null)" || return 1
    dir_mode="$(stat -c %a "$dir" 2>/dev/null)" || return 1
    permissions=$((8#$dir_mode))
    [ "$owner" = 0 ] && (( (permissions & 8#022) == 0 )) || return 1
    [ ! -L "$target" ] || return 1
    tmp="$(mktemp -- "$dir/.${base}.vdisplay-restore.XXXXXX")" || return 1
    if install -m"$mode" -- "$source" "$tmp" && cmp -s -- "$source" "$tmp" &&
       mv -fT -- "$tmp" "$target"; then
        tmp=""
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

if safe_root_file "$INSTALL_STATE"; then
    # The file is generated with shell-escaped assignments and is root-owned.
    # shellcheck disable=SC1090
    . "$INSTALL_STATE"
    HAVE_INSTALL_STATE=1
else
    HAVE_INSTALL_STATE=0
    TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
    [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ] || {
        echo "No trusted install state and no desktop user could be determined" >&2
        exit 1
    }
    USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    TARGET_GROUP="$(id -gn "$TARGET_USER")"
    INSTALL_DIR="$USER_HOME/.local/libexec/vdisplay"
    STATE_DIR="$USER_HOME/.local/share/vdisplay"
    CONF="$USER_HOME/.config/vdisplay.conf"
    USER_UNIT_DIR="$USER_HOME/.config/systemd/user"
    HOST_CONF="${HOST_CONF:-$USER_HOME/.config/sunshine/sunshine.conf}"
    REGEN_DIR=/var/lib/vdisplay
    EDID_NAME=virtual-display.bin
    EDID_DST="/usr/lib/firmware/edid/$EDID_NAME"
    EDID_MANAGED=0
    EDID_BACKUP=""
    EDID_SOURCE=""
    EDID_SOURCE_HASH=""
    EDID_IDENTITY=""
    EDID_SOURCE_INTERFACE=""
    EDID_TARGET_INTERFACE=""
    EDID_SOURCE_SNAPSHOT=""
    VIRT_OUTPUT=""
    BOOT_BACKEND=""
    INITRAMFS_BACKEND=""
    KARGS_MANAGED=0
    KARGS_ADDED=""
    KARGS_PENDING=0
    KARGS_PENDING_ARGS=""
    INITRAMFS_CONFIG_MANAGED=0
    INITRAMFS_CONFIG_PENDING=0
    PLATFORM_HELPER=""
    STREAM_MODE=virtual
    DYNAMIC_EDID=0
    SUNSHINE_PATCHED=0
    SUN_CAPTURE_OLD_LINES=""
    SUN_OUTPUT_OLD_LINES=""
    SUN_PREP_OLD_LINES=""
    SUN_CAPTURE_INSTALLED_VALUE=""
    SUN_OUTPUT_INSTALLED_VALUE=""
    SUN_PREP_INSTALLED_VALUE=""
    INSTALLED_SCRIPT_HASHES=""
    INSTALLED_ROOT_ASSET_HASHES=""
    INSTALLED_USER_UNIT_HASH=""
    echo "WARN: trusted $INSTALL_STATE is absent; boot files, EDID, and Sunshine config will be preserved" >&2
fi

: "${TARGET_GROUP:=$(id -gn "$TARGET_USER")}" "${KARGS_ADDED:=}"
: "${KARGS_PENDING:=0}" "${KARGS_PENDING_ARGS:=}"
: "${INITRAMFS_CONFIG_PENDING:=0}"
: "${SUNSHINE_PATCHED:=0}" "${SUN_CAPTURE_OLD_LINES:=}" "${SUN_OUTPUT_OLD_LINES:=}"
: "${SUN_PREP_OLD_LINES:=}" "${SUN_CAPTURE_INSTALLED_VALUE:=}"
: "${SUN_OUTPUT_INSTALLED_VALUE:=}" "${SUN_PREP_INSTALLED_VALUE:=}"
: "${INSTALLED_SCRIPT_HASHES:=}"
: "${INSTALLED_ROOT_ASSET_HASHES:=}" "${INSTALLED_USER_UNIT_HASH:=}"
: "${EDID_SOURCE:=}" "${EDID_SOURCE_HASH:=}" "${EDID_IDENTITY:=}"
: "${EDID_SOURCE_INTERFACE:=}" "${EDID_TARGET_INTERFACE:=}"
: "${EDID_SOURCE_SNAPSHOT:=}"
: "${STREAM_MODE:=virtual}"
[ -n "$USER_HOME" ] && [ "$USER_HOME" != "/" ] || { echo "Invalid user home" >&2; exit 1; }
[[ "$EDID_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] &&
    [ "$EDID_DST" = "/usr/lib/firmware/edid/$EDID_NAME" ] || {
        echo "Invalid EDID path in install metadata" >&2
        exit 1
    }
[ "$REGEN_DIR" = "/var/lib/vdisplay" ] || {
    echo "Invalid regeneration path in install metadata" >&2
    exit 1
}
if { [ -n "$EDID_SOURCE_HASH" ] || [ -n "$EDID_SOURCE_SNAPSHOT" ]; } && \
   [ "$EDID_SOURCE_SNAPSHOT" != "$REGEN_DIR/source-edid.bin" ]; then
    echo "Invalid EDID source snapshot path in install metadata" >&2
    exit 1
fi
for user_path in "$INSTALL_DIR" "$STATE_DIR" "$CONF" "$USER_UNIT_DIR" "$HOST_CONF"; do
    case "$user_path" in
        "$USER_HOME"/*) ;;
        *) echo "Refusing user path outside $USER_HOME: $user_path" >&2; exit 1 ;;
    esac
done

UID_N="$(id -u "$TARGET_USER")"
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
        if [ -n "$extra" ] || ! [[ "$hash" =~ ^[0-9a-f]{64}$ ]]; then
            echo "Invalid $kind hash metadata in $INSTALL_STATE" >&2
            return 1
        fi
        case "$kind" in
            root) root_asset_path_allowed "$key" || {
                echo "Invalid root asset in $INSTALL_STATE: $key" >&2
                return 1
            } ;;
            script) script_asset_name_allowed "$key" || {
                echo "Invalid script asset in $INSTALL_STATE: $key" >&2
                return 1
            } ;;
        esac
        case $'\n'"$seen"$'\n' in
            *$'\n'"$key"$'\n'*)
                echo "Duplicate $kind asset in $INSTALL_STATE: $key" >&2
                return 1
                ;;
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

validate_hash_manifest "$INSTALLED_SCRIPT_HASHES" script || exit 1
validate_hash_manifest "$INSTALLED_ROOT_ASSET_HASHES" root || exit 1
case "$KARGS_PENDING:$INITRAMFS_CONFIG_PENDING" in
    0:0|0:1|1:0|1:1) ;;
    *) echo "Invalid pending-operation metadata in $INSTALL_STATE" >&2; exit 1 ;;
esac

if [ "$HAVE_INSTALL_STATE" = "1" ] && [ -n "${PLATFORM_HELPER:-}" ]; then
    expected_platform_hash="$(manifest_hash_for "$PLATFORM_HELPER" "$INSTALLED_ROOT_ASSET_HASHES" || true)"
    [ "$PLATFORM_HELPER" = /usr/local/libexec/vdisplay/vdisplay-platform.sh ] &&
        [ -n "$expected_platform_hash" ] && safe_root_file "$PLATFORM_HELPER" &&
        [ "$(sha256sum "$PLATFORM_HELPER" | awk '{ print $1 }')" = "$expected_platform_hash" ] || {
        echo "Trusted platform helper is missing or modified; keeping install metadata for recovery" >&2
        exit 1
    }
    # shellcheck disable=SC1090
    . "$PLATFORM_HELPER"
fi

critical_status=0
EDID_SOURCE_SNAPSHOT_TRUSTED=0
if [ "$HAVE_INSTALL_STATE" = "1" ] && [ -n "$EDID_SOURCE_HASH" ]; then
    if [ -e "$EDID_SOURCE_SNAPSHOT" ] || [ -L "$EDID_SOURCE_SNAPSHOT" ]; then
        if safe_root_file "$EDID_SOURCE_SNAPSHOT" && \
           [ "$(sha256sum "$EDID_SOURCE_SNAPSHOT" 2>/dev/null | awk '{ print $1 }')" = "$EDID_SOURCE_HASH" ]; then
            EDID_SOURCE_SNAPSHOT_TRUSTED=1
        else
            echo "WARN: preserving modified EDID source snapshot: $EDID_SOURCE_SNAPSHOT" >&2
            critical_status=1
        fi
    else
        # Already absent is equivalent to a successful cleanup for uninstall.
        EDID_SOURCE_SNAPSHOT_TRUSTED=1
    fi
fi
VDISPLAY_DOWN_TRUSTED=0
if [ "$HAVE_INSTALL_STATE" = "1" ]; then
    while read -r asset_path expected_hash extra; do
        [ -n "$asset_path" ] || continue
        if [ -e "$asset_path" ] || [ -L "$asset_path" ]; then
            if ! safe_root_file "$asset_path" ||
               [ "$(sha256sum "$asset_path" 2>/dev/null | awk '{ print $1 }')" != "$expected_hash" ]; then
                echo "WARN: preserving modified installed root asset: $asset_path" >&2
                critical_status=1
            fi
        fi
    done <<< "$INSTALLED_ROOT_ASSET_HASHES"

    for script_name in generate_edid.py pick-mode.py vdisplay-common.sh vdisplay-up.sh \
                       vdisplay-down.sh monitor-watchdog.sh; do
        expected_hash="$(manifest_hash_for "$script_name" "$INSTALLED_SCRIPT_HASHES" || true)"
        script_path="$INSTALL_DIR/$script_name"
        if [ -e "$script_path" ] || [ -L "$script_path" ]; then
            actual_hash="$(as_user sha256sum "$script_path" 2>/dev/null | awk '{ print $1 }')"
            if [ -z "$expected_hash" ] || [ ! -f "$script_path" ] || [ -L "$script_path" ] ||
               [ "$actual_hash" != "$expected_hash" ]; then
                echo "WARN: preserving user-modified installed script: $script_path" >&2
                critical_status=1
            elif [ "$script_name" = "vdisplay-down.sh" ]; then
                VDISPLAY_DOWN_TRUSTED=1
            fi
        fi
    done

    user_unit="$USER_UNIT_DIR/monitor-watchdog.service"
    if [ -e "$user_unit" ] || [ -L "$user_unit" ]; then
        actual_hash="$(as_user sha256sum "$user_unit" 2>/dev/null | awk '{ print $1 }')"
        if [ -z "$INSTALLED_USER_UNIT_HASH" ] || [ ! -f "$user_unit" ] || [ -L "$user_unit" ] ||
           [ "$actual_hash" != "$INSTALLED_USER_UNIT_HASH" ]; then
            echo "WARN: preserving user-modified installed unit: $user_unit" >&2
            critical_status=1
        fi
    fi
fi

say "Restoring the desktop layout"
if [ "$VDISPLAY_DOWN_TRUSTED" = "1" ] && [ -x "$INSTALL_DIR/vdisplay-down.sh" ]; then
    as_user env XDG_RUNTIME_DIR="/run/user/$UID_N" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" \
        "$INSTALL_DIR/vdisplay-down.sh" || echo "WARN: desktop restore will be retried by the watchdog" >&2
fi
if [ "$HAVE_INSTALL_STATE" = "1" ]; then
    uctl stop vdisplay-inhibit.service 2>/dev/null || true
fi

say "Removing user service"
if [ "$HAVE_INSTALL_STATE" = "1" ] && [ -n "$INSTALLED_USER_UNIT_HASH" ]; then
    uctl disable --now monitor-watchdog.service 2>/dev/null || true
fi

say "Removing EDID regeneration service"
if manifest_hash_for /etc/systemd/system/vdisplay-edid-regen.path \
    "$INSTALLED_ROOT_ASSET_HASHES" >/dev/null; then
    systemctl disable --now vdisplay-edid-regen.path 2>/dev/null || true
fi
if manifest_hash_for /etc/systemd/system/vdisplay-edid-regen.service \
    "$INSTALLED_ROOT_ASSET_HASHES" >/dev/null; then
    systemctl disable --now vdisplay-edid-regen.service 2>/dev/null || true
fi

BOOT_REFRESH_NEEDED=0
DELETE_EDID_BACKUP=0
if [ "$HAVE_INSTALL_STATE" = "1" ]; then
    say "Removing managed boot configuration"
    if [ "${INITRAMFS_CONFIG_MANAGED:-0}" = "1" ]; then
        BOOT_REFRESH_NEEDED=1
        if ! vd_remove_initramfs_config "$INITRAMFS_BACKEND" 1; then
            critical_status=1
        fi
        [ "${VD_INITRAMFS_CONFIG_CHANGED:-0}" = "1" ] && BOOT_REFRESH_NEEDED=1
    elif [ "$INITRAMFS_CONFIG_PENDING" = "1" ]; then
        BOOT_REFRESH_NEEDED=1
        pending_init_target=""
        case "$INITRAMFS_BACKEND" in
            limine|mkinitcpio) pending_init_target="$VD_MKINITCPIO_DROPIN" ;;
            dracut) pending_init_target="$VD_DRACUT_DROPIN" ;;
            update-initramfs) ;;
            *) echo "WARN: invalid pending initramfs backend: $INITRAMFS_BACKEND" >&2; critical_status=1 ;;
        esac
        # A pending journal may precede the actual write. Only a marked
        # fragment can have been created by the interrupted installer.
        if [ -n "$pending_init_target" ] && [ -f "$pending_init_target" ] &&
           [ ! -L "$pending_init_target" ] &&
           grep -Fxq "$VD_FRAGMENT_MARKER" "$pending_init_target"; then
            if ! vd_remove_initramfs_config "$INITRAMFS_BACKEND" 1; then
                critical_status=1
            fi
            [ "${VD_INITRAMFS_CONFIG_CHANGED:-0}" = "1" ] && BOOT_REFRESH_NEEDED=1
        fi
    fi
    if [ "${KARGS_MANAGED:-0}" = "1" ] || [ "$KARGS_PENDING" = "1" ]; then
        BOOT_REFRESH_NEEDED=1
        removal_args=""
        for kernel_arg in $KARGS_ADDED $KARGS_PENDING_ARGS; do
            case " $removal_args " in
                *" $kernel_arg "*) ;;
                *) removal_args="${removal_args:+$removal_args }$kernel_arg" ;;
            esac
        done
        if ! vd_remove_kernel_args "$BOOT_BACKEND" "$VIRT_OUTPUT" "$EDID_NAME" 1 "$removal_args"; then
            critical_status=1
        fi
        [ "${VD_KARGS_CHANGED:-0}" = "1" ] && BOOT_REFRESH_NEEDED=1
    fi

    EDID_COMMIT_OK=1
    if [ "${EDID_MANAGED:-0}" = "1" ]; then
        BOOT_REFRESH_NEEDED=1
        if [ -L "$EDID_DST" ]; then
            echo "WARN: refusing symlinked EDID destination: $EDID_DST" >&2
            critical_status=1
            EDID_COMMIT_OK=0
        elif [ -n "${EDID_BACKUP:-}" ]; then
            if atomic_restore_root_file "$EDID_BACKUP" "$EDID_DST" 0644; then
                DELETE_EDID_BACKUP=1
                echo "  restored the pre-install EDID"
            else
                echo "WARN: could not restore the EDID backup; it was retained" >&2
                critical_status=1
                EDID_COMMIT_OK=0
            fi
        elif rm -f -- "$EDID_DST"; then
            echo "  removed the installer-owned EDID"
        else
            echo "WARN: could not remove $EDID_DST" >&2
            critical_status=1
            EDID_COMMIT_OK=0
        fi
    else
        echo "  preserving pre-existing EDID and kernel arguments"
    fi

    if [ "$BOOT_REFRESH_NEEDED" = "1" ] && [ "$EDID_COMMIT_OK" = "1" ]; then
        vd_rebuild_initramfs "$INITRAMFS_BACKEND" || {
            echo "WARN: initramfs rebuild failed" >&2
            critical_status=1
        }
        vd_refresh_bootloader "$BOOT_BACKEND" || {
            echo "WARN: bootloader refresh failed" >&2
            critical_status=1
        }
    fi
fi

say "Restoring Sunshine configuration"
if [ "$SUNSHINE_PATCHED" = "1" ] && [ -e "$HOST_CONF" ]; then
    as_user /bin/bash --noprofile --norc -ceu '
        file=$1
        capture_installed=$2; capture_old=$3
        output_installed=$4; output_old=$5
        prep_installed=$6; prep_old=$7
        up_path=$8; down_path=$9
        [ -f "$file" ] && [ ! -L "$file" ] || {
            echo "WARN: refusing unsafe Sunshine config: $file" >&2
            exit 1
        }
        current_value() {
            /usr/bin/awk -v key="$1" '\''
                $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { count++; line=$0 }
                END {
                    if (count != 1) exit 1
                    sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
                    sub("[[:space:]]*$", "", line)
                    print line
                }
            '\'' "$file"
        }
        json_equal() {
            python3 -c '\''import json,sys; raise SystemExit(0 if json.loads(sys.argv[1]) == json.loads(sys.argv[2]) else 1)'\'' \
                "$1" "$2" 2>/dev/null
        }
        json_has_hook() {
            python3 -c '\''
import json, sys
try:
    value = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
found = isinstance(value, list) and any(
    isinstance(item, dict) and item.get("do") == sys.argv[2] and item.get("undo") == sys.argv[3]
    for item in value
)
raise SystemExit(0 if found else 1)
'\'' "$1" "$up_path" "$down_path" 2>/dev/null
        }
        ca=0; oa=0; pa=0; prep_conflict=0
        current=$(current_value capture || true)
        if [ "$current" = "$capture_installed" ] && [ -n "$capture_installed" ]; then
            ca=1
        else
            echo "  preserving changed capture setting" >&2
        fi
        current=$(current_value output_name || true)
        if [ "$current" = "$output_installed" ] && [ -n "$output_installed" ]; then
            oa=1
        else
            echo "  preserving changed output_name setting" >&2
        fi
        current=$(current_value global_prep_cmd || true)
        if [ -n "$prep_installed" ] &&
           { [ "$current" = "$prep_installed" ] || json_equal "$current" "$prep_installed"; }; then
            pa=1
        else
            echo "  preserving changed global_prep_cmd setting" >&2
            if json_has_hook "$current"; then
                prep_conflict=1
            else
                case "$current" in
                    *"$up_path"*|*"$down_path"*) prep_conflict=1 ;;
                esac
            fi
        fi

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
        [ "$ca" = 0 ] || [ -z "$capture_old" ] || /usr/bin/printf "%s\n" "$capture_old" >> "$tmp"
        [ "$oa" = 0 ] || [ -z "$output_old" ] || /usr/bin/printf "%s\n" "$output_old" >> "$tmp"
        [ "$pa" = 0 ] || [ -z "$prep_old" ] || /usr/bin/printf "%s\n" "$prep_old" >> "$tmp"
        /usr/bin/chmod --reference="$file" "$tmp"
        /usr/bin/mv -fT -- "$tmp" "$file"
        tmp=
        trap - EXIT HUP INT TERM
        if [ "$prep_conflict" = 1 ]; then
            echo "WARN: changed global_prep_cmd still references vdisplay scripts" >&2
            exit 3
        fi
    ' _ "$HOST_CONF" "$SUN_CAPTURE_INSTALLED_VALUE" "$SUN_CAPTURE_OLD_LINES" \
        "$SUN_OUTPUT_INSTALLED_VALUE" "$SUN_OUTPUT_OLD_LINES" \
        "$SUN_PREP_INSTALLED_VALUE" "$SUN_PREP_OLD_LINES" \
        "$INSTALL_DIR/vdisplay-up.sh" "$INSTALL_DIR/vdisplay-down.sh"
    sunshine_status=$?
    if [ "$sunshine_status" -ne 0 ]; then
        echo "WARN: Sunshine configuration could not be restored; install metadata was retained" >&2
        critical_status=1
    fi
elif [ "$SUNSHINE_PATCHED" = "1" ]; then
    echo "  Sunshine config is absent; nothing to restore"
else
    echo "  no installer-owned Sunshine keys recorded; preserving the file"
fi

if [ "$HAVE_INSTALL_STATE" != "1" ]; then
    cat >&2 <<EOF

=== UNINSTALL INCOMPLETE ===
No trusted install metadata was found, so no project-named files were removed.
Restore $INSTALL_STATE from backup or remove the installation manually.
EOF
    exit 1
fi

if [ "$critical_status" -ne 0 ]; then
    cat >&2 <<EOF

=== UNINSTALL INCOMPLETE ===
Recovery metadata and installed scripts were retained. Fix the warnings above,
then run sudo ./uninstall.sh again.
EOF
    exit 1
fi

cleanup_status=0
say "Removing installed scripts and state"
if [ -n "$INSTALLED_USER_UNIT_HASH" ]; then
    as_user rm -f -- "$USER_UNIT_DIR/monitor-watchdog.service" || cleanup_status=1
    uctl daemon-reload 2>/dev/null || true
fi
while read -r script_name expected_hash extra; do
    [ -n "$script_name" ] || continue
    as_user rm -f -- "$INSTALL_DIR/$script_name" || cleanup_status=1
done <<< "$INSTALLED_SCRIPT_HASHES"
as_user rm -f -- \
    "$CONF" "$STATE_DIR/requests.log" "$STATE_DIR/pending-modes.txt" \
    "$STATE_DIR/extra-modes.txt" "$STATE_DIR/virtual-edid.bin" \
    "$STATE_DIR/regen.log" "$STATE_DIR/reboot-needed" || cleanup_status=1
as_user rmdir -- "$INSTALL_DIR" 2>/dev/null || true
as_user rmdir -- "$STATE_DIR" 2>/dev/null || true
rm -f -- "/run/user/$UID_N/vdisplay.flag" || cleanup_status=1

system_units_removed=0
while read -r asset_path expected_hash extra; do
    [ -n "$asset_path" ] || continue
    [ "$asset_path" != "$PLATFORM_HELPER" ] || continue
    case "$asset_path" in
        /etc/systemd/system/vdisplay-edid-regen.path|\
        /etc/systemd/system/vdisplay-edid-regen.service) system_units_removed=1 ;;
    esac
    rm -f -- "$asset_path" || cleanup_status=1
done <<< "$INSTALLED_ROOT_ASSET_HASHES"
if [ "$system_units_removed" = "1" ]; then
    systemctl daemon-reload 2>/dev/null || \
        echo "WARN: systemd manager could not be reloaded" >&2
fi

rm -f -- "$REGEN_DIR/pending-modes.txt" "$REGEN_DIR/pending-modes.lock" \
      "$REGEN_DIR/extra-modes.txt" "$REGEN_DIR/virtual-edid.bin" \
      "$REGEN_DIR/regen.log" "$REGEN_DIR/reboot-needed" \
      "$REGEN_DIR/processing-modes.txt" || cleanup_status=1
rmdir -- "$REGEN_DIR/backups" 2>/dev/null || true
rmdir -- "$REGEN_DIR" 2>/dev/null || true

if [ "$cleanup_status" -ne 0 ]; then
    echo "WARN: some installed files could not be removed; install metadata was retained" >&2
    exit 1
fi

rm -f -- "$INSTALL_STATE" || {
    echo "WARN: could not remove $INSTALL_STATE" >&2
    exit 1
}
[ ! -e "$INSTALL_STATE" ] && [ ! -L "$INSTALL_STATE" ] || {
    echo "WARN: $INSTALL_STATE still exists" >&2
    exit 1
}

# Recovery artifacts remain available until the state unlink has committed.
if [ "$EDID_SOURCE_SNAPSHOT_TRUSTED" = "1" ] && [ -n "$EDID_SOURCE_SNAPSHOT" ]; then
    rm -f -- "$EDID_SOURCE_SNAPSHOT" || \
        echo "WARN: stale EDID source snapshot remains at $EDID_SOURCE_SNAPSHOT" >&2
fi
if [ "$DELETE_EDID_BACKUP" = "1" ]; then
    rm -f -- "$EDID_BACKUP" || echo "WARN: stale EDID backup remains at $EDID_BACKUP" >&2
fi
if manifest_hash_for "$PLATFORM_HELPER" "$INSTALLED_ROOT_ASSET_HASHES" >/dev/null; then
    rm -f -- "$PLATFORM_HELPER" || echo "WARN: root platform helper remains at $PLATFORM_HELPER" >&2
fi
rmdir -- /usr/local/libexec/vdisplay 2>/dev/null || true
rmdir -- "$REGEN_DIR/backups" 2>/dev/null || true
rmdir -- "$REGEN_DIR" 2>/dev/null || true

cat <<EOF

=== UNINSTALL DONE ===
$([ "$BOOT_REFRESH_NEEDED" = 1 ] && echo "Reboot recommended because managed boot configuration changed." || echo "Pre-existing boot configuration and EDID were left untouched.")
EOF
