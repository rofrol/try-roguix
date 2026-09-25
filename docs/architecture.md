# Architecture

Try Roguix packages three pieces into one macOS app:

1. A small Swift/AppKit launcher for the macOS side.
2. A patched QEMU runtime that creates and runs the virtual machine.
3. A Roguix disk image: Guix System for ARM64 with the pinned upstream Omarchy
   desktop, built by this project (`guest/guix`).

```text
Try Roguix.app
└── Swift/AppKit launcher
    └── QEMU + Apple Hypervisor Framework
        └── Roguix (Guix System, UEFI/GPT disk)
            └── Omarchy desktop on Hyprland
```

The launcher and runtime come from Try Omarchy, whose Arch Linux guest this
project replaced ([decision 0001](decisions/0001-guix-guest-on-existing-qemu-runtime.md);
the old design is recorded in [legacy-try-omarchy.md](legacy-try-omarchy.md)).

## What happens when the app opens

The Swift launcher presents a start menu on every app open. It reports optional
macOS Accessibility, Microphone, and Camera permission state, handles confirmed factory
resets, startup, shutdown, and host audio devices. It prepares a writable copy
of the Linux disk and starts QEMU. QEMU's Cocoa input layer uses the shared
Accessibility grant to capture system-wide Command chords and deliver Command
as guest Super. Swift does not replace QEMU or run the Omarchy desktop itself.

QEMU presents the hardware that Linux expects: CPUs, memory, storage, networking,
graphics, audio, keyboard, and pointer devices. Because both the Mac and the
guest are ARM64, Apple Hypervisor Framework runs the guest CPU instructions on
the Apple Silicon processor. QEMU provides the virtual devices around that CPU.

The balloon device enables free-page reporting. Linux keeps the selected RAM
capacity but reports unused ranges, which the patched HVF runtime unmaps from
the hypervisor, replaces with fresh anonymous host backing, and maps again
before acknowledging the report. This releases macOS physical memory without
waiting for host pressure. See [memory reclamation](memory-reclamation.md) for
the constraints and the disposable-VM validation command.

QEMU starts the bundled EDK2 UEFI firmware, which boots GRUB from the VM disk's
EFI system partition; GRUB boots the current Guix System generation, and
Omarchy runs inside it. The kernel, initrd and every earlier generation live
on the VM disk, so `guix system reconfigure` and `roll-back` work inside the VM
and an app update never replaces them. Graphics travel from Linux through virtio-gpu and VirGL to the
native Cocoa window. Storage, networking, audio, and input use their matching
QEMU virtual devices and host backends.

On macOS 26 or newer, before the real VM starts, the launcher asks the bundled
QEMU to create a tiny disposable HVF machine with ARM virtualization extensions
and Apple's platform GICv3. When that probe succeeds on M3 and newer Apple
Silicon, the real guest starts at EL2 and Linux exposes `/dev/kvm`; on older
chips and on macOS 15 the launcher keeps the existing platform-GIC/EL1
configuration. The launcher rejects hosts older than macOS 15 before probing
or starting QEMU. The updated VirGL renderer is source-built for macOS 15.0,
including the dual-source shader fix used by accelerated Alacritty.
The pinned QEMU 11.1.1 runtime contains the upstream HVF vGIC and
nested-virtualization implementation.

Trackpad magnification uses a dedicated indirect virtio touchpad alongside the
ordinary pointer tablet. The Cocoa bridge reconstructs two contacts from each
pinch and releases them on cancellation or focus loss; the guest disables
tapping for this gesture-only device. See [pinch zoom](pinch-zoom.md) for the
input contract, existing-guest setup, and integration validation.

Mac keyboard geometry (ANSI / ISO / JIS) is detected once per launch and
given to Cocoa. New and reset factory users also load an overlay that sets
`kb_model=applealu_*`. App upgrade applies the Cocoa swap only; existing
homes keep their current Hyprland input. See
[Mac keyboard](mac-keyboard.md).

The macOS helper opens an authenticated connection to QEMU's private,
single-client machine protocol socket before host sleep and retains that control
session through wake. Before macOS sleeps it synchronously pauses the guest
vCPUs, and after wake it resumes them only when that sleep handler observed the
pause transition. The bundled Cocoa runtime removes its in-process Pause and
Resume menu actions because they cannot participate in QMP connection
ownership. Abnormal QEMU states such as an I/O error are never overridden. This
preserves in-memory guest state across lid close while leaving safety stops
untouched.

One small host-integration channel sits beside those devices. A virtio-serial
port (`dev.tryomarchy.clipboard`) carries newline-delimited JSON between a
Swift bridge on the Mac, which watches the `NSPasteboard` change count, and a
Python agent in the Omarchy session, which uses wl-clipboard's data-control
protocol. Text and PNG payloads flow both ways; each side remembers the
fingerprint of what it last wrote so the immediate echo is dropped. The marker
is cleared as soon as the other side moves on to new content, and expires after
a couple of seconds regardless, so a genuine repeat of the same content still flows.

