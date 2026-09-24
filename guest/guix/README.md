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

On the Linux builder:

```sh
# Authenticate and evaluate with the pinned Guix before building the image:
python3 guest/guix/build.py --source /path/to/vendor/guix --check
python3 guest/guix/build.py --source /path/to/vendor/guix
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

The image carries no password. It declares one desktop account, `guest`
(UID 1000, the shared-folder owner), with the locked password `!`, and a
locked root. On the first start, `try-guix-first-boot`
(`modules/try-guix/services.scm`) switches to tty1 and asks for the account's
password twice before tty1 logs in; it sets it with `chpasswd` (SHA-512).
Guix account activation keeps a password set this way across reboots and
reconfigures, so the prompt appears only while the password is still locked.

Like the Arch guest, the VM console then logs in directly: the disk is
protected by the Mac account. tty1 auto-logs in `guest`, and
`/etc/profile.d/try-guix-session.sh` runs `start-hyprland` there only; other
consoles, the serial console and SSH get an ordinary shell. The password is
what `sudo` asks for. No display manager runs and no SSH server is enabled.

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

## Package the launcher artifact

```sh
make guix-package GUIX_IMAGE=/absolute/path/to/image.raw
```

`package.py` accepts only the exact `efi-raw` layout: a protective MBR,
identical primary and backup GPT headers with valid CRCs, partition 1 an EFI
system partition (FAT) at LBA 2048 and partition 2 an ext4 root labelled
`Guix_image`, nothing else. It writes `dist/guix/` with exactly:

- `disk.raw.zst`: the disk, compressed with the runtime's pinned `zstd`;
- `guix-manifest.json`: kind `try-guix-guest-artifacts`, boot ABI
  `uefi-gpt-v1`, the recorded partition layout, raw and compressed sizes and
  SHA-256 values, the Guix commit, a digest of the system definition files, and
  the credentials profile;
- `SHA256SUMS` for the other two files.

The directory is staged beside its target and renamed into place only after
`artifact.validate_artifacts` passes, including a full decompression that
must reproduce the raw SHA-256. An existing output is never replaced.
`systemFilesSHA256` records the definition present when packaging; the image
itself is not re-derived. The credentials profile is `first-boot`: the
image carries no password (see above).

## Ephemeral graphics smoke test on macOS

Build the existing runtime with `make runtime`. Copy the completed raw image
from Linux to the Mac, dereferencing the Guix GC-root symlink. Then run:

```sh
python3 guest/guix/run.py --image /absolute/path/to/image.raw
```

The UEFI firmware is the runtime's own
`share/qemu/edk2-aarch64-code.fd`: the EDK2 build committed in the pinned QEMU
source, decompressed and SHA-256-pinned by `prepare-qemu-gpu-runtime.sh` (it is
byte-identical to Homebrew QEMU's copy). No firmware is read from the system.

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

## Guest side of the persistent disk

The launcher will keep a VM's writes on its own copy of the disk and grow it
by extending the file. The guest cooperates without launcher-specific kernel
arguments:

- GRUB is installed with `grub-efi-removable-bootloader` at
  `EFI/BOOT/BOOTAA64.EFI`. EDK2 started with `-bios` keeps no UEFI variables,
  so this is the path it boots, and every `guix system reconfigure`
  reinstalls it there.
- `/` is declared by the label `Guix_image`, which the partition's ext4
  carries. The image mounts it by a derived UUID; an in-guest reconfigure of
  `/etc/try-guix/system.scm` mounts the same file system by label.
- The one-shot Shepherd service `try-guix-grow-root`
  (`modules/try-guix/services.scm`) runs after `file-systems` and `udev`. If
  more than 1 MiB lies after partition 2 of `/dev/vdX`, it relocates the
  backup GPT (`sfdisk --relocate gpt-bak-std`), extends partition 2 in place
  (`sfdisk -N 2`, keeping start, type, GUID and name), tells the kernel
  (`partx --update`) and runs `resize2fs` online. `resize2fs` runs on every
  boot, so a growth interrupted after `sfdisk` completes on the next boot.

On the first boot, `fsck.fat` repairs `.`/`..` entries in the ESP that
genimage writes; later boots find nothing to fix.

## Running through the app

```sh
make guix-app   # dist/app.noindex/Try Guix.app with the dist/guix guest
make guix-run   # build it and open it like `make run`
```

`build-app.sh` recognizes a Guix guest directory by `guix-manifest.json` and
bundles exactly `disk.raw.zst`, `guix-manifest.json` and `SHA256SUMS`, plus
`artifact.py` as `scripts/guix-artifact.py`. Its build-time validation writes
`launch.plist` with `bootABI = uefi-gpt-v1` and no `kernelCommandLine`.

`run-qemu-gpu.sh` takes the guest kind from those signed resources and checks
each kind only against its own contract: a Guix bundle must declare the UEFI
boot ABI and carry no kernel command line, and the Arch bundle must declare
none. For Guix it:

- validates the artifact (`guix-artifact.py launch-record`) when no
  `launch.plist` exists;
- selects `qemu_persistent_storage_configure_guest uefi`: the factory disk is
  materialized once to `images/<identity>.raw`, re-hashed against the
  manifest, APFS-cloned to `disks/current/disk.raw` and sparsely extended to
  24 GiB (`WORKING_DISK_BYTES`), all under the state root's `guix/`
  subdirectory, so an Arch VM in the same root is never read or reset;
- boots with `-bios runtime/share/qemu/edk2-aarch64-code.fd` instead of
  `-kernel/-initrd/-append`; there is no boot kit and no boot recovery;
- keeps every other device and the window title `Try Guix`.

### Verified 2026-09-24, Apple M1 Pro, through the app's launcher

With a test state root: the first launch materialized and verified the
12.0 GB factory disk, created the 24 GiB workspace, printed `Ready`, and the
guest grew `/` to 24G. A file written before `sudo halt` was present after a
second launch, which reused the workspace without materializing again.

### First start, verified 2026-09-24, Apple M1 Pro, macOS 27.0

On a fresh persistent copy of the image: tty1 showed the password prompt,
rejected two different entries ("The passwords differ") and asked again;
after two equal entries it set a SHA-512 hash, tty1 logged in as `guest` and
Hyprland with Foot came up. `sudo` accepted the new password, root stayed
locked (`!`), and the next boot went straight to the desktop without a prompt.

An earlier version ran `chvt 1` before prompting. On both first starts with it,
Hyprland then waited forever in `epoll_wait` right after renderer setup
(the logind session was active, but the compositor never got the seat), and
a manual VT switch away and back released it. tty1 is already the active VT
at boot, so the prompt no longer switches VTs; two fresh first starts since
went straight to the desktop.

## The Omarchy 4 desktop

`modules/try-guix/omarchy.scm` gives the desktop account the same Omarchy 4
("Quattro") desktop as the Arch guest, from the same pinned upstream commit
(`346e69e1`, tree `24ff1b25`):

- **Omarchy itself** is a package: the upstream tree under
  `share/omarchy`, its commands in `bin/`, and `/usr/share/omarchy` (the
  default `OMARCHY_PATH`) linked to it. Quickshell 0.3.1 (the Arch guest's
  version, `packages.scm`) runs its shell; JetBrainsMono Nerd Font 3.5.1, the
  `omarchy` glyph font, Liberation and Yaru provide its fonts and icons.
- **Arch assumptions** are replaced by `try-guix-omarchy-compat`: `uwsm-app`
  and `systemd-cat` run the command directly, `systemctl --user` succeeds
  without doing anything, `busctl` covers Omarchy's notification and UPower
  calls through gdbus (`test_busctl.py`), and `xdg-terminal-exec` is the Arch
  guest's (byte-identical copy).
- **The account** is seeded once, at the first desktop login, by
  `try-guix-omarchy-seed`: Omarchy's `config/` into `~/.config` (never
  overwriting), its applications, Hyprland toggles and fontconfig aliases;
  `OMARCHY_THEME_HEADLESS=1 omarchy-theme-set "Tokyo Night"`; first-run,
  user provisioning and shipped migrations marked done, since they install
  Arch packages and systemd units. An account from the pre-Omarchy image gets
  its old Try Guix `hyprland.lua` replaced.
- **The VM additions** live in `/etc/try-guix-hypr-vm.lua`, which the seed
  appends to `~/.config/hypr/monitors.lua` as the Arch guest appends its QEMU
  fragment: Hyprland's cursor is hidden when the launcher reports VirGL (Cocoa
  draws the Mac's cursor), `try-guix-display-sync` follows the window, and the
  host bridges and PipeWire start with the session.
- **Lock screen:** the shell authenticates with the PAM service
  `omarchy-lock-password`, defined with `pam_unix`.

Menus that manage Arch packages or systemd timers (updates, installing apps,
reminders) do nothing here. `gum` and `libvips` are not in this Guix, so gum
dialogs and background-picker thumbnails are missing.

Verified 2026-09-24 on a fresh image: the shell's bar (workspaces, clock,
weather, network, audio, display), the Tokyo Night background, Foot with the
theme's colours and border on Super+Return, and Omarchy's menu on
Super+Space; the full integration run through the launcher passed on the
same image.

## macOS integrations

`modules/try-guix/integrations.scm` ports the guest side of the launcher's
integrations. The host side and wire protocols are the Arch guest's,
unchanged, and the guest programs are byte-identical copies of the Arch
guest's reviewed scripts (`test_build.py` pins them); only their startup
differs.

- **Launcher settings.** The launcher passes its arguments as SMBIOS OEM
  strings (see ADR 0001); `try-guix-host-settings` writes them to
  `/run/try-guix/host-settings` in kernel command-line format. The shared
  folder script reads it through its `OMARCHY_MAC_SHARE_CMDLINE` override, the
  SSH gate directly. A
  missing or unreadable table yields an empty file, never a failed boot.
- **Shared folder.** `mac-share` (the Arch `omarchy-native-mac-share`) mounts
  the `mac` 9p tag at `/mnt/mac` from a Shepherd service that tty1's session
  waits for, and `/etc/profile.d` links `~/<Mac folder name>` at each login of
  the desktop account. Mount failures are logged and never block the session.
- **Clipboard.** `clipboard-bridge` runs under `try-guix-agent`, which Hyprland
  starts: it keeps the bridge running while the session's Wayland socket and
  the `dev.tryomarchy.clipboard` port exist and restarts it 2 s after it
  exits, as the Arch unit's `Restart=` does. A udev rule gives the port to the
  `users` group, mode 0660. `wl-clipboard` is installed system-wide.
- **Audio.** Sound itself flows through QEMU's intel-hda. Hyprland starts
  PipeWire, WirePlumber and pipewire-pulse under `try-guix-agent`, then
  `audio-bridge`, which mirrors the Mac's devices as `omarchy_host_*` remap
  endpoints through `pactl` and relays the selection. The Arch guest's graph
  quantum file is installed as `/etc/pipewire/pipewire.conf.d/`
  `90-try-omarchy-quantum.conf`, and PulseAudio's client `autospawn` is off so
  `pactl` never starts a real PulseAudio daemon. The session runs inside
  `dbus-run-session`.
- **Camera.** `v4l2loopback-linux-module` is a loadable module, loaded at boot
  with the Arch guest's options (`/dev/video42`, "Mac Camera",
  `exclusive_caps`); `camera-bridge` runs under `try-guix-agent`. udev gives
  the port and `video42` to the `video` group.
- **Touch ID for sudo.** `authentication-broker` is the Arch guest's broker,
  with only its two `/usr/bin` OpenSSL references rewritten to the store at
  build time (`test_build.py` pins both). `/etc/pam.d/sudo` always starts with
  a `sufficient` `pam_exec` rule whose gate fails at once until
  `try-guix-touch-id enable` (which runs `try-guix-touch-id-control` through
  sudo) has enrolled with the Mac and written
  `/var/lib/try-guix/touch-id-enabled`; see ADR 0001. The port is root-only,
  mode 0600, as the broker requires.
- **SSH.** `sshd` is installed with auto-start off; `try-guix-ssh-access`
  starts it for the current boot only when the settings contain exactly
  `tryomarchy.ssh_access=1`. Root login is refused; host keys live on the
  guest disk.

tty1's login also waits for Shepherd's `elogind`. Without that, an early
auto-login let `pam_elogind` D-Bus-activate a second elogind; Shepherd then
disabled its own, and `pam` and `sshd` could never start.

### Integrations, verified 2026-09-24, Apple M1 Pro, macOS 27.0

Through the app's launcher with a fresh state root, a shared Mac folder named
`Work Folder` and the `tcp:2222:22` forward: SSH logged in as `guest`; the
settings file held all three launcher arguments; `~/Work Folder` pointed at
`/mnt/mac`; a Mac file was readable in the guest and a file written by the
guest appeared on the Mac; the Mac pasteboard reached `wl-paste` and a
`wl-copy` in the guest reached `pbpaste`. With audio and camera added, the
same run found PipeWire, WirePlumber and pipewire-pulse running, the audio
bridge exposing two Mac output and two Mac input endpoints, and `/dev/video42`
named "Mac Camera" with its bridge running. Streaming the camera was not
exercised: it would switch on the Mac's camera and needs macOS permission.
With Touch ID added: `/etc/pam.d/sudo` carried the gated rule, the port was
`root 600`, sudo accepted the password, and the gate returned 1 while Touch ID
was off. Enrollment needs the owner's finger on the Mac and was not run.

### Not done yet

1. Cursor handling in the display contract.
2. The Swift app still shows Omarchy names and reads Arch workspace metrics
   for its free-space guard; `resize-vm-disk.sh` handles only the Arch disk.
3. Enroll Touch ID once by hand (`try-guix-touch-id enable` in the guest,
   with the VM window in front) to confirm the host approval path.
4. Switch the default build to Guix and remove the Arch builder once the
   above covers the required behavior.

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
