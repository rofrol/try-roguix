# Guix guest migration: image build slice

This is the first slice of replacing the Arch/Omarchy guest with Guix System and
Hyprland. The macOS launcher, patched QEMU, HVF, Virtio/VirGL and ANGLE/Metal
remain the intended host stack. The image has been built and booted once with
acceleration (see below); it is not yet connected to the launcher, is not a
supported guest, and does not yet reproduce the Omarchy desktop or its host
integrations. This does not add a second supported guest or an Arch
compatibility layer.

## Build

Use an ARM64 Linux machine with Guix, Git, Python 3 and a running
`guix-daemon`. Keep the source on the builder's native filesystem; fetching the
full Git history directly over a 9p host share is unnecessarily slow.
The source defaults to `../../../vendor/guix` relative to this directory
(`~/personal_projects/guix/vendor/guix` in the original checkout). The builder
uses that repository as a local Git channel, pinned to
`7e74121a40a8308166e328a23647cf6f3768e6c8`, via `guix time-machine`.
Tracked modifications and a different HEAD are rejected; untracked files are
not inputs to a Git channel. The checkout must include `origin/keyring`, as the
supplied vendor checkout does. A temporary bare Git repository exposes that ref
as the channel's `keyring` branch without modifying the vendor checkout or
copying its object database. The channel inherits the official Guix introduction:
Guix verifies commit signatures, not only the requested hash. Authentication is
never disabled. Guix still downloads package sources/substitutes and may build
missing packages.

From the project root, on any host, inspect the plan without starting a build:

```sh
python3 guest/guix/build.py --dry-run
```

On the Linux builder, generate a SHA-512 crypt hash for a **throwaway development
password**, for example with `openssl passwd -6` (interactive input), then:

```sh
read -r -s -p 'Development password hash: ' GUIX_GUEST_PASSWORD_HASH; echo
export GUIX_GUEST_PASSWORD_HASH
# Authenticate and evaluate with the pinned Guix before building the image:
python3 guest/guix/build.py --source /path/to/vendor/guix --check
python3 guest/guix/build.py --source /path/to/vendor/guix
unset GUIX_GUEST_PASSWORD_HASH
```

Unlike `--dry-run`, `--check` actually runs Guix and needs Linux, network access
and a daemon. It can download/build Guix itself and instantiate derivations,
but does not build the guest image or publish an output/GC root. An existing
image is left alone during checks. A failing Guix command propagates a nonzero
exit status, and the temporary channel repository is removed on either outcome.

A raw EFI image of this size plus the Guix store and build outputs needs more
room than the image itself: reserve well over 40 GiB of free space on the
builder, and expect the final `disk-image` derivation to need several GiB of
headroom. A build that runs out of space during that last derivation fails with
a `No space left on device` backtrace while copying the image into the store.

A Guix System VM can serve as the builder. Do not fetch the vendor checkout
over a 9p share: copy or clone it onto the builder's own filesystem first, and
set `safe.directory` if the copy is owned by another user.

The default output `dist/guix/image.raw` is a Guix GC-root symlink to a 12 GiB
raw EFI disk image, not an unpartitioned ext4 filesystem. Copy the image, not
just the symlink, when transferring it to macOS. An existing output, including
a dangling symlink, is refused rather than replaced. Choose another `--output`
for another build. The builder never opens existing VM workspaces.

This development image has a `guest` account (UID 1000) with the supplied
password and ordinary password-authenticated sudo. Root password login is
locked; neither autologin nor an SSH server is enabled. The password hash is
part of the world-readable Guix store closure: **do not reuse a real password
or distribute this development image**. Release-quality first-boot owner
provisioning is still to be designed before packaging a public factory.

SDDM provides login into the packaged Hyprland Wayland session. Guix installs
`hyprland.lua` through the account skeleton for newly created users. It starts
Foot and binds Super+Q to Foot, Super+R to Wofi, Super+C to close, and Super+M to
end the session, using Hyprland's standard navigation and workspace bindings.
Existing user configuration is not overwritten by this skeleton mechanism.

Foot avoids the separate Kitty OpenGL-context problem documented by the old
Arch guest's `native-overlay/usr/local/bin/kitty` wrapper. Kitty and its
software-rendering exception are not part of this image. No compositor
software-rendering override or version-specific Arch Hyprland patch is carried
over. Fonts and Mesa diagnostic tools are also installed.

The pinned checkout packages Hyprland 0.55.4 with Aquamarine 0.12.1, which
cannot follow window resizes (see below). `modules/try-guix/packages.scm`
therefore defines Hyprland 0.56.1 and Aquamarine 0.14.0, the known-good Arch
guest pair, built without systemd/UWSM like the upstream package. Notes:

- Hyprland 0.56 needs a newer C++ toolchain than the default GCC 14. This
  checkout's aarch64 `gcc-16.2.0` substitute ships a libstdc++ configured
  without C99 math (`_GLIBCXX11_USE_C99_MATH` undefined, so even
  `std::signbit` is missing), so the package uses `gcc-toolchain-15`. Its one
  gap, a single C++23 `std::ranges::starts_with` call, is rewritten to the
  C++20 equivalent in an origin snippet.
- The module is project code outside Guix's channel authentication; review it
  like any other source. `build.py` passes it with `--load-path`, and the image
  installs a copy under `/etc/try-guix` so an in-guest `guix system
  reconfigure` keeps these versions instead of reverting to 0.55.4.

