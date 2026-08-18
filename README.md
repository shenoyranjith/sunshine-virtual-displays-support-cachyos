# Virtual display + client-adaptive resolution on Linux/Wayland

> **Status: DRAFT.** The KDE/NVIDIA runtime was originally built on
> Nobara/Fedora. The installer also supports CachyOS/Arch with Limine and
> mkinitcpio, including hybrid-GPU connector selection. Other compositors and
> GPU vendors remain experimental; see "Status / what still needs work."

## Problem

On Linux + Wayland (especially KDE/KWin + NVIDIA), a good remote-gaming setup
today requires several manual hacks:

1. **You need a physical dummy plug** to have a capturable display whose
   resolution can differ from your real monitor. Cheap dummies only advertise
   low resolutions / refresh rates (e.g. 1080p60) and cap link bandwidth (HBR).
2. **Resolution/FPS does not adapt to the client on Linux.** The host's
   automatic display configuration (`dd_resolution_option`, `dd_refresh_rate_option`,
   …) is **Windows-only** today. Linux users must script `global_prep_cmd`
   themselves.
3. **Games open on the wrong display.** With both the physical monitor and the
   streamed display enabled, Steam/games launch on the physical primary, not on
   the streamed output.
4. **The streamed display blanks mid-session.** KDE/PowerDevil DPMS turns the
   (idle, no local input) display off → capture dies → Moonlight 503.

## What this proposes

These map to discrete, individually-useful contributions:

### 1. Documented NVIDIA-Wayland virtual display (no dummy plug)
A source EDID loaded on a **spare, force-enabled connector**:
```
drm.edid_firmware=DP-2:edid/virtual-display.bin  video=DP-2:e
```
- On the tested NVIDIA drivers, `video=<conn>:e` was required;
  `drm.edid_firmware` alone did not expose the empty connector. Together they
  avoid a dummy plug's trained-link cap, but they do not bypass NvKMS mode
  validation or emulate HDR link-layer negotiation.
- By default, the installer snapshots the EDID from a connected physical
  display on the same DRM card. This preserves the monitor's real bit depth,
  chromaticities, CTA HDR metadata, colorimetry, luminance, and vendor blocks
  instead of trying to imitate them.
- `scripts/generate_edid.py` remains an explicit fallback. It builds a
  standards-clean, synthetic EDID (DTDs + CTA VICs) from a simple mode list,
  but intentionally advertises only sRGB/SDR. It is not the HDR path.
- The source and target must use the same transport. A DisplayPort EDID is not
  silently applied to an HDMI connector (or vice versa), because the base EDID
  interface and HDMI/DP capability blocks are transport-specific.
- **Could ship as**: official docs + an optional `setup-virtual-display`
  helper/wizard (detect a source display and compatible free connector,
  snapshot or generate the EDID, set kernel args, and rebuild initramfs). It is
  inherently system-level config, so "docs + helper" fits better than a
  runtime feature.

### 2. First-class client-adaptive resolution on Linux
The host already exports `SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS/HDR` to prep commands.
`scripts/pick-mode.py` + `scripts/vdisplay-up.sh` set the virtual output to the
client's exact mode (or the closest available) via `kscreen-doctor`.
- **Could ship as**: a Linux backend for the existing display-device layer
  (the Windows-only `dd_*` options), driving `kscreen`/`wlr-output-management`/
  KDE's output API, i.e. parity with Windows auto-config.

### 3. Dynamic EDID extension
When a client requests a mode not present in the virtual EDID, queue it, then
append a mode-only extension, reinstall the EDID, and rebuild initramfs automatically
(`scripts/edid-regen.sh` + the systemd `.path` watcher in `systemd/system/`).
- The captured source is kept as an immutable baseline. Regeneration always
  starts from that baseline and preserves its HDR, color, audio, and vendor
  data; it never repeatedly edits the last generated result or replaces the
  source capabilities with the synthetic SDR template.
- **Honest limitation:** the tested NVIDIA/KDE stack did not reliably
  re-enumerate a changed debugfs EDID. This project therefore treats firmware
  EDID as boot-time state: a newly appended mode appears after a **reboot** and
  the current session uses the closest existing mode meanwhile. This is still
  useful as a "self-growing" EDID, but upstream may prefer to ship a generous
  default mode set instead.

