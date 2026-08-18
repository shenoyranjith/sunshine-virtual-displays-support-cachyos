#!/usr/bin/env python3
"""Generate or clone an EDID for a forced-virtual display connector, for
self-hosted remote streaming on Linux/Wayland.

Builds a multi-block EDID (base DTDs + CTA-861 VICs, SDR/sRGB) from a curated
default mode set, or preserves a physical monitor EDID and appends requested
modes in new CTA extension blocks.

  generate_edid.py OUTPUT.bin [--extra extra-modes.txt] [--name NAME]
                              [--max-pixclk-mhz 1200]
  generate_edid.py OUTPUT.bin --source-edid PHYSICAL.bin
                              [--virtualize-identity] [--extra modes.txt]
  generate_edid.py --inspect-source PHYSICAL.bin

Validate the result with `edid-decode OUTPUT.bin`.

Notes / hard limits (see docs/TECHNICAL-NOTES.md):
  * DTD pixel clock is a 16-bit field (10 kHz units) -> 655.35 MHz ceiling.
    Modes above that are skipped here; use CTA VICs for them instead.
  * The CTA SVD native bit (0x80) is only valid for VIC <= 64.
"""

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

MAX_CUSTOM_MODES = 128
MAX_EXTRA_INPUTS = 256
EDID_BLOCK_SIZE = 128
EDID_HEADER = b'\x00\xFF\xFF\xFF\xFF\xFF\xFF\x00'

# --------------------------------------------------------------------------- #
# timing helpers
# --------------------------------------------------------------------------- #

def cvt_rb(w, h, refresh):
    """CVT reduced-blanking-ish timing, safe for a virtual sink."""
    hblank, hfront, hsync = 160, 48, 32
    htotal = w + hblank
    vfront, vsync = 3, 8
    rb_min_vblank = 460e-6
    vblank = math.ceil(rb_min_vblank * refresh * h / (1.0 - rb_min_vblank * refresh))
    vblank = max(vblank, vfront + vsync + 6)
    vtotal = h + vblank
    pixclk_khz = int(round(htotal * vtotal * refresh / 10000.0)) * 10
    return dict(w=w, h=h, refresh=refresh, htotal=htotal, vtotal=vtotal,
                hblank=hblank, hfront=hfront, hsync=hsync,
                vblank=vblank, vfront=vfront, vsync=vsync, pixclk_khz=pixclk_khz)


def make_dtd(t, hmm=600, vmm=340):
    w, h = t['w'], t['h']
    hblank, vblank = t['hblank'], t['vblank']
    hfront, hsync = t['hfront'], t['hsync']
    vfront, vsync = t['vfront'], t['vsync']
    pc = t['pixclk_khz'] // 10
    if pc > 0xFFFF:
        raise ValueError(
            f"{w}x{h}@{t['refresh']} needs {t['pixclk_khz']/1000:.1f} MHz, "
            f"exceeds the 655.35 MHz DTD ceiling; use a VIC instead")
    d = bytearray(18)
    d[0] = pc & 0xFF
    d[1] = (pc >> 8) & 0xFF
    d[2] = w & 0xFF
    d[3] = hblank & 0xFF
    d[4] = ((w >> 4) & 0xF0) | ((hblank >> 8) & 0x0F)
    d[5] = h & 0xFF
    d[6] = vblank & 0xFF
    d[7] = ((h >> 4) & 0xF0) | ((vblank >> 8) & 0x0F)
    d[8] = hfront & 0xFF
    d[9] = hsync & 0xFF
    d[10] = ((vfront & 0x0F) << 4) | (vsync & 0x0F)
    d[11] = (((hfront >> 8) & 3) << 6) | (((hsync >> 8) & 3) << 4) | \
            (((vfront >> 4) & 3) << 2) | ((vsync >> 4) & 3)
    d[12] = hmm & 0xFF
    d[13] = vmm & 0xFF
    d[14] = ((hmm >> 4) & 0xF0) | ((vmm >> 8) & 0x0F)
    d[17] = 0x1E  # digital separate sync, +vsync, +hsync
    return bytes(d)


