#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(mktemp -d /tmp/vdisplay-edid-test.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT
GENERATOR="$(cd "$(dirname "$0")/.." && pwd)/scripts/generate_edid.py"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_reject() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "$label was accepted"
    fi
}

python3 "$GENERATOR" "$ROOT/default.bin" >/dev/null
python3 - "$ROOT/default.bin" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
assert data and len(data) % 128 == 0
assert all(sum(data[i:i + 128]) % 256 == 0 for i in range(0, len(data), 128))
PY
if command -v edid-decode >/dev/null 2>&1; then
    edid-decode --check "$ROOT/default.bin" >/dev/null
fi

# The generated fallback must describe the connector transport honestly while
# remaining a conforming, deliberately SDR EDID.
python3 "$GENERATOR" "$ROOT/hdmi.bin" --interface hdmi >/dev/null
python3 "$GENERATOR" --inspect-source "$ROOT/hdmi.bin" > "$ROOT/hdmi.json"
python3 - "$ROOT/hdmi.json" <<'PY'
import json
from pathlib import Path
import sys

info = json.loads(Path(sys.argv[1]).read_text())
assert info["interface"] == "hdmi"
assert info["bits_per_color"] == 8
assert info["hdr_static_metadata"] is False
assert info["bt2020"] is False
PY
if command -v edid-decode >/dev/null 2>&1; then
    edid-decode --check "$ROOT/hdmi.bin" >/dev/null
fi

# All CTA extensions must agree on byte 3 capability flags. A source with
# basic-audio/underscan flags therefore passes those flags to additive blocks.
printf '1600x900@75\n' > "$ROOT/hdmi-extra-mode"
python3 "$GENERATOR" "$ROOT/hdmi-extra.bin" --source-edid "$ROOT/hdmi.bin" \
    --extra "$ROOT/hdmi-extra-mode" >/dev/null
python3 - "$ROOT/hdmi.bin" "$ROOT/hdmi-extra.bin" <<'PY'
from pathlib import Path
import sys

source, output = (Path(path).read_bytes() for path in sys.argv[1:])
assert output[128:len(source)] == source[128:]
assert output[128 + 3] == 0xc0
assert output[len(source) + 3] == output[128 + 3]
PY
if command -v edid-decode >/dev/null 2>&1; then
    edid-decode --check "$ROOT/hdmi-extra.bin" >/dev/null
fi

# The low nibble of CTA byte 3 is the native-DTD count for the whole EDID, and
# CTA requires the complete byte to agree across all CTA extensions.
python3 - "$ROOT/hdmi.bin" "$ROOT/native-count-source.bin" <<'PY'
from pathlib import Path
import sys

source = bytearray(Path(sys.argv[1]).read_bytes())
source[128 + 3] = (source[128 + 3] & 0xf0) | 1
source[255] = 0
source[255] = (-sum(source[128:255])) & 0xff
Path(sys.argv[2]).write_bytes(source)
PY
python3 "$GENERATOR" "$ROOT/native-count-extra.bin" \
    --source-edid "$ROOT/native-count-source.bin" \
    --extra "$ROOT/hdmi-extra-mode" >/dev/null
python3 - "$ROOT/native-count-extra.bin" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1]).read_bytes()
assert output[128 + 3] == 0xc1
assert output[256 + 3] == 0xc1
PY
if command -v edid-decode >/dev/null 2>&1; then
    edid-decode --check "$ROOT/native-count-extra.bin" >/dev/null
fi

# A Block Map indexes later extension positions. Since clone mode promises to
# keep every OEM extension byte immutable, it must not append behind one and
# leave the map stale.
python3 - "$ROOT/hdmi.bin" "$ROOT/block-map-source.bin" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_bytes()
base = bytearray(source[:128])
block_map = bytearray(128)
block_map[0], block_map[1] = 0xf0, 0x02
block_map[127] = (-sum(block_map[:127])) & 0xff
base[126] = 2
base[127] = 0
base[127] = (-sum(base[:127])) & 0xff
Path(sys.argv[2]).write_bytes(bytes(base) + bytes(block_map) + source[128:])
PY
if command -v edid-decode >/dev/null 2>&1; then
    edid-decode --check "$ROOT/block-map-source.bin" >/dev/null