## Ephemeral graphics smoke test on macOS

Build the existing runtime with `make runtime`. Copy the completed raw image
from Linux to the Mac, dereferencing the Guix GC-root symlink. Then run:

```sh
python3 guest/guix/run.py \
  --image /absolute/path/to/image.raw \
  --firmware /absolute/path/to/edk2-aarch64-code.fd
```

For an existing Homebrew QEMU installation, the firmware is normally at
`$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd`. Firmware is executable
input: supply it from a trusted source. It is **not** bundled or downloaded by
this development harness, and is not a new release dependency.

`run.py` uses only the project's signed QEMU runtime, HVF, Virtio GPU with
VirGL, and the Cocoa GLES/ANGLE path. It does not fall back to a system QEMU or
software CPU emulation. QEMU's `-snapshot` keeps all writes in a disposable
overlay: shutdown discards guest changes and leaves the supplied image intact.
There is no host filesystem share, port forwarding, microphone/camera capture,
clipboard bridge or system-wide keyboard grab in this smoke test. Guest outbound
network access uses QEMU's existing user-mode networking. `--dry-run` prints the
command without opening files or starting QEMU.

Log into the Hyprland session as `guest` using the build-time development
password. A successful build alone establishes nothing about the guest.

### Verified once, 2026-09-17, Apple M1 Pro, macOS 26.5.2

Image `aaf789447a3925fe119fcd030baf9a7ff83ea66cac96b9ef5aa8f4d88c5d0481`,
built from Guix `7e74121a`, ran on this runtime with these observations:

- The guest booted to SDDM, accepted the development password, and started the
  packaged Hyprland session. Foot opened from the autostart entry.
- GPU acceleration was real, not software. The host reported
  `ANGLE (Apple, ANGLE Metal Renderer: Apple M1 Pro)`, the guest reported
  `Renderer: virgl` and `glamor X acceleration enabled on virgl`, and
  `Mesa 26.0.2` was the user-space driver. `llvmpipe` did not appear.
- Keyboard and pointer input reached the guest through virtio. Typing in Foot
  created a file, and Super+R opened Wofi with desktop entries.
- `halt` shut the guest down; QEMU's `-action shutdown=poweroff` ended the
  process. The image SHA-256 was identical afterwards, confirming the
  `-snapshot` isolation.

### Window resizes, verified 2026-09-24, Apple M1 Pro, macOS 26.5.2

Image `e0dc1a159133e9da30c934d1127244a0fb780c68fb68b352d68838e4f123349d`
(Hyprland 0.56.1, Aquamarine 0.14.0, same Guix `7e74121a`):

- `hyprctl systeminfo` reported Hyprland 0.56.1 built against hyprutils 0.14.2
  and Aquamarine 0.14.0; the guest log still showed `Renderer: virgl` and the
  host ANGLE Metal Renderer.
- `try-guix-display-sync` ran from the session. Resizing the QEMU window
  through the macOS accessibility API changed the guest mode each time, at
  scale 2: 1200x760 pt (clamped by macOS to 1187x700) gave `2374x1336`,
  700x450 gave `1400x788`, and growing again gave `2374x1336`. Foot followed
  the new size. Shrinking and growing past the boot mode both worked.
- `halt` ended QEMU and the image SHA-256 was unchanged.

With 0.55.4/0.12.1 (image `aaf78944…`, probed 2026-09-23) every mode larger
than the current one failed: atomic test commits returned `Invalid argument`,
and with `AQ_NO_ATOMIC=1` the log showed `drmModeSetCrtc failed: No space left
on device`, i.e. a modeset with the old, smaller framebuffer. Runtime rules and
config reloads did not help. Cursor handling is still unverified.

## Not connected to the launcher yet

`make guest`, `make build` and the app still use the original Arch pipeline.
**Do not put this image in `dist/guest` or rename it to `rootfs.ext4`.** The
launcher currently checks an Omarchy-specific manifest and direct-boot ABI;
its disk growth code assumes an unpartitioned ext4 filesystem. Disabling those
checks or passing it a partitioned Guix disk would not be a safe migration.

Remaining slices:

1. Publish the display contract: resize and mode changes are verified above;
   decide on and verify cursor handling.
2. Integrate Guix's boot artifacts, provenance, validation and disk layout with
   the host launcher/storage contract. Isolate Guix state from existing Arch
   disks; do not migrate or delete user data implicitly.
3. Port shared folders, clipboard, audio, camera, optional SSH and opt-in
   Touch ID to Guix services while preserving their host protocols and
   security policies. None is claimed functional by this initial definition.
4. Switch the existing build entry points and remove the Arch builder,
   Omarchy package pins, overlays and obsolete tests once the replacement
   covers required behavior. Fold this temporary build entry point into the
   normal `guest` build at that cutover; do not retain parallel guest support.

## Local checks

```sh
PYTHONDONTWRITEBYTECODE=1 python3 guest/guix/test_build.py
PYTHONDONTWRITEBYTECODE=1 python3 guest/guix/test_run.py
python3 guest/guix/build.py --dry-run
```

These check build planning, pin enforcement, no-overwrite behavior and failure
propagation. A real temporary Git repository test verifies that the keyring is
exported without modifying source refs or tracked files. These tests also run
through `make test`. Smoke-launcher tests check explicit acceleration, ephemeral
storage, filename escaping, signature failure, and the absence of host access
channels. These tests do not evaluate the Guix system or boot a VM; `--check`
is the separate Linux integration check.