def make_name(name):
    d = bytearray(18)
    d[3] = 0xFC
    nb = name.encode('ascii')[:13]
    d[5:5 + len(nb)] = nb
    pos = 5 + len(nb)
    if pos < 18:
        d[pos] = 0x0A
        pos += 1
    for i in range(pos, 18):
        d[i] = 0x20
    return bytes(d)


def make_range(min_v, max_v, min_h, max_h, max_pixclk_mhz):
    d = bytearray(18)
    d[3] = 0xFD
    flags = 0
    mv, mh = max_v, max_h
    if mh > 255:           # EDID 1.4 max-rate +255 offset
        flags |= 0x08
        mh -= 255
    if mv > 255:
        flags |= 0x02
        mv -= 255
    d[4] = flags
    d[5] = min_v
    d[6] = mv
    d[7] = min_h
    d[8] = mh
    d[9] = max_pixclk_mhz // 10
    d[10] = 0x01
    for i in range(11, 18):
        d[i] = 0x0A if i == 11 else 0x20
    return bytes(d)


def checksum(block):
    return (256 - (sum(block[:-1]) % 256)) % 256


def set_block_checksum(block):
    """Update the last byte of a mutable 128-byte EDID block."""
    if len(block) != EDID_BLOCK_SIZE:
        raise ValueError("internal error: EDID block is not 128 bytes")
    block[-1] = 0
    block[-1] = (-sum(block[:-1])) & 0xFF


def validate_source_edid(data, source="source EDID"):
    """Validate only the binary invariants needed to clone an OEM EDID safely.

    Real monitor EDIDs commonly fail one or more optional conformance checks in
    edid-decode.  Cloning must retain those bytes, so this deliberately checks
    structure and integrity rather than attempting to repair vendor data.
    """
    if len(data) < EDID_BLOCK_SIZE or len(data) % EDID_BLOCK_SIZE:
        raise ValueError(
            f"{source}: size {len(data)} is not a positive multiple of 128 bytes")
    if data[:8] != EDID_HEADER:
        raise ValueError(f"{source}: invalid EDID header")
    blocks = len(data) // EDID_BLOCK_SIZE
    declared = data[126] + 1
    if declared != blocks:
        raise ValueError(
            f"{source}: base block declares {declared} block(s), file has {blocks}")
    for index in range(blocks):
        block = data[index * EDID_BLOCK_SIZE:(index + 1) * EDID_BLOCK_SIZE]
        if sum(block) % 256:
            raise ValueError(f"{source}: checksum failure in block {index}")
    return blocks


def read_source_edid(path):
    """Read an EDID without consulting st_size (sysfs EDIDs report size zero)."""
    try:
        data = Path(path).read_bytes()
    except OSError as exc:
        raise ValueError(f"cannot read source EDID {path}: {exc}") from exc
    validate_source_edid(data, str(path))
    return data


def cta_data_blocks(block):
    """Yield (tag, payload) pairs from a structurally bounded CTA extension."""
    if len(block) != EDID_BLOCK_SIZE or block[0] != 0x02:
        return
    dtd_offset = block[2]
    if dtd_offset == 0:
        return
    if not 4 <= dtd_offset <= 127:
        return
    pos = 4
    while pos < dtd_offset:
        header = block[pos]
        length = header & 0x1F
        end = pos + 1 + length
        if end > dtd_offset:
            return
        yield header >> 5, bytes(block[pos + 1:end])
        pos = end


def source_vics(data):
    """Return CTA VIC byte values already advertised by the source."""
    found = set()
    for offset in range(EDID_BLOCK_SIZE, len(data), EDID_BLOCK_SIZE):
        for tag, payload in cta_data_blocks(data[offset:offset + EDID_BLOCK_SIZE]):
            if tag == 2:
                # Raw SVD values 129-192 are VICs 1-64 with the native flag.
                # Values above 192 are extended VIC numbers in their own right
                # (e.g. 246 must not be mistaken for native VIC 118).
                for value in payload:
                    found.add(value & 0x7F if 129 <= value <= 192 else value)
    return found