### 4. Stream-scoped idle/DPMS inhibition
`vdisplay-up.sh` holds `kde-inhibit --power --screenSaver` (as a transient
`systemd-run --user` unit) for the stream's duration; `vdisplay-down.sh` releases
it. Prevents the streamed display from blanking → no more 503.
- **Could ship as**: the host taking an idle inhibitor (org.freedesktop.ScreenSaver
  / PowerManagement.Inhibit) for the lifetime of any active session, cross-DE.

### 5. Single-active-output during stream
`vdisplay-up.sh` disables the physical monitor and leaves the virtual output as
the only active display, so games/Steam land on the streamed output;
`vdisplay-down.sh` restores the physical monitor.

## Repository layout

```
install.sh                                  one-shot installer (run as root): replicates the whole setup
uninstall.sh                                remove installer-owned resources; preserve pre-existing boot/EDID state
config/vdisplay.conf.example       per-host config (connectors, backend, single-display, inhibit)
scripts/
  generate_edid.py                          clone/inspect a source, append modes, or synthesize SDR
  pick-mode.py                              choose exact/closest kscreen mode for a client request
  vdisplay-platform.sh                      Limine/GRUB/grubby + initramfs backend helpers
  vdisplay-common.sh                        shared, config-driven backend helpers (kscreen; wlr = TODO)
  vdisplay-up.sh / vdisplay-down.sh         global_prep_cmd do/undo: set virtual output, single-display, inhibit
  edid-regen.sh                             root-side: bake queued modes into the EDID + rebuild initramfs
  monitor-watchdog.sh                       user daemon: keep the physical monitor primary while idle
systemd/
  system/vdisplay-edid-regen.{path,service}.in   watch the pending-modes queue -> regen
  user/monitor-watchdog.service.in               run the watchdog in the graphical session
docs/TECHNICAL-NOTES.md                     the hard-won EDID/NVIDIA details
tests/test-{platform,runtime,regen,edid,install}.sh rootless unit and sandboxed install/uninstall tests
```

### CachyOS + KDE quick start

Required commands are provided by these CachyOS packages:

```bash
sudo pacman -S python libkscreen kde-cli-tools jq systemd util-linux limine-mkinitcpio-hook
# Recommended for EDID conformity validation and desktop notification:
sudo pacman -S v4l-utils libnotify
```

Inspect the detected GPU, connectors, bootloader, and initramfs backend without
changing anything:

```bash
./install.sh --check
```

The tested host needs an explicit source decision: its real MSI monitor is
`DP-3`, while the currently forced target is `HDMI-A-1`. Its live EDID declares
DisplayPort and has no HDMI VSDB/HF-VSDB, so the default `physical` source
correctly fails preflight instead of silently installing that DP blob on HDMI.

For the best chance of retaining HDR on `HDMI-A-1`, temporarily connect the
same monitor through HDMI and capture the EDID exposed for that HDMI input. Do
this on an HDMI connector that is not already subject to a firmware override,
or boot once without the old override. If inspection identifies `VirtDisplay`
instead of the physical monitor, it is still the override and must not be used
as the source. Check that the captured file identifies the MSI monitor and says
`HDMI-a interface`, then unplug that HDMI cable before targeting the connector:

```bash
# Replace cardN-HDMI-A-N with the unoverridden connector used for the capture.
cp /sys/class/drm/cardN-HDMI-A-N/edid "$HOME/mag321ux-hdmi.edid"
test -s "$HOME/mag321ux-hdmi.edid"

python3 scripts/generate_edid.py \
  --inspect-source "$HOME/mag321ux-hdmi.edid"
edid-decode "$HOME/mag321ux-hdmi.edid"

# Switching monitor inputs may leave hot-plug detection asserted; unplug HDMI.
test "$(cat /sys/class/drm/card1-HDMI-A-1/status)" = disconnected

env \
  VIRT_OUTPUT=HDMI-A-1 PHYS_OUTPUT=DP-3 \
  EDID_SOURCE=file \
  EDID_SOURCE_FILE="$HOME/mag321ux-hdmi.edid" \
  EDID_IDENTITY=exact \
  ./install.sh --check

sudo env \
  VIRT_OUTPUT=HDMI-A-1 PHYS_OUTPUT=DP-3 \
  EDID_SOURCE=file \
  EDID_SOURCE_FILE="$HOME/mag321ux-hdmi.edid" \
  EDID_IDENTITY=exact \
  ./install.sh
```