fi
: > "$ROOT/block-map.accepted"
python3 "$GENERATOR" "$ROOT/block-map-output.bin" \
    --source-edid "$ROOT/block-map-source.bin" \
    --extra "$ROOT/hdmi-extra-mode" \
    --accepted-extra-out "$ROOT/block-map.accepted" >/dev/null 2>&1
cmp -s "$ROOT/block-map-source.bin" "$ROOT/block-map-output.bin" || \
    fail "additive clone left a Block Map stale"
[ ! -s "$ROOT/block-map.accepted" ] || \
    fail "Block-Map-incompatible mode was reported as accepted"
expect_reject "strict Block Map augmentation" python3 "$GENERATOR" \
    "$ROOT/block-map-strict.bin" --source-edid "$ROOT/block-map-source.bin" \
    --extra "$ROOT/hdmi-extra-mode" --strict-extra

# Make a structurally sound source with a second CTA extension carrying the
# capability bytes clone mode must never normalize away.  The source is based
# on the generated fixture only to keep the test binary self-contained.
python3 - "$ROOT/default.bin" "$ROOT/source.bin" "$ROOT/oem-weird.bin" \
    "$ROOT/base-source.bin" "$ROOT/hdmi13-source.bin" "$ROOT/native-source.bin" \
    "$ROOT/extended-vic-source.bin" <<'PY'
from pathlib import Path
import sys

default_path, source_path, weird_path, base_path, hdmi13_path, native_path, \
    extended_vic_path = \
    map(Path, sys.argv[1:])
default = default_path.read_bytes()
base = bytearray(default[:128])
base[21], base[22] = 70, 40

cta = bytearray(128)
cta[0], cta[1] = 0x02, 0x03
pos = 4
# CTA extended tag 5 (Colorimetry): BT.2020 cYCC/YCC/RGB.
cta[pos:pos + 4] = bytes((0xE3, 0x05, 0xE0, 0x00))
pos += 4
# CTA extended tag 6 (HDR Static Metadata): SDR, traditional HDR and PQ.
cta[pos:pos + 7] = bytes((0xE6, 0x06, 0x07, 0x01, 102, 75, 0))
pos += 7
cta[2] = pos
cta[127] = (-sum(cta[:127])) & 0xff

base[126] = 2
base[127] = 0
base[127] = (-sum(base[:127])) & 0xff
source = bytes(base) + default[128:256] + bytes(cta)
source_path.write_bytes(source)

# Structurally valid but semantically strange OEM data must still be cloneable.
weird = bytearray(source)
weird[8:10] = b'\x00\x00'
weird[127] = 0
weird[127] = (-sum(weird[:127])) & 0xff
weird_path.write_bytes(weird)

base_only = bytearray(source[:128])
base_only[126] = 0
base_only[127] = 0
base_only[127] = (-sum(base_only[:127])) & 0xff
base_path.write_bytes(base_only)

# EDID 1.3 does not encode the digital interface in byte 20. A CTA HDMI VSDB
# must therefore make inspect mode report HDMI.
hdmi13_base = bytearray(base_only)
hdmi13_base[19], hdmi13_base[20], hdmi13_base[126] = 3, 0x80, 1
hdmi13 = bytearray(128)
hdmi13[0], hdmi13[1], hdmi13[2] = 0x02, 0x03, 10
hdmi13[4:10] = bytes((0x65, 0x03, 0x0c, 0x00, 0x10, 0x00))
hdmi13[127] = (-sum(hdmi13[:127])) & 0xff
hdmi13_base[127] = 0
hdmi13_base[127] = (-sum(hdmi13_base[:127])) & 0xff
hdmi13_path.write_bytes(bytes(hdmi13_base) + bytes(hdmi13))

# VIC 16 with the CTA native flag set must be recognized as an existing VIC.
native_base = bytearray(base_only)
native_base[126] = 1
native_cta = bytearray(128)
native_cta[0], native_cta[1], native_cta[2] = 0x02, 0x03, 6
native_cta[4:6] = bytes((0x41, 0x90))
native_cta[127] = (-sum(native_cta[:127])) & 0xff
native_base[127] = 0
native_base[127] = (-sum(native_base[:127])) & 0xff
native_path.write_bytes(bytes(native_base) + bytes(native_cta))

