#!/usr/bin/env bash
# Exercise the root regeneration queue in an isolated user namespace. In
# particular, a no-op invocation must not modify the PathModified-watched file.
set -Eeuo pipefail

command -v bwrap >/dev/null 2>&1 || { echo "regen test skipped (bwrap unavailable)"; exit 0; }

ROOT="$(mktemp -d /tmp/vdisplay-regen-test.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PENDING="$ROOT/var/lib/vdisplay/pending-modes.txt"
PROCESSING="$ROOT/var/lib/vdisplay/processing-modes.txt"
EXTRA="$ROOT/var/lib/vdisplay/extra-modes.txt"

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$ROOT/etc" "$ROOT/usr/local/bin" "$ROOT/usr/local/libexec/vdisplay" \
    "$ROOT/usr/lib/firmware/edid" "$ROOT/var/lib/vdisplay" "$ROOT/opt/repo"
chmod 0755 "$ROOT/var/lib/vdisplay"
printf 'root:x:0:0:root:/root:/bin/bash\n' > "$ROOT/etc/passwd"
printf 'root:x:0:\n' > "$ROOT/etc/group"
printf 'passwd: files\ngroup: files\n' > "$ROOT/etc/nsswitch.conf"
install -m0755 "$REPO/scripts/vdisplay-platform.sh" \
    "$ROOT/usr/local/libexec/vdisplay/vdisplay-platform.sh"
install -m0755 "$REPO/scripts/generate_edid.py" \
    "$ROOT/usr/local/libexec/vdisplay/generate_edid.py"
python3 "$REPO/scripts/generate_edid.py" \
    "$ROOT/var/lib/vdisplay/source-edid.bin" --interface displayport >/dev/null
# Add a checksum-valid CTA extension containing the real-world HDR static
# metadata and BT.2020 blocks used by clone mode. This source need not be
# edid-decode-conformant: OEM semantic warnings are deliberately non-fatal.
python3 - "$ROOT/var/lib/vdisplay/source-edid.bin" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = bytearray(path.read_bytes())
hdr = bytearray(128)
hdr[0:4] = bytes((0x02, 0x03, 0x0f, 0x00))
hdr[4:11] = bytes((0xe6, 0x06, 0x07, 0x01, 0x8a, 0x60, 0x08))
hdr[11:15] = bytes((0xe3, 0x05, 0xc0, 0x00))
hdr[127] = (-sum(hdr[:127])) & 0xff
data[126] += 1
data[127] = (-sum(data[:127])) & 0xff
path.write_bytes(data + hdr)
PY
SOURCE_HASH="$(sha256sum "$ROOT/var/lib/vdisplay/source-edid.bin" | awk '{ print $1 }')"
cat > "$ROOT/usr/local/bin/limine-mkinitcpio" <<'EOF'
#!/usr/bin/env bash
[ ! -e /var/lib/vdisplay/fail-initramfs ] || exit 42
printf 'rebuild\n' >> /var/lib/vdisplay/rebuild-trace
EOF
chmod 0755 "$ROOT/usr/local/bin/limine-mkinitcpio"
cat > "$ROOT/etc/vdisplay-regen.conf" <<EOF
TARGET_USER=root
USER_HOME=/root
STATE_DIR=/root
REGEN_DIR=/var/lib/vdisplay
PENDING_FILE=/var/lib/vdisplay/pending-modes.txt
PENDING_LOCK=/var/lib/vdisplay/pending-modes.lock
PLATFORM_HELPER=/usr/local/libexec/vdisplay/vdisplay-platform.sh
INITRAMFS_BACKEND=limine
EDID_DST=/usr/lib/firmware/edid/virtual-display.bin
EDID_SOURCE=file
EDID_SOURCE_HASH=$SOURCE_HASH
EDID_IDENTITY=exact
EDID_SOURCE_INTERFACE=displayport
EDID_TARGET_INTERFACE=displayport
EDID_SOURCE_SNAPSHOT=/var/lib/vdisplay/source-edid.bin
EOF
chmod 0600 "$ROOT/etc/vdisplay-regen.conf"
: > "$PENDING"
: > "$ROOT/var/lib/vdisplay/pending-modes.lock"
chmod 0644 "$PENDING"
chmod 0600 "$ROOT/var/lib/vdisplay/pending-modes.lock"