A separate virtio-serial port (`dev.tryomarchy.camera`) carries fixed-size
1280×720 NV12 frames from an AVFoundation bridge in the signed Mac helper. The
guest feeds those frames into an exclusive-capabilities `v4l2loopback` device,
`/dev/video42`, labeled **Mac Camera**. The guest subscribes to the loopback
driver's client-usage events and requests capture only while a Linux application
is reading the camera. Camera permission, capture failure, or device removal is
non-fatal to the VM; the launcher can restart the optional bridge without
restarting Omarchy.

A further virtio-serial port (`dev.tryomarchy.battery`) mirrors the Mac's
battery into the guest. A Swift bridge watches IOKit power sources and sends
complete JSON snapshots — percentage, charge state, AC presence, and time
estimates — on every change and every 30 seconds. A root guest agent writes
each snapshot as one line into a small DKMS `power_supply` module, which
presents `BAT0` and `ADP0` under `/sys/class/power_supply`, so UPower and the
Omarchy bar treat the VM as the laptop it runs on. The guest can only request
a refresh; nothing it sends can change Mac power state. A UPower drop-in keeps
the guest from acting on a critical battery — warnings appear, the Mac decides.
On a Mac with no internal battery the guest sees only mains power and the bar
shows nothing. See [host battery](host-battery.md) for the protocol, the sysfs
contract, and how to retrofit an existing guest without a factory reset.

A root-only authentication port
(`dev.tryomarchy.authentication`) lets the guest's `sudo` PAM policy request a
fixed-purpose macOS Touch ID prompt. Enrollment creates a non-exportable P-256
signing key in the Mac's Secure Enclave for a root-private random guest ID and
pins its public key inside that guest. The host stores the Secure Enclave's
device-bound encrypted key representation outside the Keychain, so local ad-hoc
test builds do not need a provisioned Keychain access group. Each authentication uses a new 256-bit
challenge. The host signs a
canonical payload that binds the request ID, challenge, PAM user, requesting
user, `sudo` service, interactive TTY, guest ID, signing-key ID, and a 15-second validity
window. The guest verifies that signature with OpenSSL before PAM can return
success. It never accepts an unsigned approval boolean.

The integration's binaries and root-only device rule are present in the factory
image, but the sudo PAM policy remains unchanged until the user opts in through
**Setup → Security → Touch ID for sudo**. The root control enrolls first and
atomically adds the PAM rule only after successful guest-password and Touch ID
authentication. Disable removes that exact rule before deleting guest state and
requesting deletion of the corresponding host key representation. Re-pair runs
the disable and enable transitions while preserving password fallback.

The QEMU window must be frontmost, the QEMU process identity must still match,
and the host owns both enrollment and sudo prompt text. When enabled, the PAM
module is `sufficient`: a denial, missing enrollment, unavailable bridge,
invalid signature, non-interactive request, or timeout falls through to
Omarchy's normal password authentication. This integration does not authenticate
login or screen-unlock flows, cannot bind approval to the exact sudo command
because PAM does not expose it, and is not a general guest-to-host approval
service.

When a folder is chosen on the start menu, QEMU exports it over virtio-9p with
`security_model=none`, so every host file operation runs as the Mac user and
the Mac keeps real modes and ownership. A small QEMU patch adds
`guest_owner_uid`/`guest_owner_gid` fsdev options that report the Mac user's
files as the first Omarchy account (uid/gid 1000), which makes the guest
kernel's permission checks agree with what the host will actually allow. The
guest mounts the tag at `/mnt/mac` before the display manager starts, and a
login hook links `~/<folder name>` to it; the name travels in the launcher's
SMBIOS OEM strings as `omarchy.shared_folder_name=<base64url>`.

Optional port mappings are stored as a versioned launcher preference, validated
again at every Swift-to-shell boundary, and translated into QEMU user-network
`hostfwd` rules. The host side is always bound explicitly to `127.0.0.1`; the
launcher never creates wildcard or LAN-facing listeners. TCP and UDP occupy
separate host-port namespaces, matching QEMU's socket behavior.

**Add SSH** inserts an ordinary `tcp:2222:22` mapping into that same preference;
there is no second SSH forwarding store or QEMU argument path. After the shell
parser accepts the complete mapping list, any TCP rule targeting guest port 22
also adds the fixed `tryomarchy.ssh_access=1` setting. UDP port 22 and other
guest ports do not. A guest Shepherd service consumes only that exact setting
and starts `sshd` for the current boot; `sshd` is installed with auto-start off,
so no persistent configuration changes.

