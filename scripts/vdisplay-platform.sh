#!/usr/bin/env bash
# Platform-specific bootloader and initramfs helpers.
#
# This file is sourced by install.sh, uninstall.sh, and the root EDID regeneration
# service. Paths and command names are overrideable so the behavior can be tested
# without touching the running system.

: "${VD_OS_RELEASE:=/etc/os-release}"
: "${VD_LIMINE_DEFAULT:=/etc/default/limine}"
: "${VD_LIMINE_DROPIN:=/etc/limine-entry-tool.d/90-vdisplay.conf}"
: "${VD_GRUB_DEFAULT:=/etc/default/grub}"
: "${VD_GRUB_OUTPUT:=/boot/grub/grub.cfg}"
: "${VD_MKINITCPIO_CONF:=/etc/mkinitcpio.conf}"
: "${VD_MKINITCPIO_DROPIN:=/etc/mkinitcpio.conf.d/90-vdisplay.conf}"
: "${VD_DRACUT_CONF:=/etc/dracut.conf}"
: "${VD_DRACUT_DROPIN:=/etc/dracut.conf.d/90-vdisplay.conf}"
: "${VD_LIMINE_CMD:=limine-mkinitcpio}"
: "${VD_MKINITCPIO_CMD:=/usr/bin/mkinitcpio}"
: "${VD_DRACUT_CMD:=dracut}"
: "${VD_UPDATE_INITRAMFS_CMD:=update-initramfs}"

VD_LIMINE_BEGIN="# BEGIN vdisplay kernel arguments"
VD_LIMINE_END="# END vdisplay kernel arguments"
VD_GRUB_BEGIN="# BEGIN vdisplay kernel arguments"
VD_GRUB_END="# END vdisplay kernel arguments"
VD_FRAGMENT_MARKER="# Managed by sunshine-virtual-displays-support."

vd_platform_log() { printf '%s\n' "$*"; }
vd_platform_warn() { printf 'WARN: %s\n' "$*" >&2; }

vd_detect_distro_family() {
    local id="" id_like=""
    if [ -r "$VD_OS_RELEASE" ]; then
        id="$(sed -n 's/^ID=//p' "$VD_OS_RELEASE" | tr -d '"' | head -n1)"
        id_like="$(sed -n 's/^ID_LIKE=//p' "$VD_OS_RELEASE" | tr -d '"' | head -n1)"
    fi
    case " $id $id_like " in
        *" cachyos "*|*" arch "*) printf 'arch\n' ;;
        *" fedora "*|*" rhel "*) printf 'fedora\n' ;;
        *" debian "*|*" ubuntu "*) printf 'debian\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

# Print one of: limine, grubby, grub. An explicit non-auto argument wins.
vd_detect_boot_backend() {
    local requested="${1:-auto}" distro_family
    case "$requested" in
        limine|grubby|grub) printf '%s\n' "$requested"; return 0 ;;
        auto|'') ;;
        *) vd_platform_warn "unsupported BOOT_BACKEND=$requested"; return 1 ;;
    esac

    distro_family="$(vd_detect_distro_family)"
    if [ "$distro_family" = "arch" ] && [ -f "$VD_LIMINE_DEFAULT" ] &&
       command -v "$VD_LIMINE_CMD" >/dev/null 2>&1; then
        printf 'limine\n'
    elif [ "$distro_family" = "fedora" ] && command -v grubby >/dev/null 2>&1; then
        printf 'grubby\n'
    elif [ -f "$VD_LIMINE_DEFAULT" ] && command -v "$VD_LIMINE_CMD" >/dev/null 2>&1; then
        printf 'limine\n'
    elif command -v grubby >/dev/null 2>&1; then
        printf 'grubby\n'
    elif [ -f "$VD_GRUB_DEFAULT" ] &&
         { command -v update-grub >/dev/null 2>&1 || command -v grub-mkconfig >/dev/null 2>&1; }; then
        printf 'grub\n'
    else
        vd_platform_warn "no supported bootloader detected (Limine, grubby, or GRUB)"
        return 1
    fi
}