# Raw SVD 246 is extended VIC 246, not native-bit VIC 118.
extended_base = bytearray(base_only)
extended_base[126] = 1
extended_cta = bytearray(128)
extended_cta[0], extended_cta[1], extended_cta[2] = 0x02, 0x03, 6
extended_cta[4:6] = bytes((0x41, 246))
extended_cta[127] = (-sum(extended_cta[:127])) & 0xff
extended_base[127] = 0
extended_base[127] = (-sum(extended_base[:127])) & 0xff
extended_vic_path.write_bytes(bytes(extended_base) + bytes(extended_cta))
PY

# An exact source clone is byte-for-byte identical, even when edid-decode would
# object to optional OEM conformance details.
python3 "$GENERATOR" "$ROOT/source-clone.bin" --source-edid "$ROOT/source.bin" >/dev/null
cmp -s "$ROOT/source.bin" "$ROOT/source-clone.bin" || fail "exact source clone changed bytes"
python3 "$GENERATOR" "$ROOT/oem-clone.bin" --source-edid "$ROOT/oem-weird.bin" >/dev/null
cmp -s "$ROOT/oem-weird.bin" "$ROOT/oem-clone.bin" || fail "OEM source was normalized"

python3 "$GENERATOR" --inspect-source "$ROOT/source.bin" > "$ROOT/source.json"
python3 - "$ROOT/source.json" <<'PY'
import json
from pathlib import Path
import sys

info = json.loads(Path(sys.argv[1]).read_text())
assert info["bytes"] == 384 and info["blocks"] == 3
assert info["interface"] == "displayport"
assert info["hdr_static_metadata"] is True
assert info["bt2020"] is True
assert "pq" in info["hdr_eotfs"]
assert len(info["sha256"]) == 64
PY
python3 "$GENERATOR" --inspect-source "$ROOT/hdmi13-source.bin" > "$ROOT/hdmi13.json"
python3 - "$ROOT/hdmi13.json" <<'PY'
import json
from pathlib import Path
import sys

assert json.loads(Path(sys.argv[1]).read_text())["interface"] == "hdmi"
PY

# Identity virtualization is reproducible and may alter only the serial, an
# existing monitor-name payload, and the base checksum.
python3 "$GENERATOR" "$ROOT/virtualized-1.bin" --source-edid "$ROOT/source.bin" \
    --virtualize-identity --name SUNSHINE-VIRT >/dev/null
python3 "$GENERATOR" "$ROOT/virtualized-2.bin" --source-edid "$ROOT/source.bin" \
    --virtualize-identity --name SUNSHINE-VIRT >/dev/null
cmp -s "$ROOT/virtualized-1.bin" "$ROOT/virtualized-2.bin" || \
    fail "virtualized identity is not deterministic"
python3 - "$ROOT/source.bin" "$ROOT/virtualized-1.bin" <<'PY'
from pathlib import Path
import sys

source, changed = (Path(path).read_bytes() for path in sys.argv[1:])
assert len(source) == len(changed)
assert source[128:] == changed[128:]
allowed = set(range(12, 16)) | set(range(113, 126)) | {127}
different = {i for i, pair in enumerate(zip(source, changed)) if pair[0] != pair[1]}
assert different and different <= allowed, sorted(different - allowed)
assert source[12:16] != changed[12:16]
assert b"SUNSHINE-VIRT" in changed[108:126]
assert sum(changed[:128]) % 256 == 0
PY

# Source extras are additive: all original extension bytes stay at their exact
# offsets. Known CTA modes are accepted as SVDs; custom modes use appended DTDs.
cat > "$ROOT/source-modes" <<'EOF'
1600x900@75
1600x900@75.0
3840x2160@120
3840x2160@240
EOF
python3 "$GENERATOR" "$ROOT/source-extra.bin" --source-edid "$ROOT/source.bin" \
    --extra "$ROOT/source-modes" --accepted-extra-out "$ROOT/source.accepted" \
    >/dev/null 2>&1
expect_reject "strict source generation with an unencodable mode" python3 "$GENERATOR" \
    "$ROOT/source-strict.bin" --source-edid "$ROOT/source.bin" \
    --extra "$ROOT/source-modes" --strict-extra
