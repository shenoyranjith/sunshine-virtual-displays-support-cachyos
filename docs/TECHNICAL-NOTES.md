# Technical notes: NVIDIA / Wayland virtual display

Findings from the original Nobara/Fedora 43 prototype and the current CachyOS
host, both using KDE Plasma 6/KWin Wayland and NVIDIA RTX. The current host was
audited with the NVIDIA 610 series driver. Driver behavior can change, so the
notes distinguish observed behavior from what the Linux and NVIDIA source
interfaces guarantee.

## EDID injection on NVIDIA

- On the tested NVIDIA stack,
  `drm.edid_firmware=<conn>:edid/<file>.bin` did nothing by itself. It also
  needed `video=<conn>:e` to force-enable the connector. Together, the two
  kernel arguments exposed the firmware EDID as a connected output.
- The [Linux firmware-EDID loader](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/drm_edid_load.c)
  selects a blob by connector name, validates it, and uses it instead of
  probing a monitor. NVIDIA's current
  [`nvidia-drm-connector.c`](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/kernel-open/nvidia-drm/nvidia-drm-connector.c)
  passes a DRM override EDID into NvKMS. This is why the blob is not merely a
  list of desktop modes: it becomes the driver's description of the sink.
- The debugfs route (`/sys/kernel/debug/dri/N/<conn>/edid_override`) did not
  reliably re-enumerate modes on the tested driver/KDE combination. Firmware
  EDID changes are therefore treated as boot-time changes and require a
  **reboot**; the project does not depend on hot-reload behavior.
- Put the EDID in `/usr/lib/firmware/edid/` and include it in the initramfs
  (`dracut --force --install <path>`), since the connector may be probed early.
- A **spare connector with no physical plug** (force-enabled) avoids the
  bandwidth cap a physical dummy imposes (DP dummies often train only at HBR
  ≈ 2.7 Gbps → ~150–165 MHz pixel-clock cap regardless of EDID).

## Source EDID strategy

The safest way to retain real HDR and color capabilities is to clone a real
monitor descriptor, not recreate those capabilities from memory:

- `EDID_SOURCE=physical` (the default) reads the connected `PHYS_OUTPUT` on
  the selected DRM card.
- `EDID_SOURCE=file` reads `EDID_SOURCE_FILE`. Use this for an EDID captured
  from the desired monitor input earlier, or on another system.
- `EDID_SOURCE=generated` explicitly selects the synthetic sRGB/SDR fallback.
  Its target interface is selected with the generator's
  `--interface displayport|hdmi`; synthetic output deliberately contains no
  HDR claim.

The source is copied to the root-controlled, immutable baseline
`/var/lib/vdisplay/source-edid.bin`. Dynamic regeneration always begins with
that file. `generate_edid.py --source-edid FILE` preserves the original EDID;
with no extra modes and `EDID_IDENTITY=exact`, the result is byte-for-byte
identical. `EDID_IDENTITY=virtualized` changes only identifying fields so KDE
can distinguish the clone from the physical display, while preserving the
source's CTA/DisplayID feature and vendor blocks. Exact identity is the default
because it eliminates one more variable when investigating NVIDIA quirks;
virtualized identity is useful if duplicate monitor identity confuses KScreen.

When modes are learned, they are placed in new CTA extension blocks. Relative
to the selected exact or identity-virtualized baseline, existing source
extension bytes remain untouched; only the copied base block's extension
count/checksum and the newly appended blocks differ. A source containing a
Block Map cannot satisfy that immutability rule if extension positions change,
so such additions are rejected. Never use the previously generated output as
the next baseline: repeated mutation risks losing or corrupting OEM HDR,
audio, VRR, and vendor data.

### Validation: structural validity versus OEM conformity

A clone must pass the checks needed to consume it safely:

1. the EDID header is present;
2. the size is a non-zero multiple of 128 bytes;
3. byte 126's extension count matches the number of blocks; and
4. every block checksum is valid.

