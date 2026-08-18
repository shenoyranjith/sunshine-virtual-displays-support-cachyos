# Virtual display support for Linux game streaming

Proof-of-concept tooling that gives a **KDE Plasma / Wayland** host a firmware-backed virtual monitor, client-adaptive resolution, and stream-scoped display switching — without a physical dummy plug.

Works with **Sunshine**, **Apollo**, and other Sunshine-compatible hosts that support Linux prep commands and KMS capture.

> **Status: draft / working POC.** Exercised on CachyOS with KDE Plasma 6, NVIDIA, Limine, and Apollo 0.4.x. The original prototype targeted Nobara/Fedora + grubby/dracut. Other compositors, boot loaders, and GPU vendors are best-effort or untested.

## Credits and lineage

This repository is a **CachyOS/Arch fork** of the upstream proof-of-concept:

- **[EnriqueWood/sunshine-virtual-displays-support-poc](https://github.com/EnriqueWood/sunshine-virtual-displays-support-poc)** — parent project and reference implementation, filed alongside [LizardByte/Sunshine#5266](https://github.com/LizardByte/Sunshine/issues/5266) (*Virtual displays not supported on linux*).

Changes in this fork focus on:

- Limine + mkinitcpio on CachyOS/Arch (alongside existing GRUB/grubby/dracut paths)
- Clone-first EDID installation with transport validation and reversible install metadata
- Hybrid-GPU connector selection via the host's Sunshine `adapter_name`
- **Apollo-compatible capture defaults** (`capture = kms`, `output_name = 0`)
- Expanded tests and technical notes from real CachyOS hardware bring-up

If you use or extend this work, please credit the [parent repository](https://github.com/EnriqueWood/sunshine-virtual-displays-support-poc) and the [Sunshine](https://github.com/LizardByte/Sunshine) project it targets.

## What problem this solves

On Linux + Wayland, a good Moonlight/Apollo session usually needs several manual hacks:

1. A **dummy plug** (or kernel EDID tricks) so the host has a second capturable output whose resolution can differ from the physical monitor.
2. **Client-adaptive resolution** — Windows hosts get `dd_*` options; Linux users otherwise hand-roll `global_prep_cmd` scripts.
3. **Games on the wrong display** — with two outputs enabled, Steam and many titles launch on the physical primary.
4. **Mid-stream blanking** — KDE DPMS can turn off the idle streamed output and kill capture.

This repo automates those pieces for a KDE + NVIDIA stack.

## What works today (tested)

On a CachyOS host with an MSI MAG321UX OLED (`DP-3` physical, `DP-1` virtual):

| Feature | Status |
|--------|--------|
| Virtual display via firmware EDID + force-enable | Works |
| Client-adaptive mode (e.g. 4K@120) via `global_prep_cmd` | Works |
| Single-active-output during stream (games on virtual) | Works |
| Stream-scoped DPMS inhibition | Works |
| Idle monitor watchdog (restore physical primary) | Works |
| Apollo KMS capture (`capture = kms`, `output_name = 0`) | Works |
| Dynamic EDID mode learning (reboot to apply new modes) | Works |
| HDR on the virtual output | **Does not work** (see below) |

## Known limitations

### HDR on the virtual output (NVIDIA)

A cloned HDR EDID is **necessary but not sufficient**. The installer can copy a real monitor's 10-bit, BT.2020, PQ, and static-metadata blocks onto a force-enabled connector, and KDE will offer an HDR toggle — but **NVIDIA NvKMS rejects the HDR atomic configuration** on a headless forced port.

Observed on the tested stack (not just high-bandwidth modes):

- 3840×2160@120 SDR — works
- 3840×2160@60 HDR — **rejected** ("display driver rejected the output configuration")
- 2560×1440@240 HDR — **rejected**
- HDR on the **physical** monitor (`DP-3`) — works as usual

The EDID cannot emulate DisplayPort DPCD/AUX link training or an HDMI FRL sink. NvKMS validates HDR colorspace and metadata against real link state. Treat **SDR streaming from the virtual display** as the supported path on NVIDIA + firmware EDID for now.

See [docs/TECHNICAL-NOTES.md](docs/TECHNICAL-NOTES.md) for the full EDID/HDR analysis.

### Other caveats

- **New EDID modes need a reboot** on the tested NVIDIA driver (firmware EDID is boot-time state).
- **EDID transport must match** the forced connector (do not install a DisplayPort blob on HDMI without an explicit override).
- **Apollo 0.4.x does not ship KWin screencast capture**; use `capture = kms`, not `capture = kwin`.
- For KMS, set **`output_name = 0`**, not a connector name. Apollo parses `DP-1` as monitor index `23171`.
- With `SINGLE_DISPLAY=1`, index `0` is whichever output is enabled: physical while idle, virtual while streaming.
- A hard-killed host process may skip the undo prep command; run `vdisplay-down.sh` manually or reboot.
- wlroots/non-KDE backends, AMD/Intel, and systemd-boot/rEFInd install paths remain TODO.

## Requirements

**Host:** KDE Plasma 6 on Wayland, NVIDIA GPU, a spare disconnected connector on the streaming GPU.

**Streaming host:** Sunshine or Apollo with `global_prep_cmd` support. Apollo needs KMS capture and `cap_sys_admin` on the binary (the AUR package sets this).

**CachyOS packages:**

```bash
sudo pacman -S python libkscreen kde-cli-tools jq systemd util-linux limine-mkinitcpio-hook
# Optional but recommended:
sudo pacman -S v4l-utils libnotify edid-decode
```

## Quick start (CachyOS)

### 1. Preflight

Inspect connectors, EDID source, and boot backend without changing anything:

```bash
./install.sh --check
```

Override connectors if auto-detection is wrong:

```bash
sudo env VIRT_OUTPUT=DP-1 PHYS_OUTPUT=DP-3 ./install.sh --check
```

### 2. Install

Typical DisplayPort setup (clone the physical monitor EDID onto a free DP port):

```bash
sudo env \
  VIRT_OUTPUT=DP-1 PHYS_OUTPUT=DP-3 \
  EDID_SOURCE=physical EDID_IDENTITY=exact \
  ./install.sh
```

Reboot when the installer reports boot or initramfs changes, then verify:

```bash
kscreen-doctor -o
```

You should see the virtual connector **connected** (often disabled while idle) with modes from the source monitor.

### 3. Streaming host config

The installer patches `~/.config/sunshine/sunshine.conf` (Apollo uses the same path):

```ini
capture = kms
output_name = 0
global_prep_cmd = [{"do":"…/vdisplay-up.sh","undo":"…/vdisplay-down.sh"}]
```

Restart Apollo/Sunshine after install. For Sunshine builds with KWin screencast support, reinstall with `CAPTURE=kwin` instead.

### 4. Stream

Connect from Moonlight/Artemis. On session start:

- `vdisplay-up.sh` sets the virtual output to the client's requested mode (or closest match)
- disables the physical monitor (`SINGLE_DISPLAY=1`)
- holds a DPMS inhibitor for the session

On disconnect, `vdisplay-down.sh` restores the physical layout.

## How it works

### Boot-time virtual connector

Kernel arguments on a spare connector:

```
drm.edid_firmware=DP-1:edid/virtual-display.bin  video=DP-1:e
```

On NVIDIA, **`video=<conn>:e` is required**; `drm.edid_firmware` alone is not enough. Together they expose a connected output with the installed EDID, avoiding a dummy plug's HBR bandwidth cap.

The EDID blob lives in `/usr/lib/firmware/edid/` and is embedded in the initramfs.

### Runtime display switching

| Phase | Active output | KMS `output_name = 0` |
|-------|---------------|------------------------|
| Idle | Physical (`DP-3`) | Captures physical (startup probe succeeds) |
| Streaming | Virtual (`DP-1`) | Captures virtual |

The monitor watchdog keeps the physical monitor primary whenever no stream lease is active (`$XDG_RUNTIME_DIR/vdisplay.flag`).

### Dynamic EDID growth

When a client requests a mode not in the EDID, `vdisplay-up.sh` queues it. A systemd path unit runs `edid-regen.sh`, appends encodable modes to a new firmware EDID from the immutable source snapshot, and asks for a reboot. Until then, the session uses the closest existing mode.

## Configuration

User runtime config: `~/.config/vdisplay.conf` (written by the installer).

```bash
VIRT_OUTPUT=DP-1      # forced virtual connector
PHYS_OUTPUT=DP-3      # physical monitor to restore
SINGLE_DISPLAY=1      # disable physical during stream (recommended for KMS index 0)
INHIBIT=1             # hold KDE idle inhibitor during stream
BACKEND=kscreen       # output management backend (wlroots = TODO)
DYNAMIC_EDID=1
```

### Install-time environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `VIRT_OUTPUT` | auto | Spare connector to force |
| `PHYS_OUTPUT` | auto | Connected physical monitor on the same DRM card |
| `EDID_SOURCE` | `physical` | `physical`, `file`, or `generated` |
| `EDID_SOURCE_FILE` | — | Path when `EDID_SOURCE=file` |
| `EDID_IDENTITY` | `exact` | `exact` or `virtualized` (KScreen de-duplication) |
| `CAPTURE` | `kms` | `kms` or `kwin` (Sunshine with kwingrab only) |
| `REPLACE_EDID` | `1` | Replace existing firmware EDID (with backup) |
| `DYNAMIC_EDID` | `1` | Enable mode-learning regeneration service |

### EDID source policy

- **`physical`** — snapshot `PHYS_OUTPUT` on the selected DRM card (default; preserves HDR/color/vendor blocks).
- **`file`** — use a captured EDID; required when source and target transports differ (e.g. HDMI capture for an HDMI virtual port).
- **`generated`** — synthetic SDR EDID from `scripts/generate_edid.py`; no HDR claims.

Source and target **transport must match** (DisplayPort EDID on DisplayPort, etc.) unless `ALLOW_EDID_TRANSPORT_MISMATCH=1`.

## Repository layout

```
install.sh / uninstall.sh          Installer and reversible removal
config/vdisplay.conf.example       Runtime config template
scripts/
  generate_edid.py                 Clone, inspect, append modes, or synthesize SDR
  pick-mode.py                     Closest KScreen mode for a client request
  vdisplay-up.sh / vdisplay-down.sh   Sunshine global_prep_cmd pair
  vdisplay-common.sh               Shared KScreen / lease / inhibit helpers
  monitor-watchdog.sh              Restore physical primary when idle
  edid-regen.sh                    Root-side EDID regeneration
  vdisplay-platform.sh             Bootloader + initramfs backends
systemd/                           EDID regen (system) + watchdog (user)
docs/TECHNICAL-NOTES.md            EDID, NVIDIA, Limine, HDR deep dive
tests/                             Rootless unit tests + bwrap install smoke test
```

## Uninstall

```bash
sudo ./uninstall.sh
```

Removes installer-owned scripts, units, boot fragments, and Sunshine keys (when still installer-owned). Preserves administrator-managed boot args and externally managed EDID files unless the install state proves ownership.

## Status / roadmap

**Done in this fork:** Limine/grubby/GRUB, mkinitcpio/dracut, connector auto-detection, NVIDIA card filtering, source-EDID snapshots, transport checks, reversible install metadata, Apollo KMS defaults, tests.

**Still TODO:** wlroots backend, AMD/Intel validation, systemd-boot/rEFInd, upstream Sunshine `dd_*` parity on Linux.

## References

- [EnriqueWood/sunshine-virtual-displays-support-poc](https://github.com/EnriqueWood/sunshine-virtual-displays-support-poc) — parent repository
- [LizardByte/Sunshine#5266](https://github.com/LizardByte/Sunshine/issues/5266) — upstream feature discussion
- [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) — self-hosted game stream host
- [ClassicOldSong/Apollo](https://github.com/ClassicOldSong/Apollo) — Sunshine fork used in CachyOS testing
- [CachyOS Limine boot configuration](https://wiki.cachyos.org/configuration/boot_manager_configuration/)
- [Linux firmware EDID loader](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/drm_edid_load.c)
- [NVIDIA open-gpu-kernel-modules — DRM connector](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/kernel-open/nvidia-drm/nvidia-drm-connector.c)
- Community NVIDIA virtual-display gist: [8dbf551d66f00e8156ef4dd2b2b090a0](https://gist.github.com/8dbf551d66f00e8156ef4dd2b2b090a0)