grep -qxF '1600x900@75' "$ROOT/source.accepted" || fail "source DTD extra was not accepted"
grep -qxF '3840x2160@120' "$ROOT/source.accepted" || fail "source VIC extra was not accepted"
[ "$(wc -l < "$ROOT/source.accepted")" = 2 ] || fail "source accepted list is inaccurate"
python3 - "$ROOT/source.bin" "$ROOT/source-extra.bin" <<'PY'
from pathlib import Path
import sys

source, output = (Path(path).read_bytes() for path in sys.argv[1:])
assert output[128:len(source)] == source[128:]
assert output[126] == source[126] + 1
assert all(sum(output[i:i + 128]) % 256 == 0 for i in range(0, len(output), 128))
added = output[len(source):]
assert added[0] == 0x02
pos = added[2]
assert pos == 4                 # no duplicate VIC: source already had VIC 118
dtd = added[pos:pos + 18]
w = dtd[2] | ((dtd[4] & 0xf0) << 4)
h = dtd[5] | ((dtd[7] & 0xf0) << 4)
hmm = dtd[12] | ((dtd[14] & 0xf0) << 4)
vmm = dtd[13] | ((dtd[14] & 0x0f) << 8)
assert (w, h) == (1600, 900)
assert (hmm, vmm) == (700, 400)
PY

# A base-only source demonstrates that source mode appends just the requested
# known VIC and does not leak the synthetic DEFAULT_CUSTOM timing set.
printf '3840x2160@120\n' > "$ROOT/source-vic-mode"
python3 "$GENERATOR" "$ROOT/source-vic.bin" --source-edid "$ROOT/base-source.bin" \
    --extra "$ROOT/source-vic-mode" --accepted-extra-out "$ROOT/source-vic.accepted" \
    >/dev/null
grep -qxF '3840x2160@120' "$ROOT/source-vic.accepted" || fail "new source VIC was not accepted"
python3 - "$ROOT/source-vic.bin" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
assert len(data) == 256 and data[126] == 1
cta = data[128:]
assert cta[:7] == bytes((0x02, 0x03, 0x06, 0x00, 0x41, 118, 0x00))
assert not any(cta[6:127])       # no generated-default DTDs were added
PY

printf '1920x1080@60\n' > "$ROOT/native-mode"
python3 "$GENERATOR" "$ROOT/native-clone.bin" --source-edid "$ROOT/native-source.bin" \
    --extra "$ROOT/native-mode" --accepted-extra-out "$ROOT/native.accepted" >/dev/null
cmp -s "$ROOT/native-source.bin" "$ROOT/native-clone.bin" || \
    fail "native-bit VIC was duplicated"
grep -qxF '1920x1080@60' "$ROOT/native.accepted" || \
    fail "existing native-bit VIC was not accepted"
python3 "$GENERATOR" "$ROOT/extended-vic-clone.bin" \
    --source-edid "$ROOT/extended-vic-source.bin" --extra "$ROOT/source-vic-mode" \
    >/dev/null
python3 - "$ROOT/extended-vic-source.bin" "$ROOT/extended-vic-clone.bin" <<'PY'
from pathlib import Path
import sys

source, output = (Path(path).read_bytes() for path in sys.argv[1:])
assert output[128:len(source)] == source[128:]
assert output[126] == 2
assert output[len(source):len(source) + 7] == \
    bytes((0x02, 0x03, 0x06, 0x00, 0x41, 118, 0x00))
PY

# CTA DTD capacity is bounded per block; overflow is carried into another new
# block while the base extension count and all checksums remain consistent.
: > "$ROOT/seven-source-modes"
for width in $(seq 1500 1506); do
    printf '%sx900@60\n' "$width" >> "$ROOT/seven-source-modes"
done
python3 "$GENERATOR" "$ROOT/seven-source.bin" --source-edid "$ROOT/base-source.bin" \
    --extra "$ROOT/seven-source-modes" --accepted-extra-out "$ROOT/seven.accepted" \
    >/dev/null
[ "$(wc -l < "$ROOT/seven.accepted")" = 7 ] || fail "CTA spill rejected a valid source mode"
python3 - "$ROOT/seven-source.bin" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
assert len(data) == 384 and data[126] == 2
assert all(sum(data[i:i + 128]) % 256 == 0 for i in range(0, len(data), 128))
PY

