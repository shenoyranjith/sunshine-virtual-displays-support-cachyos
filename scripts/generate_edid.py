#!/usr/bin/env python3
"""Generate a custom EDID for a forced-virtual display connector, for self-hosted
remote streaming on Linux/Wayland.

Builds a multi-block EDID (base DTDs + CTA-861 VICs + HDR10/BT.2020 metadata)
from a curated default mode set, optionally extended by a file of WxH@FPS lines.

  generate_edid.py OUTPUT.bin [--extra extra-modes.txt] [--name NAME]
                              [--max-pixclk-mhz 1200]

Validate the result with `edid-decode OUTPUT.bin`.

Notes / hard limits (see docs/TECHNICAL-NOTES.md):
  * DTD pixel clock is a 16-bit field (10 kHz units) -> 655.35 MHz ceiling.
    Modes above that are skipped here; use CTA VICs for them instead.
  * The CTA SVD native bit (0x80) is only valid for VIC <= 64.
"""

import argparse
import math
import sys

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
# Standard CTA modes via VIC (cheap, support >655 MHz). Native bit only on VIC<=64.
VICS = [97, 118, 96, 95, 63, 16, 4]  # 4K60,4K120,4K50,4K30,1080p120,1080p60,720p60


def parse_modes(path):
    out = []
    try:
        lines = open(path).read().splitlines()
    except FileNotFoundError:
        return out
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        try:
            res, fps = line.split('@')
            w, h = (int(x) for x in res.lower().split('x'))
            out.append((w, h, float(fps)))
        except ValueError:
            sys.stderr.write(f"ignoring unparseable mode: {line}\n")
    return out


def build_custom(extra_path=None):
    raw = list(DEFAULT_CUSTOM)
    if extra_path:
        raw += parse_modes(extra_path)
    custom, seen = [], set()
    for w, h, r in raw:
        key = (w, h, round(r))
        if key in seen:
            continue
        t = cvt_rb(w, h, r)
        if t['pixclk_khz'] // 10 > 0xFFFF:
            sys.stderr.write(f"skip {w}x{h}@{r}: {t['pixclk_khz']/1000:.0f} MHz > 655 MHz\n")
            continue
        seen.add(key)
        custom.append(t)
    return custom


# --------------------------------------------------------------------------- #
# block builders
# --------------------------------------------------------------------------- #

def build_base(base_dtds, name, max_pixclk_mhz):
    b = bytearray(128)
    b[0:8] = b'\x00\xFF\xFF\xFF\xFF\xFF\xFF\x00'
    b[8:10] = b'\x50\x74'        # "PTP" placeholder manufacturer
    b[10:12] = b'\x70\x02'
    b[16] = 22
    b[17] = 34                    # year 2024
    b[18] = 1
    b[19] = 4                     # EDID 1.4
    b[20] = 0xA5                  # digital, 10 bpc, DisplayPort
    b[21] = 60
    b[22] = 34
    b[23] = 120
    b[24] = 0x2E
    b[25:35] = bytes([0x35, 0x85, 0xA6, 0x56, 0x48, 0x9A, 0x24, 0x12, 0x50, 0x54])
    for i in range(8):
        b[38 + i*2] = 0x01
        b[39 + i*2] = 0x01
    b[54:72] = make_dtd(base_dtds[0])
    b[72:90] = make_dtd(base_dtds[1])
    b[90:108] = make_range(24, 240, 30, 510, max_pixclk_mhz)
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
    b[pos] = (1 << 5) | 3           # audio: LPCM 7.1
    b[pos+1], b[pos+2], b[pos+3] = 0x17, 0x7F, 0x07
    pos += 4
    b[pos] = (4 << 5) | 3           # speaker allocation
    b[pos+1] = 0x4F
    pos += 4
    b[pos] = (7 << 5) | 3           # colorimetry: BT.2020 + DCI-P3
    b[pos+1], b[pos+2], b[pos+3] = 0x05, 0xE0, 0x01
    pos += 4
    b[pos] = (7 << 5) | 6           # HDR static metadata: SDR/HDR/PQ/HLG
    b[pos+1:pos+7] = bytes([0x06, 0x0D, 0x01, 0x96, 0x80, 0x01])
    pos += 7
    b[2] = pos
    b[3] = 0x40
    used, p = [], pos
    for t in dtds:
        if p + 18 > 127:
            break
        b[p:p+18] = make_dtd(t)
        used.append(t)
        p += 18
    b[127] = checksum(b)
    return b, used


def build_cta_dtd_only(dtds):
    b = bytearray(128)
    b[0], b[1], b[2], b[3] = 0x02, 0x03, 4, 0x00
    used, p = [], 4
    for t in dtds:
        if p + 18 > 127:
            break
        b[p:p+18] = make_dtd(t)
        used.append(t)
        p += 18
    b[127] = checksum(b)
    return b, used


def build(custom, name, max_pixclk_mhz):
    if len(custom) < 2:
        custom = custom + custom[:1] * (2 - len(custom))
    base = build_base(custom[0:2], name, max_pixclk_mhz)
    rest = custom[2:]
    cta1, used = build_cta_primary(rest)
    rest = rest[len(used):]
    blocks = [base, cta1]
    while rest:
        cta, used = build_cta_dtd_only(rest)
        blocks.append(cta)
        rest = rest[len(used):]
    base[126] = len(blocks) - 1
    base[127] = checksum(base)
    out = bytearray()
    for blk in blocks:
        out += blk
    return bytes(out)


def main():
    ap = argparse.ArgumentParser(description="Generate a virtual-display EDID")
    ap.add_argument("output", help="output .bin path")
    ap.add_argument("--extra", help="file of extra WxH@FPS modes to append")
    ap.add_argument("--name", default="VIRT-DISPLAY", help="monitor name (<=13 chars)")
    ap.add_argument("--max-pixclk-mhz", type=int, default=1200)
    args = ap.parse_args()

    custom = build_custom(args.extra)
    edid = build(custom, args.name, args.max_pixclk_mhz)
    with open(args.output, "wb") as f:
        f.write(edid)

    n = len(edid) // 128
    print(f"Wrote {len(edid)} bytes ({n} blocks) to {args.output}")
    for i in range(n):
        ok = sum(edid[i*128:(i+1)*128]) % 256 == 0
        print(f"  block {i} checksum {'OK' if ok else 'BAD'}")
    print("DTD modes:")
    for t in custom:
        print(f"  {t['w']}x{t['h']}@{t['refresh']}  {t['pixclk_khz']/1000:.2f} MHz")
    print("VIC modes: 4K60,4K120,4K50,4K30,1080p120,1080p60,720p60")
    print("Validate with: edid-decode", args.output)


if __name__ == "__main__":
    main()