Those are fatal checks. By contrast, `edid-decode --check` can report
conformance failures in an otherwise genuine, working OEM EDID. The tool's own
[manual](https://man.archlinux.org/man/edid-decode.1.en) cautions that its
standards-validation opinions have not been verified by the relevant standards
bodies. The installer therefore reports OEM conformance findings as warnings
instead of rejecting a hardware dump. A virtualized identity or additive mode
block does not change that policy because the result still contains the OEM
blocks and can inherit their findings. A wholly synthetic EDID is expected to
pass the stricter check; repository-added blocks must not introduce new
structural or conformance defects.

Use `generate_edid.py --inspect-source FILE` to validate the structure and,
on success, report the source transport, bit depth, and HDR metadata. NVIDIA's
own [CustomEDID documentation](https://download.nvidia.com/XFree86/Linux-x86_64/610.43.02/README/xconfigoptions.html)
also describes the input as a raw monitor EDID and warns against assigning a
descriptor that does not match the display.

### Transport must match

EDID 1.4 identifies its digital interface, and HDMI descriptors can additionally
carry HDMI VSDB/HF-VSDB fields for deep color, SCDC, FRL, and other
transport-specific capabilities. A DisplayPort clone is therefore not
interchangeable with an HDMI clone merely because both describe the same panel.
The definitions are visible in the kernel's
[`drm_edid.h`](https://github.com/torvalds/linux/blob/master/include/drm/drm_edid.h).

The installer rejects a source/target mismatch by default. The
`ALLOW_EDID_TRANSPORT_MISMATCH=1` escape hatch exists for controlled
experiments, not as the normal HDR setup.

On this CachyOS host specifically:

- the real `DP-3` sink is an MSI MAG321UX OLED with a 384-byte EDID containing
  10-bpc input, BT.2020 colorimetry, PQ/Static Metadata Type 1, OEM luminance,
  VRR data, and DisplayID high-refresh modes;
- the blob has valid block structure and checksums, although the installed
  `edid-decode` reports OEM conformance failures; it is accepted with a warning;
- that base EDID declares **DisplayPort** and has no HDMI VSDB/HF-VSDB; and
- the planned forced output is `HDMI-A-1`.

Consequently the live `DP-3` blob must not silently become the EDID for
`HDMI-A-1`. The preferred HDR workflow is to temporarily connect the same
monitor through HDMI, capture the EDID for that HDMI input on a connector not
already firmware-overridden, reconnect the physical monitor as desired, then
install the captured file with:

```bash
sudo env \
  VIRT_OUTPUT=HDMI-A-1 PHYS_OUTPUT=DP-3 \
  EDID_SOURCE=file EDID_SOURCE_FILE=/absolute/path/to/mag321ux-hdmi.edid \
  EDID_IDENTITY=exact \
  ./install.sh
```

The current `card1-HDMI-A-1/edid` is the old `VirtDisplay` firmware override,
so copying it would not capture the monitor. Capture on another unoverridden
HDMI connector/system, or boot once without the old override. MSI documents
the monitor's HDMI 2.1 inputs and 48-Gbps support on its
[product page](https://www.msi.com/Monitor/MAG-321UPX-QD-OLED/Overview).

The same-transport alternative is to clone `DP-3` onto a verified-free DP
connector such as `DP-1`. Transport compatibility removes one source of
failure, but it still does not guarantee that NVIDIA will accept every HDR or
high-bandwidth mode without a physical DisplayPort sink.

## EDID construction gotchas

- **DTD pixel clock is a 16-bit field in units of 10 kHz → max 655.35 MHz.**
  Any Detailed Timing Descriptor above that silently overflows/wraps. Modes that
  exceed it (e.g. 2560x1440@165 ≈ 700 MHz, 4K120 ≈ 1188 MHz) must come from
  **CTA VICs** (predefined timings) instead of DTDs. `generate_edid.py` guards
  this and rejects offending custom timings (standard high-clock modes are
  advertised separately through CTA VICs).
- **CTA Short Video Descriptor native bit (0x80) is only valid for VIC ≤ 64.**
  Setting it on e.g. VIC 97 yields a bogus `VIC 225` (4K60 = VIC 97 is in the
  65–127 range). Don't OR the native bit onto high VICs.
- **EDID 1.4 monitor range descriptor** horizontal-rate field is 1 byte (≤ 255
  kHz). High-refresh modes exceed it; use the EDID 1.4 max-rate **offset flags**
  (byte 4) to extend by +255.
- Multi-block EDIDs (base + N CTA extensions) work fine on NVIDIA; pack extra
  DTDs into additional CTA blocks and set the extension count in byte 126.
- Bound dynamically learned modes. The generator caps custom timings at 128,
  and the regeneration service stores at most 64 extra modes; unencodable modes
  are rejected rather than being recorded as successfully baked.
- Always decode the result with `edid-decode`. Treat malformed blocks, bad
  checksums, bogus VICs, or nonsensical timings as errors. As described above,
  keep inherited strict conformance findings advisory for an otherwise
  structurally-valid OEM clone, including one with virtualized identity or
  additive mode blocks.

## CachyOS / Arch + Limine

- CachyOS stores persistent Limine kernel parameters through
  `/etc/default/limine` and `/etc/limine-entry-tool.d/*.conf`; do not patch the
  generated `/boot/limine.conf`.
- A configured `KERNEL_CMDLINE[...]` stops Limine from inheriting the running
  or `/etc/kernel/cmdline` arguments. Never create a fragment containing only
  the display arguments: require an existing non-empty persistent base and
  append to it in the highest-priority config. That base remains responsible
  for carrying the system's normal boot and root-filesystem arguments.
- Use `/etc/mkinitcpio.conf.d/*.conf` with `FILES+=(...)` to embed the EDID
  without rewriting the administrator's main `FILES` array.
- Invoke `limine-mkinitcpio` directly. CachyOS's `mkinitcpio` wrapper may prompt
  interactively to update Limine entries, which is unsuitable for an installer
  or systemd service.
- On hybrid/multi-DRM systems, connector status alone is not enough. Resolve
  Sunshine's configured `adapter_name` to its DRM card, then select both the
  physical and spare connectors on that card. Pseudo devices such as EVDI,
  Writeback, or compositor-created virtual connectors must be excluded.
- A force-enabled connector reports `connected` after reboot. Reinstalls should
  recover it from existing config or `drm.edid_firmware=` on `/proc/cmdline`
  before looking for a disconnected connector.

## HDR / VRR: EDID is necessary, not sufficient

HDR requires several independent pieces to agree:

1. The sink descriptor must advertise an appropriate bit depth, BT.2020
   colorimetry, HDR EOTF (normally PQ/ST 2084 for HDR10), Static Metadata Type
   1, and meaningful luminance data. CTA specifies HDR static signaling as an
   [EDID CTA data block plus an InfoFrame](https://shop.cta.tech/products/cta-861-3).
2. The compositor must recognize those sink capabilities, compose/tone-map in
   an HDR-capable format, and set the DRM connector's `Colorspace`, `max bpc`,
   and `HDR_OUTPUT_METADATA` state.
3. The driver must accept the atomic state and program the protocol-specific
   HDR packet. The kernel's
   [KMS documentation](https://docs.kernel.org/gpu/drm-kms.html#standard-connector-properties)
   describes userspace reading HDR capabilities from EDID, supplying output
   metadata, and the driver producing an HDMI DRM InfoFrame or DisplayPort SDP.

Current NVIDIA source attaches HDR metadata and colorspace properties to both
HDMI and DisplayPort connectors and forwards Type-1 metadata/BT.2020 into
NvKMS. It does **not** support the earlier blanket claim that those properties
exist only on a real HDMI 2.1/SCDC link. See NVIDIA's
[`nvidia-drm-connector.c`](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/kernel-open/nvidia-drm/nvidia-drm-connector.c).
However, the same source delegates mode enumeration and validation to NvKMS.
An accurate OEM EDID therefore removes one common rejection cause; it does not
force NvKMS to accept a headless connector state.

An EDID clone also cannot clone link-layer hardware:

- HDMI says FRL is needed for higher uncompressed formats above 4K60 and uses
  a link-training protocol. An HF-VSDB can declare FRL support, but a
  force-enabled empty socket provides no real sink with which to train. See the
  official [HDMI specification overview](https://www.hdmi.org/spec/hdmi2).
- DisplayPort uses DPCD access over AUX for receiver-capability discovery and
  link training; EDID is a separate stream-sink capability description. A
  copied EDID does not emulate DPCD or AUX. See VESA's official
  [DisplayPort overview](https://www.vesa.org/wp-content/uploads/2010/12/DisplayPort-DevCon-Presentation-DP-1.2-Dec-2010-rev-2b.pdf).

This is particularly relevant to 4K120/240, DSC, FRL, and VRR. Lower-bandwidth
HDR modes may work when a correct same-transport EDID is present, while a
higher mode can still fail link or NvKMS validation. Treat the final result as
something to verify on the installed NVIDIA/KWin versions, not a capability
that can be guaranteed from EDID bytes alone.

The repository's synthetic generator intentionally advertises sRGB/SDR, so it
cannot test this path. Use a real, same-transport HDR monitor dump, then verify
after reboot that:

- the kernel-exposed EDID matches the installed source;
- the connector exposes HDR metadata, BT.2020 colorspace, and at least 10 bpc;
- KWin allows HDR for the virtual output; and
- Sunshine/Moonlight negotiate and capture an HDR session at a mode NvKMS
  actually accepted.

VRR is likewise not guaranteed merely by copying an Adaptive-Sync or HDMI VRR
declaration. It depends on connector/link and driver state in addition to the
EDID, and should be reported as unsupported if the post-boot DRM/KWin checks do
not expose it.

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