def source_has_block_map(data):
    """Block Maps index later extension positions and cannot stay immutable
    when new blocks are appended after them."""
    return any(data[offset] == 0xF0
               for offset in range(EDID_BLOCK_SIZE, len(data), EDID_BLOCK_SIZE))


def source_name(data):
    for offset in range(54, 126, 18):
        descriptor = data[offset:offset + 18]
        if descriptor[:5] == b'\x00\x00\x00\xFC\x00':
            return descriptor[5:18].split(b'\x0A', 1)[0].decode('ascii', 'replace').rstrip()
    return ""


def inspect_source(data):
    input_byte = data[20]
    cta_hdmi = False
    hdr_static_metadata = False
    bt2020 = False
    eotf_bits = 0
    for offset in range(EDID_BLOCK_SIZE, len(data), EDID_BLOCK_SIZE):
        for tag, payload in cta_data_blocks(data[offset:offset + EDID_BLOCK_SIZE]):
            # HDMI Licensing and HDMI Forum OUIs are stored least-significant
            # byte first in CTA Vendor-Specific Data Blocks. This is the only
            # reliable transport signal in many otherwise valid EDID 1.3 files.
            if tag == 3 and len(payload) >= 3 and payload[:3] in (
                    b'\x03\x0C\x00', b'\xD8\x5D\xC4'):
                cta_hdmi = True
            if tag != 7 or not payload:
                continue
            if payload[0] == 0x05 and len(payload) >= 2:
                bt2020 = bt2020 or bool(payload[1] & 0xE0)
            elif payload[0] == 0x06 and len(payload) >= 2:
                hdr_static_metadata = True
                eotf_bits |= payload[1]

    if not input_byte & 0x80:
        interface = "analog"
        bits_per_color = None
    else:
        interface = {
            0: "undefined",
            1: "dvi",
            2: "hdmi",
            3: "hdmi",
            4: "mddi",
            5: "displayport",
        }.get(input_byte & 0x0F, "reserved")
        bits_per_color = {
            0: None, 1: 6, 2: 8, 3: 10, 4: 12, 5: 14, 6: 16,
        }.get((input_byte >> 4) & 0x07)
    if cta_hdmi:
        interface = "hdmi"

    eotfs = []
    for bit, name in enumerate(("traditional-sdr", "traditional-hdr", "pq", "hlg")):
        if eotf_bits & (1 << bit):
            eotfs.append(name)
    return {
        "bits_per_color": bits_per_color,
        "blocks": len(data) // EDID_BLOCK_SIZE,
        "bt2020": bt2020,
        "bytes": len(data),
        "hdr_eotfs": eotfs,
        "hdr_static_metadata": hdr_static_metadata,
        "interface": interface,
        "name": source_name(data),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def virtualize_identity(data, name):
    """Give a clone a stable distinct identity without touching capabilities."""
    original = bytes(data)
    base = bytearray(original[:EDID_BLOCK_SIZE])
    digest = hashlib.sha256(b"vdisplay-edid-identity\0" + original).digest()
    old_serial = int.from_bytes(base[12:16], "little")
    serial = int.from_bytes(digest[:4], "little") or 1
    if serial == old_serial:
        serial = (serial ^ 0x80000000) or 1
    base[12:16] = serial.to_bytes(4, "little")

    try:
        name_bytes = name.encode("ascii")[:13]
    except UnicodeEncodeError as exc:
        raise ValueError("monitor name must contain ASCII characters only") from exc
    for offset in range(54, 126, 18):
        if base[offset:offset + 5] != b'\x00\x00\x00\xFC\x00':
            continue
        payload = bytearray(b' ' * 13)
        payload[:len(name_bytes)] = name_bytes
        if len(name_bytes) < 13:
            payload[len(name_bytes)] = 0x0A
        base[offset + 5:offset + 18] = payload

    set_block_checksum(base)
    return bytes(base) + original[EDID_BLOCK_SIZE:]


# --------------------------------------------------------------------------- #
# default mode set  (edit freely; non-16:9 / non-CEA modes must be DTDs)
# --------------------------------------------------------------------------- #
DEFAULT_CUSTOM = [
    (2560, 1440, 120),   # preferred / native
    (1920, 1080, 120),
    (2560, 1440, 60),
    (2560, 1440, 144),
    (1920, 1080, 240),
]
# Standard CTA modes via VIC (cheap, support >655 MHz). VIC 1 is required for a
# conforming CTA EDID even though it is not useful as a streaming mode.
VICS = [97, 118, 96, 95, 63, 16, 4, 1]
VIC_BY_MODE_KEY = {
    (3840, 2160, 60.0): 97,
    (3840, 2160, 120.0): 118,
    (3840, 2160, 50.0): 96,
    (3840, 2160, 30.0): 95,
    (1920, 1080, 120.0): 63,
    (1920, 1080, 60.0): 16,
    (1280, 720, 60.0): 4,
    (640, 480, 60.0): 1,
}
VIC_MODE_KEYS = set(VIC_BY_MODE_KEY)


def canonical_mode(w, h, refresh):
    rounded = round(refresh, 3)
    refresh_text = f"{rounded:.3f}".rstrip('0').rstrip('.')
    return f"{w}x{h}@{refresh_text}"


def parse_modes(path):
    out, rejected = [], []
    try:
        lines = open(path).read().splitlines()
    except FileNotFoundError:
        return out, rejected
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if len(out) + len(rejected) >= MAX_EXTRA_INPUTS:
            rejected.append(f"{line}: extra-mode input limit ({MAX_EXTRA_INPUTS}) exceeded")
            continue
        try:
            res, fps = line.split('@')
            w, h = (int(x) for x in res.lower().split('x'))
            out.append((w, h, float(fps), line.lower()))
        except ValueError:
            rejected.append(f"{line}: unparseable mode")
    return out, rejected


def build_custom(extra_path=None, strict_extra=False):
    raw = [(w, h, r, None) for w, h, r in DEFAULT_CUSTOM]
    rejected = []
    if extra_path:
        extra, parse_rejected = parse_modes(extra_path)
        raw += extra
        rejected += parse_rejected
    custom, seen = [], set()
    accepted_extra, accepted_keys = [], set()

    def accept_extra(key):
        if source_line and key not in accepted_keys:
            accepted_extra.append(canonical_mode(w, h, r))
            accepted_keys.add(key)

    for w, h, r, source_line in raw:
        if not (320 <= w <= 4095 and 200 <= h <= 4095 and
                math.isfinite(r) and 24 <= r <= 360):
            message = f"{source_line or f'{w}x{h}@{r}'}: outside encodable/supported range"
            sys.stderr.write(f"skip {message}\n")
            if source_line:
                rejected.append(message)
            continue
        key = (w, h, round(r, 3))
        if key in VIC_MODE_KEYS:
            accept_extra(key)
            continue
        if key in seen:
            accept_extra(key)
            continue
        t = cvt_rb(w, h, r)
        if t['pixclk_khz'] // 10 > 0xFFFF:
            message = f"{source_line or f'{w}x{h}@{r}'}: {t['pixclk_khz']/1000:.0f} MHz > 655 MHz"
            sys.stderr.write(f"skip {message}\n")
            if source_line:
                rejected.append(message)
            continue
        if len(custom) >= MAX_CUSTOM_MODES:
            message = f"{source_line or f'{w}x{h}@{r}'}: custom-mode limit ({MAX_CUSTOM_MODES}) exceeded"
            sys.stderr.write(f"skip {message}\n")
            if source_line:
                rejected.append(message)
            continue
        seen.add(key)
        custom.append(t)
        accept_extra(key)
    if strict_extra and rejected:
        raise ValueError("rejected extra mode(s): " + "; ".join(rejected[:8]))
    return custom, accepted_extra


def build_source_extras(extra_path=None, strict_extra=False):
    """Classify only caller-supplied modes for additive source-EDID blocks."""
    raw, rejected = parse_modes(extra_path) if extra_path else ([], [])
    dtds, vics = [], []
    seen_modes, seen_vics = set(), set()
    accepted, accepted_keys = [], set()

    for w, h, refresh, source_line in raw:
        if not (320 <= w <= 4095 and 200 <= h <= 4095 and
                math.isfinite(refresh) and 24 <= refresh <= 360):
            message = f"{source_line}: outside encodable/supported range"
            sys.stderr.write(f"skip {message}\n")
            rejected.append(message)
            continue
        key = (w, h, round(refresh, 3))
        vic = VIC_BY_MODE_KEY.get(key)
        if vic is not None:
            if vic not in seen_vics:
                vics.append(vic)
                seen_vics.add(vic)
        elif key not in seen_modes:
            timing = cvt_rb(w, h, refresh)
            if timing['pixclk_khz'] // 10 > 0xFFFF:
                message = (
                    f"{source_line}: {timing['pixclk_khz']/1000:.0f} MHz > 655 MHz")
                sys.stderr.write(f"skip {message}\n")
                rejected.append(message)
                continue
            if len(dtds) >= MAX_CUSTOM_MODES:
                message = (
                    f"{source_line}: custom-mode limit ({MAX_CUSTOM_MODES}) exceeded")
                sys.stderr.write(f"skip {message}\n")
                rejected.append(message)
                continue
            dtds.append(timing)
            seen_modes.add(key)

        if key not in accepted_keys:
            accepted.append(canonical_mode(w, h, refresh))
            accepted_keys.add(key)

    if strict_extra and rejected:
        raise ValueError("rejected extra mode(s): " + "; ".join(rejected[:8]))
    return dtds, vics, accepted


# --------------------------------------------------------------------------- #
# block builders
# --------------------------------------------------------------------------- #

def build_base(base_dtds, name, max_pixclk_mhz, interface="displayport"):
    b = bytearray(128)
    b[0:8] = b'\x00\xFF\xFF\xFF\xFF\xFF\xFF\x00'
    b[8:10] = b'\x50\x74'        # "PTP" placeholder manufacturer
    b[10:12] = b'\x70\x02'
    b[16] = 22
    b[17] = 34                    # year 2024
    b[18] = 1
    b[19] = 4                     # EDID 1.4
    interface_code = {"displayport": 0x05, "hdmi": 0x02}[interface]
    b[20] = 0xA0 | interface_code  # digital, 8 bpc, selected interface
    b[21] = 60
    b[22] = 34
    b[23] = 120
    b[24] = 0x2E
    # Standard sRGB chromaticities, matching the sRGB flag in feature byte 24.
    b[25:35] = bytes([0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54])
    for i in range(8):
        b[38 + i*2] = 0x01
        b[39 + i*2] = 0x01
    b[54:72] = make_dtd(base_dtds[0])
    b[72:90] = make_dtd(base_dtds[1])
    b[90:108] = make_range(24, 360, 30, 510, max_pixclk_mhz)
    b[108:126] = make_name(name)
    b[126] = 1
    b[127] = checksum(b)
    return b


def build_cta_primary(dtds):
    b = bytearray(128)
    b[0] = 0x02
    b[1] = 0x03
    pos = 4
    b[pos] = (2 << 5) | len(VICS)
    for i, v in enumerate(VICS):
        b[pos + 1 + i] = v
    pos += 1 + len(VICS)

    # CTA extended tag 0: Video Capability Data Block. Advertise selectable
    # RGB quantization and underscan for IT and CE formats.
    b[pos], b[pos+1], b[pos+2] = (7 << 5) | 2, 0x00, 0x4A
    pos += 3

    b[pos] = (1 << 5) | 3           # audio: LPCM 7.1
    b[pos+1], b[pos+2], b[pos+3] = 0x0F, 0x7F, 0x07
    pos += 4
    b[pos] = (4 << 5) | 3           # speaker allocation
    b[pos+1] = 0x0F
    pos += 4
    b[2] = pos
    b[3] = 0xC0                     # underscan + basic audio
    used, p = [], pos
    for t in dtds:
        if p + 18 > 127:
            break
        b[p:p+18] = make_dtd(t)
        used.append(t)
        p += 18
    b[127] = checksum(b)
    return b, used


def build_cta_dtd_only(dtds, hmm=600, vmm=340, flags=0):
    b = bytearray(128)
    b[0], b[1], b[2], b[3] = 0x02, 0x03, 4, flags
    used, p = [], 4
    for t in dtds:
        if p + 18 > 127:
            break
        b[p:p+18] = make_dtd(t, hmm, vmm)
        used.append(t)
        p += 18
    b[127] = checksum(b)
    return b, used


def build_cta_additive(vics, dtds, hmm, vmm, flags):
    """Build one non-native CTA block containing requested SVDs and DTDs."""
    if len(vics) > 31:
        raise ValueError("too many CTA VICs for one Video Data Block")
    b = bytearray(EDID_BLOCK_SIZE)
    b[0], b[1], b[3] = 0x02, 0x03, flags
    pos = 4
    if vics:
        b[pos] = (2 << 5) | len(vics)
        b[pos + 1:pos + 1 + len(vics)] = bytes(vics)
        pos += 1 + len(vics)
    b[2] = pos
    used, dtd_pos = [], pos
    for timing in dtds:
        if dtd_pos + 18 > 127:
            break
        b[dtd_pos:dtd_pos + 18] = make_dtd(timing, hmm, vmm)
        used.append(timing)
        dtd_pos += 18
    set_block_checksum(b)
    return b, used


def append_source_modes(source, dtds, vics):
    """Append requested modes without modifying any original extension block."""
    advertised_vics = source_vics(source)
    new_vics = [vic for vic in vics if vic not in advertised_vics]
    if not dtds and not new_vics:
        return source

    # Base EDID physical dimensions are in centimetres. Retain the cloned
    # display's geometry in appended DTDs instead of introducing the synthetic
    # generator's 600x340 mm dimensions. Zero means unspecified; use zero in
    # both DTD fields in that case.
    hmm, vmm = source[21] * 10, source[22] * 10
    if not hmm or not vmm:
        hmm = vmm = 0
    # CTA byte 3 is global across CTA extensions: its high bits advertise
    # underscan/audio/YCbCr capabilities and its low nibble is the total number
    # of native DTDs in the whole EDID. Preserve the first source CTA value.
    cta_flags = 0
    for offset in range(EDID_BLOCK_SIZE, len(source), EDID_BLOCK_SIZE):
        block = source[offset:offset + EDID_BLOCK_SIZE]
        if block[0] == 0x02:
            cta_flags = block[3]
            break
    appended = []
    first, used = build_cta_additive(new_vics, dtds, hmm, vmm, cta_flags)
    appended.append(first)
    remaining = dtds[len(used):]
    while remaining:
        block, used = build_cta_dtd_only(remaining, hmm, vmm, cta_flags)
        if not used:
            raise ValueError("internal error: could not encode additive CTA timing")
        appended.append(block)
        remaining = remaining[len(used):]

    old_count = source[126]
    if old_count + len(appended) > 255:
        raise ValueError("source EDID has no extension-block capacity for extra modes")
    base = bytearray(source[:EDID_BLOCK_SIZE])
    base[126] = old_count + len(appended)
    set_block_checksum(base)
    return bytes(base) + source[EDID_BLOCK_SIZE:] + b''.join(appended)


def build(custom, name, max_pixclk_mhz, interface="displayport"):
    if len(custom) < 2:
        custom = custom + custom[:1] * (2 - len(custom))
    base = build_base(custom[0:2], name, max_pixclk_mhz, interface)
    rest = custom[2:]
    cta1, used = build_cta_primary(rest)
    rest = rest[len(used):]
    blocks = [base, cta1]
    while rest:
        cta, used = build_cta_dtd_only(rest, flags=cta1[3])
        blocks.append(cta)
        rest = rest[len(used):]
    if len(blocks) - 1 > 255:
        raise ValueError("EDID extension-block count exceeds the 8-bit limit")
    base[126] = len(blocks) - 1
    base[127] = checksum(base)
    out = bytearray()
    for blk in blocks:
        out += blk
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description="Generate a virtual-display EDID")
    ap.add_argument("output", nargs="?", help="output .bin path")
    ap.add_argument("--source-edid",
                    help="clone this structurally valid EDID instead of using defaults")
    ap.add_argument("--inspect-source", metavar="FILE",
                    help="validate FILE, print its capabilities as JSON, and exit")
    ap.add_argument("--virtualize-identity", action="store_true",
                    help="give a source clone a deterministic virtual serial/name")
    ap.add_argument("--extra", help="file of extra WxH@FPS modes to append")
    ap.add_argument("--accepted-extra-out",
                    help="write extra-mode lines that were actually encoded")
    ap.add_argument("--strict-extra", action="store_true",
                    help="fail instead of skipping any invalid/unencodable extra mode")
    ap.add_argument("--name", default="VIRT-DISPLAY", help="monitor name (<=13 chars)")
    ap.add_argument("--max-pixclk-mhz", type=int, default=1200)
    ap.add_argument("--interface", choices=("displayport", "hdmi"),
                    help="generated EDID transport (default: displayport)")
    args = ap.parse_args()

    if args.inspect_source:
        if args.output or args.source_edid or args.extra or args.accepted_extra_out or \
           args.strict_extra or args.virtualize_identity or args.interface:
            ap.error("--inspect-source is a standalone operation")
        try:
            inspected = read_source_edid(args.inspect_source)
        except ValueError as exc:
            ap.error(str(exc))
        print(json.dumps(inspect_source(inspected), sort_keys=True, separators=(",", ":")))
        return

    if not args.output:
        ap.error("OUTPUT is required unless --inspect-source is used")
    if not (10 <= args.max_pixclk_mhz <= 2550):
        ap.error("--max-pixclk-mhz must be between 10 and 2550")
    if args.virtualize_identity and not args.source_edid:
        ap.error("--virtualize-identity requires --source-edid")
    if args.source_edid and args.interface:
        ap.error("--interface cannot rewrite a source EDID; use a matching source")

    try:
        if args.source_edid:
            source = read_source_edid(args.source_edid)
            custom, added_vics, accepted_extra = build_source_extras(
                args.extra, args.strict_extra)
            advertised_vics = source_vics(source)
            needs_extension = bool(custom or any(
                vic not in advertised_vics for vic in added_vics))
            if needs_extension and source_has_block_map(source):
                message = (
                    "source EDID contains a Block Map; additive modes would "
                    "invalidate its extension index")
                if args.strict_extra:
                    raise ValueError(message)
                sys.stderr.write(f"skip {message}\n")
                custom, added_vics, accepted_extra = [], [], []
            edid = virtualize_identity(source, args.name) \
                if args.virtualize_identity else source
            edid = append_source_modes(edid, custom, added_vics)
            source_mode = True
        else:
            custom, accepted_extra = build_custom(args.extra, args.strict_extra)
            added_vics = VICS
            edid = build(custom, args.name, args.max_pixclk_mhz,
                         args.interface or "displayport")
            source_mode = False
        validate_source_edid(edid, "output EDID")
    except ValueError as exc:
        ap.error(str(exc))
    with open(args.output, "wb") as f:
        f.write(edid)
    if args.accepted_extra_out:
        with open(args.accepted_extra_out, "w", encoding="utf-8") as f:
            for mode in accepted_extra:
                f.write(mode + "\n")

    n = len(edid) // EDID_BLOCK_SIZE
    print(f"Wrote {len(edid)} bytes ({n} blocks) to {args.output}")
    for i in range(n):
        ok = sum(edid[i*EDID_BLOCK_SIZE:(i+1)*EDID_BLOCK_SIZE]) % 256 == 0
        print(f"  block {i} checksum {'OK' if ok else 'BAD'}")
    print("Added DTD modes:" if source_mode else "DTD modes:")
    for timing in custom:
        print(f"  {timing['w']}x{timing['h']}@{timing['refresh']}  "
              f"{timing['pixclk_khz']/1000:.2f} MHz")
    if source_mode:
        if added_vics:
            print("Requested CTA VICs:", ",".join(str(vic) for vic in added_vics))
    else:
        print("VIC modes: 4K60,4K120,4K50,4K30,1080p120,1080p60,720p60,480p60")
    print("Validate with: edid-decode", args.output)


if __name__ == "__main__":
    main()