run_regen() {
    bwrap --die-with-parent --unshare-user --uid 0 --gid 0 \
        --ro-bind / / --bind "$ROOT/etc" /etc --bind "$ROOT/usr/local" /usr/local \
        --bind "$ROOT/usr/lib/firmware" /usr/lib/firmware \
        --bind "$ROOT/var/lib" /var/lib --tmpfs /tmp --dev /dev --proc /proc \
        --bind "$ROOT/opt" /opt --ro-bind "$REPO" /opt/repo --chdir /opt/repo \
        /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root \
        REGEN_DEBOUNCE_SECONDS=0 /opt/repo/scripts/edid-regen.sh
}

# Empty startup must leave the watched queue inode metadata untouched.
touch -d @1000000000 "$PENDING"
mtime_before="$(stat -c %y "$PENDING")"
run_regen
[ "$(stat -c %y "$PENDING")" = "$mtime_before" ] || fail "empty regeneration modified the watched queue"
[ ! -e "$PROCESSING" ] || fail "empty regeneration left a processing batch"

# A durable batch from a killed/failed prior attempt must be consumed without
# rewriting the empty watched queue.
printf '1600x900@75\n' > "$EXTRA"
printf '1600x900@75\n' > "$PROCESSING"
chmod 0600 "$EXTRA" "$PROCESSING"
touch -d @1000000001 "$PENDING"
mtime_before="$(stat -c %y "$PENDING")"
run_regen
[ "$(stat -c %y "$PENDING")" = "$mtime_before" ] || fail "durable retry modified the empty watched queue"
[ ! -e "$PROCESSING" ] || fail "completed durable batch was not removed"

# A failed privileged rebuild keeps PROCESSING durable. Its delayed retry must
# consume that batch without touching the empty PathModified queue.
printf '1700x900@75\n' > "$PENDING"
: > "$ROOT/var/lib/vdisplay/fail-initramfs"
if run_regen; then
    fail "failed initramfs rebuild unexpectedly succeeded"
fi
[ ! -s "$PENDING" ] || fail "failed batch was not moved out of the user queue"
grep -qxF '1700x900@75' "$PROCESSING" || fail "failed batch was not retained durably"
mtime_after_failure="$(stat -c %y "$PENDING")"
rm -f "$ROOT/var/lib/vdisplay/fail-initramfs"
run_regen
[ "$(stat -c %y "$PENDING")" = "$mtime_after_failure" ] || fail "delayed retry rewrote the watched queue"
[ ! -e "$PROCESSING" ] || fail "successful delayed retry left its durable batch"
grep -qxF '1700x900@75' "$EXTRA" || fail "delayed retry did not commit the accepted mode"
[ "$(sha256sum "$ROOT/var/lib/vdisplay/source-edid.bin" | awk '{ print $1 }')" = "$SOURCE_HASH" ] || \
    fail "regeneration modified the immutable source snapshot"
python3 - "$ROOT/var/lib/vdisplay/source-edid.bin" \
    "$ROOT/usr/lib/firmware/edid/virtual-display.bin" <<'PY' || \
    fail "regeneration did not preserve source HDR/CTA blocks"
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_bytes()
output = Path(sys.argv[2]).read_bytes()
assert output[:126] == source[:126]
assert output[128:len(source)] == source[128:]
# CTA extended tags 0x06 (HDR static metadata) and 0x05 (colorimetry) remain.
assert bytes((0xe6, 0x06, 0x07, 0x01, 0x8a, 0x60, 0x08)) in output
assert bytes((0xe3, 0x05, 0xc0, 0x00)) in output
PY

# A real queue snapshot modifies the watched file once. The follow-up no-op
# invocation that a path unit schedules must not modify it again.
printf '1600x900@75\n' > "$PENDING"
run_regen
[ ! -s "$PENDING" ] || fail "pending queue was not consumed"
mtime_after_batch="$(stat -c %y "$PENDING")"
run_regen
[ "$(stat -c %y "$PENDING")" = "$mtime_after_batch" ] || \
    fail "follow-up no-op retriggered the watched queue"

echo "regen tests passed"
