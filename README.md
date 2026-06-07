# Virtual display + client-adaptive resolution on Linux/Wayland

> **Status: DRAFT.** Working reference implementation, built and tested on one
> machine (Nobara/Fedora 43, KDE Plasma 6 Wayland, NVIDIA RTX), on a self-hosted
> streaming host. The goal is to distill it into something such a host could
> adopt for everyone. The scripts are
> config-driven (no hardcoded paths/connectors) and `install.sh` auto-detects
> the host, but only the KDE/NVIDIA path is exercised; see "Status / what still
> needs work" for the remaining gaps.

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
A custom EDID loaded on a **spare, force-enabled connector**:
```
drm.edid_firmware=DP-2:edid/virtual-display.bin  video=DP-2:e
```
- `video=<conn>:e` is **mandatory on the NVIDIA proprietary driver**;
  `drm.edid_firmware` alone is silently ignored. Together they expose a fully-virtual output with
  arbitrary modes and **no HBR bandwidth cap** (no physical link).
- `scripts/generate_edid.py` builds a multi-block EDID (DTDs + CTA VICs +
  HDR10/BT.2020 metadata) from a simple mode list, with a DTD pixel-clock
  sanity guard.
- **Could ship as**: official docs + an optional `setup-virtual-display`
  helper/wizard (detect free connector, generate EDID, set kernel args, rebuild
  initramfs). It is inherently system-level config, so "docs + helper" fits
  better than a runtime feature.

### 2. First-class client-adaptive resolution on Linux
The host already exports `SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS/HDR` to prep commands.
`scripts/pick-mode.py` + `scripts/vdisplay-up.sh` set the virtual output to the
client's exact mode (or the closest available) via `kscreen-doctor`.
- **Could ship as**: a Linux backend for the existing display-device layer
  (the Windows-only `dd_*` options), driving `kscreen`/`wlr-output-management`/
  KDE's output API, i.e. parity with Windows auto-config.

### 3. Dynamic EDID extension
When a client requests a mode not present in the virtual EDID, queue it, then
regenerate + reinstall the EDID and rebuild initramfs automatically
(`scripts/edid-regen.sh` + the systemd `.path` watcher in `systemd/system/`).
- **Honest limitation:** NVIDIA reads the firmware EDID at boot and does **not**
  hot-reload it (the debugfs `edid_override` path is also ignored by NVIDIA), so
  a newly-baked mode only appears after a **reboot**. The current session uses
  the closest existing mode meanwhile. Still useful as "self-growing" EDID, but
  upstream may prefer to ship a generous default mode set instead.

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
uninstall.sh                                revert everything: kernel args, units, EDID, scripts, host config
config/vdisplay.conf.example       per-host config (connectors, backend, single-display, inhibit)
scripts/
  generate_edid.py                          build the EDID from a default mode set (+ --extra); edid-decode-clean
  pick-mode.py                              choose exact/closest kscreen mode for a client request
  vdisplay-common.sh                        shared, config-driven backend helpers (kscreen; wlr = TODO)
  vdisplay-up.sh / vdisplay-down.sh         global_prep_cmd do/undo: set virtual output, single-display, inhibit
  edid-regen.sh                             root-side: bake queued modes into the EDID + rebuild initramfs
  monitor-watchdog.sh                       user daemon: keep the physical monitor primary while idle
systemd/
  system/vdisplay-edid-regen.{path,service}.in   watch the pending-modes queue -> regen
  user/monitor-watchdog.service.in               run the watchdog in the graphical session
docs/TECHNICAL-NOTES.md                     the hard-won EDID/NVIDIA details
```

### Quick start (read install.sh first; NVIDIA/KDE only, untested elsewhere)
```bash
sudo ./install.sh
# or pin connectors/mode explicitly:
VIRT_OUTPUT=DP-2 PHYS_OUTPUT=HDMI-A-1 PHYS_MODE=5120x1440@240 sudo -E ./install.sh
# reboot, then verify:
kscreen-doctor -o | grep -A20 DP-2
```
`install.sh` installs all scripts, generates+installs the EDID, sets kernel args
and rebuilds the initramfs, installs the EDID-regen watcher (system) and the
monitor-watchdog (user service), and patches `~/.config/sunshine/sunshine.conf`
(`capture`/`output_name`/`global_prep_cmd`, with a backup). A reboot is required
for the kernel args + initramfs to take effect.

## Status / what still needs work before a PR
Done: hardcoded paths/IDs removed (config-driven + auto-detect), per-distro
kernel-arg + initramfs (grubby/grub, dracut/mkinitcpio/update-initramfs),
`install.sh` + `uninstall.sh`.

Still TODO:
- Compositors beyond KWin: wlroots (`wlr-randr` / `wlr-output-management`) and
  non-KDE fallbacks. `pick-mode.py` and the backend helpers are kscreen-only.
- AMD/Intel paths (they honor `drm.edid_firmware` differently; may not need
  `video=:e`; may even support HDR on virtual outputs, untested here).
- Validate `install.sh` on non-Fedora distros and on systemd-boot.

## Honest caveats (see TECHNICAL-NOTES)
- **No HDR or VRR on a forced virtual connector** with NVIDIA (driver only
  exposes these on a real HDMI 2.1 link with SCDC). HDR streaming requires
  capturing a real HDR display.
- DTD pixel clock is 16-bit → **655.35 MHz ceiling**; higher modes need CTA VICs
  or risk silent overflow.
- New EDID modes require a **reboot** to take effect on NVIDIA.

## Prior art / references
- Native Wayland capture on Linux via the XDG desktop portal / PipeWire / KWin
  screencast path (recently available in the host used to prototype this).
- A community guide on building an NVIDIA virtual display under Wayland
  (gist 8dbf551d66f00e8156ef4dd2b2b090a0).
- NVIDIA developer forums: custom EDID under Wayland; `drm.edid_firmware` ignored
  without `video=:e`; VRR breaks under EDID override.
- EVDI (Extensible Virtual Display Interface) as an alternative kernel-module
  approach to a real virtual display.