# Print one of: limine, mkinitcpio, dracut, update-initramfs.
vd_detect_initramfs_backend() {
    local boot_backend="$1" requested="${2:-auto}" distro_family
    case "$requested" in
        limine|mkinitcpio|dracut|update-initramfs) printf '%s\n' "$requested"; return 0 ;;
        auto|'') ;;
        *) vd_platform_warn "unsupported INITRAMFS_BACKEND=$requested"; return 1 ;;
    esac

    distro_family="$(vd_detect_distro_family)"
    if [ "$boot_backend" = "limine" ] && command -v "$VD_LIMINE_CMD" >/dev/null 2>&1; then
        printf 'limine\n'
    elif [ "$distro_family" = "arch" ] &&
         { [ -x "$VD_MKINITCPIO_CMD" ] || command -v mkinitcpio >/dev/null 2>&1; }; then
        printf 'mkinitcpio\n'
    elif command -v "$VD_DRACUT_CMD" >/dev/null 2>&1; then
        printf 'dracut\n'
    elif [ -x "$VD_MKINITCPIO_CMD" ] || command -v mkinitcpio >/dev/null 2>&1; then
        printf 'mkinitcpio\n'
    elif [ "$distro_family" = "debian" ] && command -v "$VD_UPDATE_INITRAMFS_CMD" >/dev/null 2>&1; then
        printf 'update-initramfs\n'
    else
        vd_platform_warn "no supported initramfs generator detected"
        return 1
    fi
}

