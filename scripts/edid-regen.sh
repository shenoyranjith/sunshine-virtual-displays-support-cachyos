#!/usr/bin/env bash
# Root-side EDID regeneration, triggered by the systemd path unit.
set -Eeuo pipefail

CONF=/etc/vdisplay-regen.conf

safe_root_file() {
    local file="$1" owner mode permissions
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    owner="$(stat -c %u "$file")" || return 1
    mode="$(stat -c %a "$file")" || return 1
    [ "$owner" = "0" ] || return 1
    permissions=$((8#$mode))
    (( (permissions & 8#022) == 0 ))
}

safe_root_file "$CONF" || { echo "unsafe or missing $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
: "${TARGET_USER:?}" "${USER_HOME:?}" "${REGEN_DIR:?}" "${PENDING_FILE:?}"
: "${PENDING_LOCK:?}" "${PLATFORM_HELPER:?}" "${INITRAMFS_BACKEND:?}" "${EDID_DST:?}"
: "${EDID_SOURCE:?}" "${EDID_SOURCE_HASH:?}" "${EDID_IDENTITY:?}"
: "${EDID_SOURCE_SNAPSHOT:?}" "${EDID_TARGET_INTERFACE:?}"

case "$EDID_SOURCE" in physical|generated|file) ;; *) echo "invalid EDID_SOURCE" >&2; exit 1 ;; esac
case "$EDID_IDENTITY" in exact|virtualized) ;; *) echo "invalid EDID_IDENTITY" >&2; exit 1 ;; esac
[[ "$EDID_SOURCE_HASH" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid source EDID hash" >&2; exit 1; }
[ "$EDID_SOURCE_SNAPSHOT" = "$REGEN_DIR/source-edid.bin" ] || {
    echo "invalid source EDID snapshot path" >&2
    exit 1
}

safe_root_file "$PLATFORM_HELPER" || { echo "unsafe platform helper" >&2; exit 1; }
# shellcheck disable=SC1090
. "$PLATFORM_HELPER"

[ -d "$REGEN_DIR" ] && [ ! -L "$REGEN_DIR" ] && [ "$(stat -c %u "$REGEN_DIR")" = "0" ] &&
    (( (8#$(stat -c %a "$REGEN_DIR") & 8#022) == 0 )) || {
    echo "unsafe regeneration directory: $REGEN_DIR" >&2
    exit 1
}
[ -f "$PENDING_FILE" ] && [ ! -L "$PENDING_FILE" ] || { echo "unsafe pending file" >&2; exit 1; }
[ -f "$PENDING_LOCK" ] && [ ! -L "$PENDING_LOCK" ] || { echo "unsafe lock file" >&2; exit 1; }

GENERATOR="$(dirname "$PLATFORM_HELPER")/generate_edid.py"
safe_root_file "$GENERATOR" || { echo "unsafe EDID generator" >&2; exit 1; }
safe_root_file "$EDID_SOURCE_SNAPSHOT" || { echo "unsafe EDID source snapshot" >&2; exit 1; }
[ "$(sha256sum "$EDID_SOURCE_SNAPSHOT" | awk '{ print $1 }')" = "$EDID_SOURCE_HASH" ] || {
    echo "immutable EDID source snapshot was modified" >&2
    exit 1
}

EXTRA="$REGEN_DIR/extra-modes.txt"
SRC="$REGEN_DIR/virtual-edid.bin.new"
LOG="$REGEN_DIR/regen.log"
REBOOT_NEEDED="$REGEN_DIR/reboot-needed"
PROCESSING="$REGEN_DIR/processing-modes.txt"
UID_N="$(id -u "$TARGET_USER")"
TMP_EXTRA=""
ACCEPTED_EXTRA=""
NEW_REQUESTS=""
SNAPSHOT_TMP=""
EDID_TMP=""
BATCH="$PROCESSING"
MAX_EXTRA_MODES="${MAX_EXTRA_MODES:-64}"
[[ "$MAX_EXTRA_MODES" =~ ^[0-9]+$ ]] && [ "$MAX_EXTRA_MODES" -ge 1 ] &&
    [ "$MAX_EXTRA_MODES" -le 120 ] || { echo "invalid MAX_EXTRA_MODES" >&2; exit 1; }

for root_output in "$EXTRA" "$SRC" "$LOG" "$REBOOT_NEEDED" "$PROCESSING"; do
    [ ! -L "$root_output" ] || {
        echo "unsafe regeneration symlink: $root_output" >&2
        exit 1
    }
    [ ! -e "$root_output" ] || safe_root_file "$root_output" || {
        echo "unsafe regeneration output: $root_output" >&2
        exit 1
    }
done

cleanup() {
    local status=$?
    set +e
    [ -z "$SNAPSHOT_TMP" ] || rm -f "$SNAPSHOT_TMP"
    [ -z "$TMP_EXTRA" ] || rm -f "$TMP_EXTRA"
    [ -z "$ACCEPTED_EXTRA" ] || rm -f "$ACCEPTED_EXTRA"
    [ -z "$NEW_REQUESTS" ] || rm -f "$NEW_REQUESTS"
    [ -z "$EDID_TMP" ] || rm -f "$EDID_TMP"
    rm -f "$SRC"
    return "$status"
}
trap cleanup EXIT

complete_batch() {
    rm -f "$PROCESSING"
}

normalize_mode() {
    local raw="$1" width height refresh
    [[ "$raw" =~ ^([0-9]+)x([0-9]+)@([0-9]+([.][0-9]+)?)$ ]] || return 1
    width=$((10#${BASH_REMATCH[1]}))
    height=$((10#${BASH_REMATCH[2]}))
    refresh="$(awk -v value="${BASH_REMATCH[3]}" 'BEGIN {
        text=sprintf("%.3f", value + 0)
        sub(/0+$/, "", text); sub(/[.]$/, "", text)
        print text
    }')"
    printf '%sx%s@%s\n' "$width" "$height" "$refresh"
}

exec >>"$LOG" 2>&1
echo "=== $(date -Is) regeneration triggered ==="

# Coalesce the burst of writes produced during stream startup. The user-facing
# queue lock is acquired only for the snapshot/truncate below.
sleep "${REGEN_DEBOUNCE_SECONDS:-2}"

exec 9>>"$PENDING_LOCK"
flock 9
if [ -s "$PENDING_FILE" ]; then
    SNAPSHOT_TMP="$(mktemp "$REGEN_DIR/processing-modes.XXXXXX")"
    [ ! -f "$PROCESSING" ] || cat "$PROCESSING" >> "$SNAPSHOT_TMP"
    cat "$PENDING_FILE" >> "$SNAPSHOT_TMP"
    chmod 0600 "$SNAPSHOT_TMP"
    mv -fT "$SNAPSHOT_TMP" "$PROCESSING"
    SNAPSHOT_TMP=""
    : > "$PENDING_FILE"
    flock -u 9
elif [ -s "$PROCESSING" ]; then
    # A prior attempt already durably moved the queue into PROCESSING. Leave
    # the watched file untouched so PathModified does not trigger us again.
    flock -u 9
    echo "resuming durable processing batch"
else
    # Opening/truncating an empty watched file emits IN_MODIFY and would make
    # the path unit continuously reactivate this otherwise no-op service.
    flock -u 9
    complete_batch
    echo "no pending modes"
    exit 0
fi

mapfile -t WANT < <(grep -oE '[0-9]+x[0-9]+@[0-9]+([.][0-9]+)?' "$BATCH" | sort -u)
[ "${#WANT[@]}" -gt 0 ] || { echo "no pending modes"; complete_batch; exit 0; }

TMP_EXTRA="$(mktemp "$REGEN_DIR/extra-modes.XXXXXX")"
ACCEPTED_EXTRA="$(mktemp "$REGEN_DIR/accepted-modes.XXXXXX")"
NEW_REQUESTS="$(mktemp "$REGEN_DIR/new-modes.XXXXXX")"
: > "$TMP_EXTRA"

# Retain only normalized, bounded entries from older runs.
if [ -f "$EXTRA" ]; then
    while IFS= read -r raw_mode; do
        mode="$(normalize_mode "$raw_mode" || true)"
        [ -n "$mode" ] || continue
        [ "$(wc -l < "$TMP_EXTRA")" -lt "$MAX_EXTRA_MODES" ] || {
            echo "dropping stored mode above limit: $mode"
            continue
        }
        grep -qxF "$mode" "$TMP_EXTRA" || printf '%s\n' "$mode" >> "$TMP_EXTRA"
    done < <(grep -oE '[0-9]+x[0-9]+@[0-9]+([.][0-9]+)?' "$EXTRA" | sort -u)
fi

for raw_mode in "${WANT[@]}"; do
    mode="$(normalize_mode "$raw_mode" || true)"
    [ -n "$mode" ] || { echo "ignoring malformed mode: $raw_mode"; continue; }
    if [[ "$mode" =~ ^([0-9]+)x([0-9]+)@([0-9]+([.][0-9]+)?)$ ]]; then
        width="${BASH_REMATCH[1]}"
        height="${BASH_REMATCH[2]}"
        refresh="${BASH_REMATCH[3]}"
    else
        echo "ignoring malformed mode: $mode"
        continue
    fi
    if (( width < 320 || width > 4095 || height < 200 || height > 4095 )) ||
       ! awk -v value="$refresh" 'BEGIN { exit !(value >= 24 && value <= 360) }'; then
        echo "ignoring out-of-range mode: $mode"
        continue
    fi
    grep -qxF "$mode" "$TMP_EXTRA" && continue
    if [ "$(wc -l < "$TMP_EXTRA")" -ge "$MAX_EXTRA_MODES" ]; then
        echo "rejecting mode at configured limit ($MAX_EXTRA_MODES): $mode"
        continue
    fi
    printf '%s\n' "$mode" >> "$TMP_EXTRA"
    printf '%s\n' "$mode" >> "$NEW_REQUESTS"
done

if [ ! -s "$NEW_REQUESTS" ]; then
    echo "no new valid modes"
    complete_batch
    exit 0
fi

generator_args=("$SRC" --source-edid "$EDID_SOURCE_SNAPSHOT" \
    --extra "$TMP_EXTRA" --accepted-extra-out "$ACCEPTED_EXTRA")
[ "$EDID_IDENTITY" != virtualized ] || generator_args+=(--virtualize-identity)
python3 "$GENERATOR" "${generator_args[@]}"
python3 "$GENERATOR" --inspect-source "$SRC" >/dev/null || {
    echo "generated EDID structure check failed"
    exit 1
}
if command -v edid-decode >/dev/null 2>&1; then
    source_conformant=0
    edid-decode --check "$EDID_SOURCE_SNAPSHOT" >/dev/null 2>&1 && \
        source_conformant=1
    if ! edid-decode --check "$SRC" >/dev/null; then
        if [ "$EDID_SOURCE" = generated ] || [ "$source_conformant" = "1" ]; then
            echo "regenerated EDID introduced a conformity failure"
            exit 1
        fi
        echo "warning: source-derived OEM EDID is structurally valid but non-conformant"
    fi
fi

NEW=0
while IFS= read -r mode; do
    if grep -qxF "$mode" "$ACCEPTED_EXTRA"; then
        NEW=$((NEW + 1))
        echo "accepted: $mode"
    else
        echo "rejected because it cannot be encoded: $mode"
    fi
done < "$NEW_REQUESTS"

if [ "$NEW" -eq 0 ]; then
    echo "no newly requested modes were encodable"
    complete_batch
    exit 0
fi

EDID_PARENT="${EDID_DST%/*}"
[ "$EDID_PARENT" != "$EDID_DST" ] && [ -d "$EDID_PARENT" ] && [ ! -L "$EDID_PARENT" ] || {
    echo "unsafe EDID destination directory: $EDID_PARENT"
    exit 1
}
[ ! -L "$EDID_DST" ] || { echo "unsafe EDID destination symlink"; exit 1; }
EDID_TMP="$(mktemp "$EDID_PARENT/.${EDID_DST##*/}.vdisplay.XXXXXX")"
install -m0644 "$SRC" "$EDID_TMP"
mv -fT "$EDID_TMP" "$EDID_DST"
EDID_TMP=""
vd_rebuild_initramfs "$INITRAMFS_BACKEND"

install -m0600 "$ACCEPTED_EXTRA" "$EXTRA"
date -Is > "$REBOOT_NEEDED"
complete_batch

runuser -u "$TARGET_USER" -- env \
    HOME="$USER_HOME" \
    XDG_RUNTIME_DIR="/run/user/$UID_N" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_N/bus" \
    notify-send -u critical "Virtual display EDID updated" \
    "$NEW new mode(s) baked. Reboot to enable them." 2>/dev/null || true
echo "done: $NEW new mode(s); reboot required"
