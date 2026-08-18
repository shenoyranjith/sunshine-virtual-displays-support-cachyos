# Sunshine / Apollo stream displays for Linux

Give a **KDE Plasma 6 / Wayland** host a second, stream-only output so Moonlight
or Artemis can request their own resolution, games land on that output, and the
desktop monitor comes back when the session ends.

No HDMI dummy plug is required. The stream output is either:

- **virtual** — firmware EDID on a spare, disconnected GPU connector
- **physical** — a real cable that stays plugged in (for example HDMI on a
  dual-input monitor) and is compositor-disabled until a stream starts

Works with **Apollo**, **Sunshine**, and other Sunshine-compatible hosts that
support `global_prep_cmd` and KMS capture.

> **Status: working proof of concept.** Tested on CachyOS, KDE Plasma 6, NVIDIA,
> Limine, and Apollo 0.4.x. The parent project targeted Nobara/Fedora with
> grubby/dracut. Other compositors, boot loaders, and GPU vendors are untested.

This is a **CachyOS/Arch fork** of
[EnriqueWood/sunshine-virtual-displays-support-poc](https://github.com/EnriqueWood/sunshine-virtual-displays-support-poc),
filed alongside [LizardByte/Sunshine#5266](https://github.com/LizardByte/Sunshine/issues/5266).
Please credit that repository and [Sunshine](https://github.com/LizardByte/Sunshine)
if you use or extend this work.

## Choose a stream mode

| | `STREAM_MODE=virtual` (default) | `STREAM_MODE=physical` |
|--|--------------------------------|------------------------|
| Stream connector | Spare port, **unplugged** | Real sink, **always plugged in** |
| How it appears | Kernel EDID + `video=<conn>:e` | Compositor enables it only while streaming |
| Reboot after install | Yes, if boot/initramfs changed | No |
| Extra client modes | Can be learned into firmware EDID (reboot to apply) | Only modes that input already advertises |
| HDR on NVIDIA | Does **not** work (headless forced port) | Uses a real sink; try this for HDR |
| Typical layout | Desktop on `DP-3`, virtual on unused `DP-1` | Desktop on `DP-3`, stream on `HDMI-A-1` |

Switching an existing install from one mode to the other requires
`sudo ./uninstall.sh` first (and a reboot if you are leaving virtual mode, so
the old kernel arguments are gone).

## What is tested

CachyOS host, MSI MAG321UX OLED, NVIDIA, Apollo 0.4.x. Desktop on `DP-3`.

| Feature | Status |
|--------|--------|
| Virtual output via firmware EDID | Works (SDR, including 4K@120) |
| Physical HDMI stream port, disabled until stream | Works |
| Client-adaptive mode via `global_prep_cmd` | Works |
| Only the stream output enabled during a session | Works |
| DPMS inhibit for the session | Works |
| Idle watchdog restores the desktop primary | Works |
| Apollo KMS (`capture = kms`, `output_name = 0`) | Works |
| Firmware EDID mode learning | Virtual mode only |
| HDR on a virtual / force-enabled connector | **Does not work** |
| HDR on a physical stream port | Possible (real sink); not a guarantee |

## Requirements

- KDE Plasma 6 on Wayland
- NVIDIA GPU (the streaming GPU must own both connectors)
- Sunshine or Apollo with `global_prep_cmd`. Apollo needs KMS capture and
  `cap_sys_admin` on the binary (the AUR package sets this)
- Either a free disconnected connector, or a second plugged-in port

```bash
sudo pacman -S python libkscreen kde-cli-tools jq systemd util-linux limine-mkinitcpio-hook
# Optional:
sudo pacman -S v4l-utils libnotify edid-decode
```

## Install

Clone the repo, then inspect without writing anything:

```bash
./install.sh --check
```

Name the connectors explicitly. Auto-detect can pick the wrong pair.

### Virtual display (spare port)

Clone the desktop monitor EDID onto a free DisplayPort (or HDMI) connector:

```bash
sudo env \
  STREAM_MODE=virtual \
  VIRT_OUTPUT=DP-1 PHYS_OUTPUT=DP-3 \
  EDID_SOURCE=physical EDID_IDENTITY=exact \
  ./install.sh
```

Reboot if the installer says boot or initramfs changed. Then:

```bash
kscreen-doctor -o
```

The spare connector should show as **connected** (usually disabled while idle)
with modes from the source monitor.

The source EDID **transport must match** the spare connector (DisplayPort blob
on DisplayPort, HDMI blob on HDMI) unless you set
`ALLOW_EDID_TRANSPORT_MISMATCH=1`. Use `EDID_SOURCE=file` with a dump from the
same kind of input when they differ. `EDID_SOURCE=generated` builds a synthetic
SDR EDID with no HDR claims.

### Physical stream port (real cable)

Leave HDMI (or a second DP) plugged in. Nothing is written to firmware or the
kernel command line:

```bash
sudo env STREAM_MODE=physical VIRT_OUTPUT=HDMI-A-1 PHYS_OUTPUT=DP-3 ./install.sh --check
sudo env STREAM_MODE=physical VIRT_OUTPUT=HDMI-A-1 PHYS_OUTPUT=DP-3 ./install.sh
```

Idle: desktop on `DP-3`, `HDMI-A-1` disabled. Stream: HDMI on, DisplayPort off.

On a dual-input monitor the panel will often **wake and switch to HDMI** when
that port gets a signal. That is the monitor, not this tooling. On MSI MAG
OLEDs, set **Input Source → Auto Scan → OFF**, keep the OSD on **DP**, and
disable **HDMI CEC** if it is on. The GPU still drives HDMI for capture; the
panel stays on DisplayPort, sees no signal, and can sleep.

### After either install

The installer patches `~/.config/sunshine/sunshine.conf` (Apollo uses the same
file):

```ini
capture = kms
output_name = 0
global_prep_cmd = [{"do":"…/vdisplay-up.sh","undo":"…/vdisplay-down.sh"}]
```

Restart Apollo or Sunshine. Use `CAPTURE=kwin` only on Sunshine builds that
ship `kwingrab`; Apollo 0.4.x does not.

`output_name` must be **`0`**, not a connector name. Apollo parses `DP-1` as
monitor index `23171`. With `SINGLE_DISPLAY=1`, index 0 is whichever output is
enabled: the desktop while idle, the stream output while a session is running.

## What happens during a stream

On connect, `vdisplay-up.sh`:

1. Picks the closest KScreen mode to the client width/height/fps
2. Enables the stream output and makes it primary
3. Disables the desktop output (`SINGLE_DISPLAY=1`)
4. Holds a KDE idle/DPMS inhibitor for the session

On disconnect, `vdisplay-down.sh` reverses that. A user unit
(`monitor-watchdog.service`) also restores the desktop primary whenever no
stream lease is present (`$XDG_RUNTIME_DIR/vdisplay.flag`), including after a
reboot that skipped the undo command.

If the host process is killed hard, run `vdisplay-down.sh` yourself or reboot.

## How the two modes work

**Virtual.** The installer installs an EDID at
`/usr/lib/firmware/edid/virtual-display.bin`, embeds it in the initramfs, and
adds kernel arguments:

```
drm.edid_firmware=DP-1:edid/virtual-display.bin  video=DP-1:e
```

On NVIDIA, `drm.edid_firmware` alone does nothing; `video=<conn>:e` is
required. Together they expose a connected output without a dummy plug (and
without a dummy’s HBR bandwidth cap). Firmware EDID is boot-time state: new
modes need a reboot.

If a client asks for a mode that is not in the EDID, the session uses the
closest match and queues the request. A systemd path unit regenerates the
firmware from an immutable source snapshot and asks for a reboot.

**Physical.** No EDID file, no kernel arguments. The stream connector must stay
**connected**. Runtime switching is the same as virtual mode.

## HDR on NVIDIA

A cloned HDR EDID is necessary but not sufficient on a **headless forced**
connector. NvKMS still rejects the HDR atomic commit
(`display driver rejected the output configuration`), including 4K@60 HDR and
1440p@240 HDR, while 4K@120 SDR on the same virtual port works. The blob cannot
fake DisplayPort DPCD/AUX or HDMI FRL link state.

Use **`STREAM_MODE=physical`** when you want the driver to see a real sink
(desktop on DisplayPort, stream on HDMI). SDR from the virtual display remains
the supported firmware-EDID path.

Details: [docs/TECHNICAL-NOTES.md](docs/TECHNICAL-NOTES.md).

## Configuration

`install.sh` writes `~/.config/vdisplay.conf`. Example:
[config/vdisplay.conf.example](config/vdisplay.conf.example).

```bash
STREAM_MODE=virtual   # or physical
VIRT_OUTPUT=DP-1      # stream connector
PHYS_OUTPUT=DP-3      # desktop connector to restore
SINGLE_DISPLAY=1      # disable desktop during stream (needed for KMS index 0)
INHIBIT=1             # KDE idle inhibitor during stream
BACKEND=kscreen       # wlroots is TODO
DYNAMIC_EDID=1        # virtual only; physical installs force 0
```

| Install-time variable | Default | Meaning |
|----------------------|---------|---------|
| `STREAM_MODE` | `virtual` | `virtual` or `physical` |
| `VIRT_OUTPUT` | auto | Stream connector |
| `PHYS_OUTPUT` | auto | Desktop connector on the same DRM card |
| `EDID_SOURCE` | `physical` | `physical`, `file`, or `generated` (ignored when physical mode) |
| `EDID_SOURCE_FILE` | — | Required for `EDID_SOURCE=file` |
| `EDID_IDENTITY` | `exact` | `exact`, or `virtualized` so KScreen can tell the clone apart |
| `CAPTURE` | `kms` | `kms`, or `kwin` on Sunshine with kwingrab |
| `REPLACE_EDID` | `1` | Replace an existing firmware EDID (backed up) |
| `DYNAMIC_EDID` | `1` | Mode-learning service; forced off in physical mode |
| `DRM_CARD` | auto | `cardN` when several GPUs are present |
| `BOOT_BACKEND` / `INITRAMFS_BACKEND` | auto | `limine`, `grubby`, `grub` / `mkinitcpio`, `dracut`, … |

## Uninstall

```bash
sudo ./uninstall.sh
```

Removes installer-owned scripts, units, boot fragments, and Sunshine keys that
are still installer-owned. It does not delete administrator-managed kernel
arguments or an EDID it does not own.

## Layout

```
install.sh / uninstall.sh
config/vdisplay.conf.example
scripts/
  vdisplay-up.sh / vdisplay-down.sh   global_prep_cmd pair
  vdisplay-common.sh                  KScreen, stream lease, inhibit
  monitor-watchdog.sh                 restore desktop primary when idle
  pick-mode.py                        closest KScreen mode
  generate_edid.py                    clone, inspect, append, or synthesize
  edid-regen.sh                       root-side firmware regeneration
  vdisplay-platform.sh                bootloader + initramfs backends
systemd/                              regen (system) + watchdog (user)
docs/TECHNICAL-NOTES.md
tests/                                rootless units + bwrap install smoke test
```

## Tests

```bash
bash tests/test-runtime.sh
bash tests/test-edid.sh
bash tests/test-regen.sh
bash tests/test-platform.sh
bash tests/test-install.sh    # needs bubblewrap
```

## Still TODO

wlroots backend, AMD/Intel, systemd-boot/rEFInd, upstream Sunshine `dd_*`
parity on Linux.

## References

- [EnriqueWood/sunshine-virtual-displays-support-poc](https://github.com/EnriqueWood/sunshine-virtual-displays-support-poc)
- [LizardByte/Sunshine#5266](https://github.com/LizardByte/Sunshine/issues/5266)
- [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine)
- [ClassicOldSong/Apollo](https://github.com/ClassicOldSong/Apollo)
- [CachyOS Limine boot configuration](https://wiki.cachyos.org/configuration/boot_manager_configuration/)
- [Linux firmware EDID loader](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/drm_edid_load.c)
- [NVIDIA nvidia-drm-connector.c](https://github.com/NVIDIA/open-gpu-kernel-modules/blob/main/kernel-open/nvidia-drm/nvidia-drm-connector.c)
- [Community NVIDIA virtual-display gist](https://gist.github.com/8dbf551d66f00e8156ef4dd2b2b090a0)