Alternatively, keep the source and target transport both DisplayPort. `DP-1`
and `DP-2` were disconnected on the tested host. Recheck the selected
connector's `status` in `/sys/class/drm/card1-DP-N/status` before choosing one.
The installer rejects a connected virtual target. The only exception is a
reinstall whose trusted state and active kernel command line prove that the same
installer-owned connector is connected because of its firmware override; use
`sudo ./install.sh --check` for that privileged reinstall preflight.

Before changing the virtual target, manually migrate or remove any legacy boot
argument that still maps the same `edid/virtual-display.bin` to `HDMI-A-1`
(for example, `drm.edid_firmware=HDMI-A-1:edid/virtual-display.bin`). The
installer deliberately refuses this conflicting administrator-managed mapping;
it will not silently delete or rewrite unrelated boot arguments.

```bash
sudo env \
  VIRT_OUTPUT=DP-1 PHYS_OUTPUT=DP-3 \
  EDID_SOURCE=physical EDID_IDENTITY=exact \
  ./install.sh
```

For an SDR-only setup that does not depend on any physical source EDID:

```bash
sudo env \
  VIRT_OUTPUT=HDMI-A-1 PHYS_OUTPUT=DP-3 \
  EDID_SOURCE=generated \
  ./install.sh
```

Generic connector and mode overrides remain available:

```bash
# Example for a different host; source and target transports must still match.
sudo env \
  VIRT_OUTPUT=DP-2 PHYS_OUTPUT=DP-3 PHYS_MODE=3840x2160@240 \
  EDID_SOURCE=physical EDID_IDENTITY=exact \
  ./install.sh
```

Reboot only when the installer reports boot/initramfs changes, then verify the
connector selected by the installation:

```bash
kscreen-doctor -o
```

On CachyOS, when arguments are missing the installer adds a marker-delimited
append to the existing `KERNEL_CMDLINE[default]` in `/etc/default/limine`; it
leaves already-present administrator arguments untouched. It embeds a missing
EDID path through an additive mkinitcpio drop-in, then invokes
`limine-mkinitcpio` directly. It never edits generated `/boot/limine.conf` and
refuses to create a display-only Limine command line when a persistent base
command line is absent.

`EDID_SOURCE` controls where the installed blob comes from:

- `physical` (default) snapshots the connected `PHYS_OUTPUT` on the selected
  DRM card;
- `file` uses `EDID_SOURCE_FILE` (the recommended route when the source was
  captured earlier or on another machine/port); and
- `generated` opts into the repository's synthetic SDR EDID.

`EDID_IDENTITY=exact` preserves every OEM byte when no modes are added. This is
the default and the best NVIDIA-compatibility diagnostic. The alternative,
`EDID_IDENTITY=virtualized`, changes only display-identification fields so KDE
does not confuse the physical and virtual outputs, while retaining the source's
color/HDR/vendor capability blocks. Any learned modes are appended in new CTA
extension blocks; the immutable source snapshot at
`/var/lib/vdisplay/source-edid.bin` is never modified.

Source EDIDs must pass structural checks: EDID header, a whole number of
128-byte blocks, matching extension count, and a valid checksum for every
block. `edid-decode --check` findings from an unmodified OEM blob are reported
but are not fatal; real monitors commonly contain standards ambiguities that
their drivers already tolerate. The same policy applies to a clone with a
virtualized identity or appended modes because it still contains the OEM
blocks. A wholly synthetic EDID is expected to pass the stricter conformity
check, and a conformity-clean source is rejected if repository-added blocks
introduce a new finding. Sources containing an EDID Block Map are kept exact;
dynamic modes that would make its extension index stale are not appended.

Once source preflight succeeds, installation replaces the old firmware EDID
and records a reversible backup. Set `REPLACE_EDID=0` only when intentionally
keeping an existing blob; that also prevents the selected source from becoming
the installed EDID.

The installer also installs the monitor watchdog and patches
`~/.config/sunshine/sunshine.conf` (`capture`, `output_name`, and
`global_prep_cmd`). It records the prior values and restores only keys that are
still installer-owned, preserving unrelated or later user edits. A reboot is
required only when boot, initramfs, or EDID state actually changes.