SSH host keys belong to the writable guest disk. Persistent compatible VMs keep
them; Factory Reset and each ephemeral disk generate new keys. Reusing the same
Mac endpoint after either operation can require removing that endpoint from the
Mac's `known_hosts`. Loopback prevents LAN access but other local Mac processes
and users can still attempt authentication.

## The Roguix image

The guest image is built by this project with `guix time-machine` from a
pinned, signature-verified Guix commit (`guest/guix/build.py`); it is not an
official Guix or Basecamp image. The system is `try-roguix-operating-system`
in `guest/guix/modules/roguix/system.scm`: Guix's own packages, plus Roguix's
Hyprland 0.56 and Quickshell builds and the pinned upstream Omarchy tree,
installed read-only at `/usr/share/omarchy` from the store. Omarchy's Arch
assumptions are met by small compatibility commands instead of changes to its
source, apart from its menu and package helpers, which are rewritten at build
time to manage Guix packages (`guest/guix/README.md`).

The image carries no password; the first start asks for one on the console.
In the VM, `/etc/config.scm` calls the same procedure with the owner's package
list and `roguix-reconfigure` applies it with the Guix that built the image.
Roguix's own packages have no substitutes on Guix's servers, so
`https://roguix.frolow.dev` publishes them
([decision 0002](decisions/0002-roguix-substitute-server.md)).

## What this project changes

- The Swift code is a separate macOS launcher and helper.
- A few QEMU C and Objective-C files are patched before QEMU is compiled. These
  patches cover the Cocoa app identity, display behavior, graphics integration,
  host audio-device routing, and shared-folder ownership mapping. Nested
  virtualization uses QEMU's upstream Apple HVF implementation unchanged.
- The guest is Guix System. Hyprland 0.56.1 with a guarded rounded-border
  coverage patch for the VM graphics path, Aquamarine 0.14.0 and Quickshell
  0.3 are packaged in `guest/guix/modules/roguix/packages.scm` with their
  reviewed source hashes.
- The pinned Omarchy tree is packaged unchanged except for its menu, its
  package helpers and logo, rewritten at build time for Guix.

Resources can set an optional maximum virtual disk capacity. On the next
normal launch, an existing disk is sparsely extended under the workspace lock,
after validating its metadata. The native helper binds the change
to the inspected inode and original size and never shrinks the disk. APFS
allocates blocks as guest writes arrive; the configured capacity does not
reserve host space. New launcher settings default to 64 GiB, raised to the
existing capacity when larger. Blank settings preserve the current capacity.
New VMs use the selected capacity when their factory clone is prepared.

Nothing is overwritten while the app runs. The app bundle and packaged factory
disk remain unchanged. Normal user launches use one private writable disk under
`~/Library/Application Support/Try Roguix/VM/v1`. The disk metadata retains
the identity of the factory that created it. The VM boots its own firmware
path, so a new app release can launch the existing VM without decompressing,
cloning, expanding, or charging free space for its new factory disk.

The current bundled factory applies only when no persistent VM exists, after an
explicitly confirmed reset, or in ephemeral mode. Unsupported storage or boot
ABIs require a confirmed reset. Unrecognized host files are always left
untouched.

The workspace does not have to live in Application Support. The start menu can
put it in any folder the user picks, including one on an external drive, and the
launcher receives that choice as `OMARCHY_QEMU_GPU_STATE_ROOT`. The chosen
folder is used as-is: it is never restructured with a folder created inside
it, so it must already be empty (or already be a workspace Omarchy has used)
— a populated folder or a drive's top level is refused with an explanation
instead. The volume must
be APFS: the storage library clones the factory image with `cp -c` and expands
the working disk sparsely, and it serializes launches with a `lockf` advisory
lock. On exFAT the same expansion allocates the full working size immediately,
and on a network share the lock is unreliable. Both layers check independently, the app
when the folder is chosen and the shell library again at launch, because the
volume can change in between. A location change never moves the existing VM;
unrecognized host files stay untouched, as everywhere else here.

## Build layout

- `guest/guix/` defines Roguix and builds its image with a pinned Guix in a
  Guix System builder; `make guix-package` compresses it into `dist/guix`.
- `macos/` builds the Swift launcher and a patched QEMU runtime. The runtime is
  isolated, relocated, and signed before it enters the app bundle.
- `dist/` is the only public output directory. It is generated and ignored by
  Git.

## Trust model

The app validates the bundled factory's exact file set, JSON schemas, hashes,
sizes, boot ABI and architecture. The app also verifies the app signature and required QEMU features.
Updates to a pinned dependency should update its digest, contract tests,
notices, and review evidence together.

App releases and guest updates are deliberately separate channels. Reusing a
disk never imports a newer app's factory image; the VM changes only through
Guix (`roguix-pkg`, `roguix-reconfigure`, roll-back) or a confirmed reset.
