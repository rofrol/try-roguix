<p align="center">
  <img src="macos/TryGuixIcon.svg" width="128" height="128" alt="Try Guix icon">
</p>

<h1 align="center">Try Guix</h1>

Run a [Guix System](https://guix.gnu.org) desktop with the
[Omarchy](https://omarchy.org) 4 look (Hyprland, its Quickshell bar, menu and
themes) as a native, hardware-accelerated app on an Apple Silicon Mac.

Try Guix packages a Guix System ARM64 disk image, a QEMU runtime using Apple's
Hypervisor Framework with VirGL/ANGLE-Metal graphics, and a small Swift/AppKit
launcher into one macOS app. The guest is built with `guix time-machine` from a
pinned, signature-verified Guix commit. The macOS side comes from
[Try Omarchy](https://github.com/omacom/try-omarchy), whose Arch Linux/Omarchy
guest this project replaces (see
[ADR 0001](docs/decisions/0001-guix-guest-on-existing-qemu-runtime.md)); its
documentation is kept in [docs/legacy-try-omarchy.md](docs/legacy-try-omarchy.md)
while the Arch code is still in the repository.

## Highlights

- Hardware-accelerated ARM64 virtualization (HVF) and VirGL graphics rendered
  by ANGLE on Metal
- Guix System booted through UEFI from a GPT disk, so `guix system
  reconfigure` and rollbacks work inside the VM; the disk grows on its own
- Hyprland 0.56.1 with Omarchy 4's configuration, shell and Tokyo Night theme,
  following the window size and HiDPI scale
- No password in the image: the first start asks for one, then the VM logs
  straight into the desktop
- Two-way text and PNG clipboard, one shared Mac folder under its own name
  (`~/Work` stays `~/Work`), Mac audio device selection, the Mac camera as
  `/dev/video42`, optional SSH, and optional Touch ID for `sudo`

## Status

The Guix guest boots from the app, keeps its disk, and every integration above
has been verified end to end through the launcher except Touch ID enrollment,
which needs a finger on the Mac. There are no release builds yet; build from
source. See [guest/guix/README.md](guest/guix/README.md) for the verified
results and what is still open (cursor handling, switching the default build
and removing the Arch builder).

## Quick start (from source)

1. On an Apple Silicon Mac with macOS 15 or newer and the Xcode command line
   tools, build the accelerated runtime: `make runtime`.
2. Build the Guix image on a Linux machine or VM with Guix (see
   [guest/guix/README.md](guest/guix/README.md#build)), copy the raw image to
   the Mac, and package it: `make guix-package GUIX_IMAGE=/path/to/image.raw`.
3. Build and open the app: `make guix-run`. It is built as
   `dist/app.noindex/Try Guix.app`.

On the first start the VM console asks for the password of the account
`guest`, twice. The desktop then starts without it; `sudo` asks for it. Every
later start goes straight to Hyprland.

The desktop is Omarchy's: **Super+Return** opens a terminal, **Super+Space**
the Omarchy menu, **Super+Alt+Space** the app launcher, **Super+W** closes a
window. Command acts as Super while the VM window is focused. Omarchy's menus
for Arch packages and updates do nothing on Guix. A VM created before the
Omarchy desktop keeps its old one; **Reset Guix** starts a new one.

## Using the Mac integrations

- **Clipboard:** copy on one side, paste on the other (text and PNG).
- **Shared folder:** choose a folder on the start menu; it appears in the guest
  as `~/<folder name>`, read and write, owned by `guest`.
- **Audio:** sound plays through the Mac; the Mac's input and output devices
  appear in PipeWire and follow the selection made in the guest.
- **Camera:** programs in the guest see the Mac camera as `/dev/video42` ("Mac
  Camera"); it turns on only while one of them reads it.
- **SSH:** add the SSH port mapping on the start menu, then
  `ssh -p 2222 guest@127.0.0.1`. `sshd` runs only while that mapping exists.
- **Touch ID for sudo:** with the VM window in front, run
  `try-guix-touch-id enable` in the guest and approve on the Mac. `sudo` then
  asks the Mac first and falls back to the password;
  `try-guix-touch-id disable` turns it off.

Processor cores, memory, networking (NAT or bridged), port forwarding and the
VM's storage location are chosen on the start menu as in Try Omarchy; see the
corresponding sections of [docs/legacy-try-omarchy.md](docs/legacy-try-omarchy.md).

## Data

The VM lives in `~/Library/Application Support/Try Guix/VM/v1/guix/`: the
verified factory image under `images/` and the VM's own disk under
`disks/current/`. Updating the app never replaces an existing VM; **Reset Guix**
on the start menu erases it and starts again from the factory image.

## The runtime

This fork moves the runtime to QEMU 11.1.1 to pick up Apple's in-hypervisor
GIC, and fixes two audio problems found along the way.

### Component versions

| Component | Upstream | This fork | Reason |
| --- | --- | --- | --- |
| QEMU | `cf3e71d8` — 10.2.50, 2026-01-13 | `c3d48b7d` — 11.1.1, 2026-08-26 | First release carrying `hw/intc/arm_gicv3_hvf.c` |
| ARM GIC | GICv2, emulated in QEMU userspace | GICv3 via Hypervisor.framework | Removes the interrupt path from the big QEMU lock |
| Render patch | startergo mega-patch, 29 files | Vendored and trimmed to 18, forward-ported | Upstream is unmaintained since 2026-01-14 and QEMU's display API moved |
| Python build deps | Host interpreter | Pinned `setuptools`, `wheel`, `pip` wheels | QEMU 11.1 builds `qemu.qmp`, and Python 3.12+ dropped `setuptools` |
| Render patch source | Downloaded from the startergo tarball | Vendored in `macos/patches/` | That tree is unmaintained since 2026-01-14; the archive is no longer fetched at all |
| Cocoa keyboard capture | Capture follows the mouse grab | Capture follows the key window | An absolute-pointing guest drops the grab as soon as virtio-tablet binds, leaking host Command chords mid-session |

### What it fixes

**Idle CPU.** QEMU emulated GICv2 in userspace under the big QEMU lock, so
every guest interrupt cost about four lock acquisitions and every IPI about
five across two vCPU threads. The cost scaled with vCPU count and was
independent of what the guest was doing.

| Measured at idle | Before | After |
| --- | --- | --- |
| QEMU | ~65% of a core | ~15% |
| `coreaudiod` attributable to the VM | 6.4% | 0.3% |
| Total | ~71% | ~15% |

The QEMU figure moved twice: the GIC work took it to ~22%, and clearing the
Cocoa GL dirty flag (below) took it to ~15%. The second measurement was taken
on a freshly booted desktop rather than the same session, so treat the split
between the two as approximate.

Under HVF, QEMU 11.1.1 also rejects GICv2 outright, so this is now the only
supported configuration rather than an optimisation.

**A host audio device held open forever.** `sdl_enable_out` only paused the
device, and QEMU links sdl2-compat over SDL3 where pausing a logical device
leaves the physical one running. The device being held was not even from
playback — `sdl_init_out` opens one at startup purely to negotiate a format,
and nothing released it. The host resampled silence for the life of the VM.
Microphone capture is stricter: its initial device open is deferred until an
guest application actually records, and the device is closed again when the
guest capture stream stops. The first recording may therefore take one device
open longer to begin, but merely launching Try Guix does not activate the
Mac microphone.

**An unconditional re-render every refresh tick.** The vendored
GPU-resolution patch cleared `gl_dirty` inside an `if (cocoa_gl_trace_enabled())`
block, so in a normal build the flag was never cleared: it latched true on the
first damage and `cocoa_gl_refresh` then blitted the scanout on every tick for
the life of the VM, whether or not anything had changed. The clear now sits at
function scope, where its own comment says it belongs.

**Audio dropouts.** PipeWire reported continuous xruns on a ring 682 ms deep,
with the guest driver using 17 us against a 42 ms deadline. QEMU advances the
emulated Intel HDA DMA position from a 100 Hz timer, so the counter moves in
coarse jumps and ALSA concludes it has missed. Raising the guest's quantum
gives the emulated counter fewer and larger checks to satisfy. A deeper SDL
buffer made this worse, and raising the QEMU main loop to
`QOS_CLASS_USER_INTERACTIVE` changed nothing, which rules out both buffer
depth and priority inversion.

### Graphics chain

Rendering reaches the GPU through Metal, but nothing in QEMU speaks Metal.
virglrenderer replays the guest's commands as OpenGL ES, and ANGLE translates
those into Metal, which is why the display is started with `gl=es`.

```
Hyprland
  |  OpenGL
  v
Mesa virgl driver                       guest
  |  command stream
  v
virtio-gpu-gl-pci  ─────────────────────────── VM boundary
  |
  v
virglrenderer                           host, replays as OpenGL ES
  |
  v
ANGLE  (libGLESv2.dylib, libEGL.dylib)  translates GL ES -> Metal
  |
  v
Metal.framework                         Apple silicon GPU
```

Two things this makes explicit. The guest sees a plain virtio GPU and needs no
Apple-specific driver. And the acceleration is real rather than a software
rasteriser: `libGLESv2.dylib` and `libEGL.dylib` link `Metal.framework`
directly, and the guest reports the renderer as
`ANGLE (Apple, ANGLE Metal Renderer: <chip>)`.

This chain is unchanged by the QEMU 11.1.1 move. That work touched the
interrupt controller and the GL scanout plumbing — how a rendered texture is
handed to the Cocoa window — not the rendering backend.

Note that the upstream tap this builds from is named
`homebrew-qemu-virgl-kosmickrisp`, but KosmicKrisp, Mesa's Vulkan-to-Metal
driver, is not part of this path.

### Not yet verified

Window resize across a HiDPI boundary, Mac output-device switching mid-session,
the shared folder, and clipboard sharing have not been exercised since the
port. The `dtc` mirror should be reverted once kernel.org returns.


## Repository layout

- `guest/guix/` — the Guix System definition, its packages and services, and
  the build, packaging and test tooling for the image
- `macos/` — the QEMU runtime build, the launcher scripts and the Swift app
- `guest/` (outside `guest/guix/`) — the Arch/Omarchy guest, kept until the
  Guix guest replaces it in the default build
- `docs/` — architecture notes and decision records