Sunshine's `kwin` capture backend must run in the logged-in KDE graphical
session; Sunshine documents it as incompatible with the system-service mode.

## Status / what still needs work before a PR
Done: config-driven connector selection, Sunshine-adapter/NVIDIA DRM-card
filtering, Limine/grubby/GRUB boot support, persistent
mkinitcpio/dracut configuration, structurally validated source-EDID snapshots,
transport mismatch protection, reversible EDID replacement/install metadata,
and rootless platform/runtime/regeneration/EDID/install tests.
The install smoke test runs the complete install→reinstall→uninstall flow inside
a rootless Bubblewrap filesystem when `bwrap` is available.

Still TODO:
- Compositors beyond KWin: wlroots (`wlr-randr` / `wlr-output-management`) and
  non-KDE fallbacks. `pick-mode.py` and the backend helpers are kscreen-only.
- AMD/Intel paths (they honor `drm.edid_firmware` differently; may not need
  `video=:e`; may even support HDR on virtual outputs, untested here).
- Add CachyOS systemd-boot (`sdboot-manage`) and rEFInd backends. CachyOS with
  Limine is supported; other Arch-family boot paths currently require GRUB.

## Honest caveats (see TECHNICAL-NOTES)
- A real HDR EDID is **necessary, not sufficient**, for HDR on a forced NVIDIA
  connector. It supplies the 10-bit, BT.2020, EOTF, luminance, and vendor
  declarations that DRM/KWin inspect, but it cannot clone HDMI FRL/SCDC or
  DisplayPort DPCD/AUX link training. NVIDIA still validates every requested
  mode and may reject HDR or high-bandwidth modes without a real sink.
- Match the EDID transport to the forced connector. In particular, do not feed
  this host's live `DP-3` dump to `HDMI-A-1` unless deliberately experimenting
  with `ALLOW_EDID_TRANSPORT_MISMATCH=1`; that override is not the recommended
  HDR setup.
- DTD pixel clock is 16-bit → **655.35 MHz ceiling**; higher modes need CTA VICs
  or risk silent overflow.
- Legacy EDID DTD dimensions are 12-bit; dynamically generated custom modes are
  therefore limited to 4095 pixels per dimension until DisplayID support lands.
- New EDID modes require a **reboot** to take effect on NVIDIA.
- A hard-killed Sunshine process may not run its undo command. The lease lives
  only in `$XDG_RUNTIME_DIR` (so reboot clears it); without a reboot, run
  `~/.local/libexec/vdisplay/vdisplay-down.sh` repeatedly until it restores the
  physical display manually (normally once; extra calls clear stale overlap leases).
- Concurrent streams may share one output only when KScreen selects the same
  mode for both; a conflicting second mode is rejected before changing the
  first stream's layout.

## Prior art / references
- CachyOS boot-manager documentation for Limine kernel-command-line management
  and `limine-mkinitcpio`: <https://wiki.cachyos.org/configuration/boot_manager_configuration/>.
- Linux's connector-specific firmware EDID loader:
  <https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/drm_edid_load.c>.
- Linux DRM/KMS HDR connector properties and EDID-derived sink metadata:
  <https://docs.kernel.org/gpu/drm-kms.html#standard-connector-properties>.
- NVIDIA's current DRM connector implementation (override EDID, HDR metadata,
  colorspace, and NvKMS validation):
  <https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/kernel-open/nvidia-drm/nvidia-drm-connector.c>.
- CTA HDR Static Metadata Extensions:
  <https://shop.cta.tech/products/cta-861-3>.
- HDMI FRL overview and VESA DisplayPort link-training/DPCD overview:
  <https://www.hdmi.org/spec/hdmi2> and
  <https://www.vesa.org/wp-content/uploads/2010/12/DisplayPort-DevCon-Presentation-DP-1.2-Dec-2010-rev-2b.pdf>.
- Native Wayland capture on Linux via the XDG desktop portal / PipeWire / KWin
  screencast path (recently available in the host used to prototype this).
- A community guide on building an NVIDIA virtual display under Wayland
  (gist 8dbf551d66f00e8156ef4dd2b2b090a0).
- NVIDIA developer forums: custom EDID under Wayland; `drm.edid_firmware` ignored
  without `video=:e`; VRR breaks under EDID override.
- EVDI (Extensible Virtual Display Interface) as an alternative kernel-module
  approach to a real virtual display.