vd_remove_marked_block() {
    local file="$1" begin="$2" end="$3" status dir base tmp
    [ -f "$file" ] || return 0
    [ ! -L "$file" ] || {
        vd_platform_warn "refusing to edit symlinked configuration: $file"
        return 1
    }
    if vd_marked_block_status "$file" "$begin" "$end"; then
        status=0
    else
        status=$?
    fi
    [ "$status" = "1" ] && return 0
    [ "$status" = "0" ] || {
        vd_platform_warn "malformed managed block in $file; refusing to edit"
        return 1
    }
    dir="$(dirname "$file")"; base="$(basename "$file")"
    tmp="$(mktemp -- "$dir/.${base}.vdisplay.XXXXXX")" || return 1
    if ! awk -v begin="$begin" -v end="$end" '
        $0 == begin { managed=1; next }
        $0 == end { managed=0; next }
        !managed { print }
    ' "$file" > "$tmp" ||
       ! chmod --reference="$file" "$tmp" ||
       ! mv -fT -- "$tmp" "$file"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# 0 = exactly one ordered pair, 1 = no markers, 2 = malformed markers.
vd_marked_block_status() {
    local file="$1" begin="$2" end="$3"
    awk -v begin="$begin" -v end="$end" '
        $0 == begin {
            begins++
            if (open) bad=1
            open=1
        }
        $0 == end {
            ends++
            if (!open) bad=1
            open=0
        }
        END {
            if (begins == 0 && ends == 0) exit 1
            if (begins == 1 && ends == 1 && !open && !bad) exit 0
            exit 2
        }
    ' "$file"
}

vd_append_marked_block() {
    local file="$1" begin="$2" end="$3" assignment="$4"
    local dir base tmp
    [ -f "$file" ] && [ ! -L "$file" ] || {
        vd_platform_warn "refusing to edit unsafe configuration: $file"
        return 1
    }
    dir="$(dirname "$file")"; base="$(basename "$file")"
    tmp="$(mktemp -- "$dir/.${base}.vdisplay.XXXXXX")" || return 1
    if ! cat "$file" > "$tmp" ||
       ! printf '\n%s\n%s\n%s\n' "$begin" "$assignment" "$end" >> "$tmp" ||
       ! chmod --reference="$file" "$tmp" ||
       ! mv -fT -- "$tmp" "$file"; then
        rm -f -- "$tmp"
        return 1
    fi
}

vd_write_fragment() {
    local file="$1" mode="$2" assignment="$3"
    local dir base tmp
    [ ! -L "$file" ] || {
        vd_platform_warn "refusing to replace symlinked fragment: $file"
        return 1
    }
    dir="$(dirname "$file")"; base="$(basename "$file")"
    if [ ! -d "$dir" ]; then
        install -d -m0755 "$dir" || return 1
    fi
    [ -d "$dir" ] && [ ! -L "$dir" ] || {
        vd_platform_warn "unsafe fragment directory: $dir"
        return 1
    }
    tmp="$(mktemp -- "$dir/.${base}.vdisplay.XXXXXX")" || return 1
    if ! printf '%s\n%s\n' "$VD_FRAGMENT_MARKER" "$assignment" > "$tmp" ||
       ! chmod "$mode" "$tmp" ||
       ! mv -fT -- "$tmp" "$file"; then
        rm -f -- "$tmp"
        return 1
    fi
}

# Limine ignores inherited cmdlines once KERNEL_CMDLINE is configured. Ignore
# our own block and require at least one non-empty administrator/base assignment.
vd_limine_has_persistent_base() {
    local file="$1"
    awk -v begin="$VD_LIMINE_BEGIN" -v end="$VD_LIMINE_END" '
        $0 == begin { managed=1; next }
        $0 == end { managed=0; next }
        managed || /^[[:space:]]*#/ { next }
        /^[[:space:]]*KERNEL_CMDLINE(\[default\])?[[:space:]]*\+?=/ {
            value=$0
            sub(/^[^=]*=/, "", value)
            gsub(/[[:space:]"\047]/, "", value)
            if (length(value) > 0) found=1
        }
        END { exit !found }
    ' "$file"
}

vd_file_has_token() {
    local token="$1" file
    shift
    for file in "$@"; do
        [ -f "$file" ] || continue
        awk -v token="$token" '
            /^[[:space:]]*#/ { next }
            {
                rest=$0
                while ((pos=index(rest, token)) != 0) {
                    before=(pos == 1 ? "=" : substr(rest, pos - 1, 1))
                    after=substr(rest, pos + length(token), 1)
                    if (before !~ /[[:alnum:]_.:\/@-]/ &&
                        (after == "" || after !~ /[[:alnum:]_.:\/@-]/)) {
                        found=1
                        break
                    }
                    rest=substr(rest, pos + length(token))
                }
            }
            END { exit !found }
        ' "$file" && return 0
    done
    return 1
}

vd_limine_config_files() {
    local file dir
    dir="$(dirname "$VD_LIMINE_DROPIN")"
    printf '%s\n' "$VD_LIMINE_DEFAULT"
    if [ -d "$dir" ]; then
        for file in "$dir"/*.conf; do
            [ -f "$file" ] && printf '%s\n' "$file"
        done
    fi
}

vd_grub_config_files() {
    printf '%s\n' "$VD_GRUB_DEFAULT"
}

vd_preflight_kernel_args() {
    local backend="$1" status
    case "$backend" in
        limine)
            [ -f "$VD_LIMINE_DEFAULT" ] && [ ! -L "$VD_LIMINE_DEFAULT" ] || {
                vd_platform_warn "unsafe or missing Limine configuration: $VD_LIMINE_DEFAULT"
                return 1
            }
            if vd_marked_block_status "$VD_LIMINE_DEFAULT" "$VD_LIMINE_BEGIN" "$VD_LIMINE_END"; then
                status=0
            else
                status=$?
            fi
            [ "$status" != "2" ] || {
                vd_platform_warn "malformed managed block in $VD_LIMINE_DEFAULT"
                return 1
            }
            vd_limine_has_persistent_base "$VD_LIMINE_DEFAULT" || {
                vd_platform_warn "$VD_LIMINE_DEFAULT has no non-empty persistent KERNEL_CMDLINE base"
                return 1
            }
            ;;
        grub)
            [ -f "$VD_GRUB_DEFAULT" ] && [ ! -L "$VD_GRUB_DEFAULT" ] || return 1
            if vd_marked_block_status "$VD_GRUB_DEFAULT" "$VD_GRUB_BEGIN" "$VD_GRUB_END"; then
                status=0
            else
                status=$?
            fi
            [ "$status" != "2" ] || {
                vd_platform_warn "malformed managed block in $VD_GRUB_DEFAULT"
                return 1
            }
            ;;
        grubby) command -v grubby >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

vd_preflight_initramfs_config() {
    local backend="$1" edid_path="$2" target=""
    local -a files=()
    case "$backend" in
        limine|mkinitcpio)
            target="$VD_MKINITCPIO_DROPIN"
            mapfile -t files < <(vd_mkinitcpio_config_files)
            ;;
        dracut)
            target="$VD_DRACUT_DROPIN"
            mapfile -t files < <(vd_dracut_config_files)
            ;;
        update-initramfs) return 0 ;;
        *) return 1 ;;
    esac
    [ ! -L "$target" ] || {
        vd_platform_warn "unsafe initramfs drop-in: $target"
        return 1
    }
    [ ! -e "$target" ] || [ -f "$target" ] || return 1
    vd_file_has_token "$edid_path" "${files[@]}" && return 0
    if [ -e "$target" ] && ! grep -Fxq "$VD_FRAGMENT_MARKER" "$target"; then
        vd_platform_warn "administrator-owned drop-in conflicts with $target"
        return 1
    fi
    return 0
}

# Installs only arguments that were not already configured. Ownership and
# mutation are deliberately separate: a rerun owns the existing marked block,
# but does not report a boot change or rewrite the file.
vd_install_kernel_args() {
    local backend="$1" connector="$2" edid_name="$3"
    local edid_arg="drm.edid_firmware=${connector}:edid/${edid_name}"
    local force_arg="video=${connector}:e"
    local -a files=() missing=()
    local joined info legacy_managed=0 marker_status=1 assignment

    VD_KARGS_MANAGED=0
    VD_KARGS_CHANGED=0
    VD_KARGS_ADDED=""
    case "$backend" in
        limine)
            [ -f "$VD_LIMINE_DEFAULT" ] && [ ! -L "$VD_LIMINE_DEFAULT" ] || {
                vd_platform_warn "unsafe or missing Limine configuration: $VD_LIMINE_DEFAULT"
                return 1
            }
            if vd_marked_block_status "$VD_LIMINE_DEFAULT" "$VD_LIMINE_BEGIN" "$VD_LIMINE_END"; then
                marker_status=0
            else
                marker_status=$?
            fi
            [ "$marker_status" != "2" ] || {
                vd_platform_warn "malformed managed block in $VD_LIMINE_DEFAULT"
                return 1
            }
            vd_limine_has_persistent_base "$VD_LIMINE_DEFAULT" || {
                vd_platform_warn "$VD_LIMINE_DEFAULT has no non-empty persistent KERNEL_CMDLINE base; refusing unsafe Limine edit"
                return 1
            }

            # Reuse an identical block byte-for-byte on reinstall.
            if [ "$marker_status" = "0" ] &&
               vd_file_has_token "$edid_arg" "$VD_LIMINE_DEFAULT" &&
               vd_file_has_token "$force_arg" "$VD_LIMINE_DEFAULT"; then
                VD_KARGS_MANAGED=1
                VD_KARGS_ADDED="$edid_arg $force_arg"
                return 0
            fi

            # Remove only our own older fragments. Never unlink an
            # administrator-owned file that happens to use our filename.
            if [ -f "$VD_LIMINE_DROPIN" ] && [ ! -L "$VD_LIMINE_DROPIN" ] &&
               grep -Fxq "$VD_FRAGMENT_MARKER" "$VD_LIMINE_DROPIN"; then
                legacy_managed=1
            fi

            [ "$marker_status" != "0" ] || {
                vd_remove_marked_block "$VD_LIMINE_DEFAULT" "$VD_LIMINE_BEGIN" "$VD_LIMINE_END" || return 1
                VD_KARGS_CHANGED=1
            }

            files=("$VD_LIMINE_DEFAULT")
            vd_file_has_token "$edid_arg" "${files[@]}" || missing+=("$edid_arg")
            vd_file_has_token "$force_arg" "${files[@]}" || missing+=("$force_arg")
            if [ "${#missing[@]}" -eq 0 ]; then
                [ "$legacy_managed" = "0" ] || {
                    rm -f "$VD_LIMINE_DROPIN" || return 1
                    VD_KARGS_CHANGED=1
                }
                return 0
            fi
            joined="${missing[*]}"

            assignment="KERNEL_CMDLINE[default]+=\" $joined \""
            vd_append_marked_block "$VD_LIMINE_DEFAULT" "$VD_LIMINE_BEGIN" \
                "$VD_LIMINE_END" "$assignment" || return 1
            if [ "$legacy_managed" = "1" ]; then
                rm -f "$VD_LIMINE_DROPIN" || return 1
            fi
            VD_KARGS_MANAGED=1
            VD_KARGS_CHANGED=1
            VD_KARGS_ADDED="$joined"
            ;;
        grubby)
            info="$(grubby --info=ALL)" || return 1
            grep -Fqw -- "$edid_arg" <<< "$info" || missing+=("$edid_arg")
            grep -Fqw -- "$force_arg" <<< "$info" || missing+=("$force_arg")
            [ "${#missing[@]}" -gt 0 ] || return 0
            joined="${missing[*]}"
            grubby --update-kernel=ALL --args="$joined" || return 1
            VD_KARGS_MANAGED=1
            VD_KARGS_CHANGED=1
            VD_KARGS_ADDED="$joined"
            ;;
        grub)
            [ -f "$VD_GRUB_DEFAULT" ] && [ ! -L "$VD_GRUB_DEFAULT" ] || {
                vd_platform_warn "unsafe or missing GRUB configuration: $VD_GRUB_DEFAULT"
                return 1
            }
            if vd_marked_block_status "$VD_GRUB_DEFAULT" "$VD_GRUB_BEGIN" "$VD_GRUB_END"; then
                marker_status=0
            else
                marker_status=$?
            fi
            [ "$marker_status" != "2" ] || {
                vd_platform_warn "malformed managed block in $VD_GRUB_DEFAULT"
                return 1
            }
            if [ "$marker_status" = "0" ] &&
               vd_file_has_token "$edid_arg" "$VD_GRUB_DEFAULT" &&
               vd_file_has_token "$force_arg" "$VD_GRUB_DEFAULT"; then
                VD_KARGS_MANAGED=1
                VD_KARGS_ADDED="$edid_arg $force_arg"
                return 0
            fi
            [ "$marker_status" != "0" ] || {
                vd_remove_marked_block "$VD_GRUB_DEFAULT" "$VD_GRUB_BEGIN" "$VD_GRUB_END" || return 1
                VD_KARGS_CHANGED=1
            }
            mapfile -t files < <(vd_grub_config_files)
            vd_file_has_token "$edid_arg" "${files[@]}" || missing+=("$edid_arg")
            vd_file_has_token "$force_arg" "${files[@]}" || missing+=("$force_arg")
            [ "${#missing[@]}" -gt 0 ] || return 0
            joined="${missing[*]}"
            assignment="GRUB_CMDLINE_LINUX_DEFAULT=\"\${GRUB_CMDLINE_LINUX_DEFAULT} $joined\""
            vd_append_marked_block "$VD_GRUB_DEFAULT" "$VD_GRUB_BEGIN" \
                "$VD_GRUB_END" "$assignment" || return 1
            VD_KARGS_MANAGED=1
            VD_KARGS_CHANGED=1
            VD_KARGS_ADDED="$joined"
            ;;
        *) vd_platform_warn "cannot install kernel arguments for $backend"; return 1 ;;
    esac
}

vd_remove_kernel_args() {
    local backend="$1" connector="$2" edid_name="$3" managed="${4:-1}"
    local args="${5:-drm.edid_firmware=${connector}:edid/${edid_name} video=${connector}:e}"
    VD_KARGS_CHANGED=0
    [ "$managed" = "1" ] || return 0
    case "$backend" in
        limine)
            if [ -f "$VD_LIMINE_DROPIN" ] && [ ! -L "$VD_LIMINE_DROPIN" ] &&
               grep -Fxq "$VD_FRAGMENT_MARKER" "$VD_LIMINE_DROPIN"; then
                rm -f "$VD_LIMINE_DROPIN" || return 1
                VD_KARGS_CHANGED=1
            fi
            if [ -f "$VD_LIMINE_DEFAULT" ] &&
               { grep -Fxq "$VD_LIMINE_BEGIN" "$VD_LIMINE_DEFAULT" ||
                 grep -Fxq "$VD_LIMINE_END" "$VD_LIMINE_DEFAULT"; }; then
                vd_remove_marked_block "$VD_LIMINE_DEFAULT" "$VD_LIMINE_BEGIN" "$VD_LIMINE_END" || return 1
                VD_KARGS_CHANGED=1
            fi
            ;;
        grubby)
            [ -n "$args" ] || return 0
            grubby --update-kernel=ALL --remove-args="$args" || return 1
            VD_KARGS_CHANGED=1
            ;;
        grub)
            if [ -f "$VD_GRUB_DEFAULT" ] &&
               { grep -Fxq "$VD_GRUB_BEGIN" "$VD_GRUB_DEFAULT" ||
                 grep -Fxq "$VD_GRUB_END" "$VD_GRUB_DEFAULT"; }; then
                vd_remove_marked_block "$VD_GRUB_DEFAULT" "$VD_GRUB_BEGIN" "$VD_GRUB_END" || return 1
                VD_KARGS_CHANGED=1
            fi
            ;;
        *) vd_platform_warn "cannot remove kernel arguments for $backend"; return 1 ;;
    esac
}

vd_mkinitcpio_config_files() {
    local file dir
    dir="$(dirname "$VD_MKINITCPIO_DROPIN")"
    printf '%s\n' "$VD_MKINITCPIO_CONF"
    if [ -d "$dir" ]; then
        for file in "$dir"/*.conf; do
            [ -f "$file" ] && printf '%s\n' "$file"
        done
    fi
}

vd_dracut_config_files() {
    local file dir
    dir="$(dirname "$VD_DRACUT_DROPIN")"
    printf '%s\n' "$VD_DRACUT_CONF"
    if [ -d "$dir" ]; then
        for file in "$dir"/*.conf; do
            [ -f "$file" ] && printf '%s\n' "$file"
        done
    fi
}

# Sets MANAGED for ownership and CHANGED only when bytes were changed.
vd_install_initramfs_config() {
    local backend="$1" edid_path="$2"
    local -a files=()
    VD_INITRAMFS_CONFIG_MANAGED=0
    VD_INITRAMFS_CONFIG_CHANGED=0
    case "$backend" in
        limine|mkinitcpio)
            [ ! -L "$VD_MKINITCPIO_DROPIN" ] || {
                vd_platform_warn "unsafe mkinitcpio drop-in: $VD_MKINITCPIO_DROPIN"
                return 1
            }
            if [ -e "$VD_MKINITCPIO_DROPIN" ]; then
                [ -f "$VD_MKINITCPIO_DROPIN" ] && [ ! -L "$VD_MKINITCPIO_DROPIN" ] || {
                    vd_platform_warn "unsafe mkinitcpio drop-in: $VD_MKINITCPIO_DROPIN"
                    return 1
                }
                if grep -Fxq "$VD_FRAGMENT_MARKER" "$VD_MKINITCPIO_DROPIN"; then
                    if vd_file_has_token "$edid_path" "$VD_MKINITCPIO_DROPIN"; then
                        VD_INITRAMFS_CONFIG_MANAGED=1
                        return 0
                    fi
                    # Keep the old managed fragment until its atomic replacement
                    # (or deliberate removal below) succeeds.
                fi
            fi
            mapfile -t files < <(vd_mkinitcpio_config_files)
            if vd_file_has_token "$edid_path" "${files[@]}"; then
                if [ -e "$VD_MKINITCPIO_DROPIN" ] &&
                   grep -Fxq "$VD_FRAGMENT_MARKER" "$VD_MKINITCPIO_DROPIN" &&
                   ! vd_file_has_token "$edid_path" "$VD_MKINITCPIO_DROPIN"; then
                    rm -f "$VD_MKINITCPIO_DROPIN" || return 1
                    VD_INITRAMFS_CONFIG_CHANGED=1
                fi
                return 0
            fi
            if [ -e "$VD_MKINITCPIO_DROPIN" ]; then
                grep -Fxq "$VD_FRAGMENT_MARKER" "$VD_MKINITCPIO_DROPIN" || {
                    vd_platform_warn "refusing to replace administrator-owned $VD_MKINITCPIO_DROPIN"
                    return 1
                }
            fi
            vd_write_fragment "$VD_MKINITCPIO_DROPIN" 0644 "FILES+=($edid_path)" || return 1
            VD_INITRAMFS_CONFIG_MANAGED=1
            VD_INITRAMFS_CONFIG_CHANGED=1
            ;;
        dracut)
            [ ! -L "$VD_DRACUT_DROPIN" ] || {
                vd_platform_warn "unsafe dracut drop-in: $VD_DRACUT_DROPIN"
                return 1
            }
            if [ -e "$VD_DRACUT_DROPIN" ]; then
                [ -f "$VD_DRACUT_DROPIN" ] && [ ! -L "$VD_DRACUT_DROPIN" ] || {
                    vd_platform_warn "unsafe dracut drop-in: $VD_DRACUT_DROPIN"
                    return 1
                }
                if grep -Fxq "$VD_FRAGMENT_MARKER" "$VD_DRACUT_DROPIN"; then
                    if vd_file_has_token "$edid_path" "$VD_DRACUT_DROPIN"; then
                        VD_INITRAMFS_CONFIG_MANAGED=1
                        return 0
                    fi
                    # Keep the old managed fragment until its atomic replacement
                    # (or deliberate removal below) succeeds.
                fi
            fi
            mapfile -t files < <(vd_dracut_config_files)
            if vd_file_has_token "$edid_path" "${files[@]}"; then
                if [ -e "$VD_DRACUT_DROPIN" ] &&
                   grep -Fxq "$VD_FRAGMENT_MARKER" "$VD_DRACUT_DROPIN" &&
                   ! vd_file_has_token "$edid_path" "$VD_DRACUT_DROPIN"; then
                    rm -f "$VD_DRACUT_DROPIN" || return 1
                    VD_INITRAMFS_CONFIG_CHANGED=1
                fi
                return 0
            fi
            if [ -e "$VD_DRACUT_DROPIN" ]; then
                grep -Fxq "$VD_FRAGMENT_MARKER" "$VD_DRACUT_DROPIN" || {
                    vd_platform_warn "refusing to replace administrator-owned $VD_DRACUT_DROPIN"
                    return 1
                }
            fi
            vd_write_fragment "$VD_DRACUT_DROPIN" 0644 "install_items+=\" $edid_path \"" || return 1
            VD_INITRAMFS_CONFIG_MANAGED=1
            VD_INITRAMFS_CONFIG_CHANGED=1
            ;;
        update-initramfs) ;;
        *) vd_platform_warn "cannot configure initramfs backend $backend"; return 1 ;;
    esac
}

vd_remove_initramfs_config() {
    local backend="$1" managed="${2:-1}"
    local target=""
    VD_INITRAMFS_CONFIG_CHANGED=0
    [ "$managed" = "1" ] || return 0
    case "$backend" in
        limine|mkinitcpio) target="$VD_MKINITCPIO_DROPIN" ;;
        dracut) target="$VD_DRACUT_DROPIN" ;;
        update-initramfs) ;;
        *) vd_platform_warn "cannot remove initramfs config for $backend"; return 1 ;;
    esac
    if [ -n "$target" ] && { [ -e "$target" ] || [ -L "$target" ]; }; then
        [ -f "$target" ] && [ ! -L "$target" ] && grep -Fxq "$VD_FRAGMENT_MARKER" "$target" || {
            vd_platform_warn "refusing to remove unmarked initramfs config: $target"
            return 1
        }
        rm -f "$target" || return 1
        VD_INITRAMFS_CONFIG_CHANGED=1
    fi
}

vd_refresh_bootloader() {
    local backend="$1"
    case "$backend" in
        limine|grubby) return 0 ;;
        grub)
            if command -v update-grub >/dev/null 2>&1; then
                update-grub
            else
                grub-mkconfig -o "$VD_GRUB_OUTPUT"
            fi
            ;;
        *) vd_platform_warn "cannot refresh bootloader $backend"; return 1 ;;
    esac
}

vd_rebuild_initramfs() {
    local backend="$1"
    case "$backend" in
        limine) "$VD_LIMINE_CMD" ;;
        mkinitcpio)
            if [ -x "$VD_MKINITCPIO_CMD" ]; then
                "$VD_MKINITCPIO_CMD" -P
            else
                mkinitcpio -P
            fi
            ;;
        dracut) "$VD_DRACUT_CMD" --regenerate-all --force ;;
        update-initramfs) "$VD_UPDATE_INITRAMFS_CMD" -u -k all ;;
        *) vd_platform_warn "cannot rebuild initramfs with $backend"; return 1 ;;
    esac
}
