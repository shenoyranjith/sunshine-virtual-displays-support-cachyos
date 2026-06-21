# Technical notes: NVIDIA / Wayland virtual display

Findings from building this on Nobara/Fedora 43, KDE Plasma 6 (KWin Wayland),
NVIDIA RTX (proprietary driver 595.x), on a self-hosted streaming host (2026.x
build). They apply to any host of this kind since the moving parts live at the
kernel/EDID/compositor layer.

## EDID injection on NVIDIA

- `drm.edid_firmware=<conn>:edid/<file>.bin` **does nothing by itself** on the
  NVIDIA proprietary driver. You also need `video=<conn>:e` (force-enable the
  connector). Both kernel args together → NVIDIA honors the firmware EDID.
- The debugfs route (`/sys/kernel/debug/dri/N/<conn>/edid_override`) is **stored
  but ignored** by NVIDIA (it does not re-enumerate modes from it). KDE's
  `kscreen` debugfs path likewise does not stick on NVIDIA.
- EDID firmware is read **at boot / driver load** → changing it requires a
  **reboot**. There is no reliable hot-reload on NVIDIA.
- Put the EDID in `/usr/lib/firmware/edid/` and include it in the initramfs
  (`dracut --force --install <path>`), since the connector may be probed early.
- A **spare connector with no physical plug** (force-enabled) avoids the
  bandwidth cap a physical dummy imposes (DP dummies often train only at HBR
  ≈ 2.7 Gbps → ~150–165 MHz pixel-clock cap regardless of EDID).

## EDID construction gotchas

- **DTD pixel clock is a 16-bit field in units of 10 kHz → max 655.35 MHz.**
  Any Detailed Timing Descriptor above that silently overflows/wraps. Modes that
  exceed it (e.g. 2560x1440@165 ≈ 700 MHz, 4K120 ≈ 1188 MHz) must come from
  **CTA VICs** (predefined timings) instead of DTDs. `generate_edid.py` guards
  this and skips/redirects offending modes.
- **CTA Short Video Descriptor native bit (0x80) is only valid for VIC ≤ 64.**
  Setting it on e.g. VIC 97 yields a bogus `VIC 225` (4K60 = VIC 97 is in the
  65–127 range). Don't OR the native bit onto high VICs.
- **EDID 1.4 monitor range descriptor** horizontal-rate field is 1 byte (≤ 255
  kHz). High-refresh modes exceed it; use the EDID 1.4 max-rate **offset flags**
  (byte 4) to extend by +255.
- Multi-block EDIDs (base + N CTA extensions) work fine on NVIDIA; pack extra
  DTDs into additional CTA blocks and set the extension count in byte 126.
- Always validate with `edid-decode` (check `Conformity`, no bogus VICs, DTD
  refresh rates sane).

## HDR / VRR limitation (important)

- On a **forced virtual connector**, NVIDIA does **not** expose HDR or VRR,
  regardless of what the EDID declares. `kscreen-doctor -o` reports
  `HDR: disabled`, `Allow EDR: unsupported`, `Vrr: incapable`.
- NVIDIA only creates the HDR DRM properties (`HDR_OUTPUT_METADATA`,
  `Colorspace`, `max_bpc`) on a **real HDMI 2.1 physical link with SCDC**.
- The previous generator declared BT.2020 colorimetry + HDR static metadata in
  the EDID anyway. With NVIDIA ignoring it the declaration was inert, but KDE
  still saw a wide-gamut sink and could apply color management to SDR content.
  The generator now omits both blocks: the EDID advertises plain sRGB/SDR,
  matching what NVIDIA + Sunshine can actually deliver.
- ⇒ HDR streaming on Linux/NVIDIA currently requires capturing a **real**
  HDR-capable display (locking you to that display's native geometry).
- Overriding EDID can also disable VRR on the affected connector under Wayland.

## Capture / encode (KDE Wayland + NVIDIA)

- `capture = kwin` (KWin direct screencast via PipeWire portal) works on KDE
  where the old `kms`/`wlr` paths did not. It selects output by **connector name**
  (`output_name = DP-2` works as a name, not just an index).
- After a fresh NVIDIA driver update, NVENC/EGL can fail (`Couldn't initialize
  EGL display [0x3001]`) until a **reboot** reloads the driver. Then NVENC +
  DMA-BUF zero-copy work.
- `av1_nvenc` probe failing is harmless if the GPU lacks AV1 encode; HEVC/H.264
  NVENC are used.

## Idle/DPMS inhibition on KDE

- KDE/PowerDevil DPMS does **not** honor logind idle inhibitors reliably; use the
  freedesktop ScreenSaver / PowerManagement inhibit (`kde-inhibit --power
  --screenSaver`). It will **not** appear in `systemd-inhibit --list` even when
  active (different bus interface).
- Hold it for the session lifetime via a transient `systemd-run --user` unit so
  it survives the prep-command process exiting.

## Coordination with external display managers

- A `kscreen`-style daemon or a user "reaffirm primary" watchdog will fight your
  output switching when a mode-change event fires (e.g. launching a game). Detect
  active sessions with an **explicit flag written by the host's session
  lifecycle** (the prep commands), not by sniffing UDP ports (false negatives).
- Put that flag in **`$XDG_RUNTIME_DIR` (tmpfs)**, not on persistent storage. If
  the host is shut down/rebooted mid-stream the "undo" prep command never runs;
  a persistent flag is then stale on next boot and the watchdog wrongly believes
  a stream is active (leaves the physical monitor disabled → black screen). A
  tmpfs flag simply disappears on boot. The watchdog should also restore the
  physical output AND disable the virtual one, since the compositor may restore
  the last (streaming) layout across reboots.