# A legal EDID can already consume all 255 extension slots. Exact cloning still
# works, but an additive request must fail rather than wrap the count byte.
python3 - "$ROOT/base-source.bin" "$ROOT/max-blocks.bin" <<'PY'
from pathlib import Path
import sys

base = bytearray(Path(sys.argv[1]).read_bytes())
base[126] = 255
base[127] = 0
base[127] = (-sum(base[:127])) & 0xff
Path(sys.argv[2]).write_bytes(bytes(base) + bytes(128 * 255))
PY
python3 "$GENERATOR" "$ROOT/max-blocks-clone.bin" --source-edid "$ROOT/max-blocks.bin" \
    >/dev/null
cmp -s "$ROOT/max-blocks.bin" "$ROOT/max-blocks-clone.bin" || \
    fail "maximum-block source clone changed bytes"
expect_reject "source extension-count overflow" python3 "$GENERATOR" \
    "$ROOT/max-blocks-extra.bin" --source-edid "$ROOT/max-blocks.bin" \
    --extra "$ROOT/source-vic-mode"

# Reject malformed sources before producing an output file.
python3 - "$ROOT/source.bin" "$ROOT" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_bytes()
root = Path(sys.argv[2])

bad = bytearray(source); bad[0] ^= 1
(root / "bad-header.bin").write_bytes(bad)
(root / "bad-length.bin").write_bytes(source[:-1])
bad = bytearray(source); bad[126] = 1; bad[127] = 0; bad[127] = (-sum(bad[:127])) & 0xff
(root / "bad-count.bin").write_bytes(bad)
bad = bytearray(source); bad[140] ^= 1
(root / "bad-checksum.bin").write_bytes(bad)
PY
for invalid in bad-header bad-length bad-count bad-checksum; do
    expect_reject "invalid source $invalid" python3 "$GENERATOR" "$ROOT/$invalid.out" \
        --source-edid "$ROOT/$invalid.bin"
done
expect_reject "source transport rewrite" python3 "$GENERATOR" "$ROOT/rewrite.bin" \
    --source-edid "$ROOT/source.bin" --interface hdmi
expect_reject "identity virtualization without a source" python3 "$GENERATOR" \
    "$ROOT/no-source-identity.bin" --virtualize-identity

printf '1600x900@75\n3840x2160@240\n' > "$ROOT/modes"
if python3 "$GENERATOR" "$ROOT/strict.bin" --extra "$ROOT/modes" --strict-extra \
    >/dev/null 2>&1; then
    fail "strict generation accepted an unencodable mode"
fi
python3 "$GENERATOR" "$ROOT/filtered.bin" --extra "$ROOT/modes" \
    --accepted-extra-out "$ROOT/accepted" >/dev/null 2>&1
grep -qxF '1600x900@75' "$ROOT/accepted" || fail "valid extra mode was not accepted"
if grep -qxF '3840x2160@240' "$ROOT/accepted"; then
    fail "unencodable extra mode was reported as accepted"
fi

cat > "$ROOT/aliases" <<'EOF'
1600x900@75
1600x900@75.0
1600x900@75.00
3840x2160@120
640x480@300
EOF
python3 "$GENERATOR" "$ROOT/aliases.bin" --extra "$ROOT/aliases" \
    --accepted-extra-out "$ROOT/aliases.accepted" >/dev/null 2>&1
[ "$(wc -l < "$ROOT/aliases.accepted")" = 3 ] || fail "mode aliases were not canonicalized/deduplicated"
grep -qxF '1600x900@75' "$ROOT/aliases.accepted" || fail "canonical refresh missing"
grep -qxF '3840x2160@120' "$ROOT/aliases.accepted" || fail "CTA VIC mode was not accepted"
grep -qxF '640x480@300' "$ROOT/aliases.accepted" || fail "300 Hz mode was not accepted"
if command -v edid-decode >/dev/null 2>&1; then
    edid-decode --check "$ROOT/aliases.bin" >/dev/null
fi

: > "$ROOT/too-many"
for width in $(seq 1000 1130); do
    printf '%sx700@60\n' "$width" >> "$ROOT/too-many"
done
if python3 "$GENERATOR" "$ROOT/overflow.bin" --extra "$ROOT/too-many" --strict-extra \
    >/dev/null 2>&1; then
    fail "custom-mode cap was not enforced"
fi

echo "EDID tests passed"
