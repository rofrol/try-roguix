# Replace the guest with Guix while retaining the accelerated host runtime

## Context

The user wants Guix System from the local `vendor/guix` checkout, with Hyprland,
while retaining the Try Omarchy infrastructure responsible for running Linux
quickly on macOS. The existing guest uses Arch/pacman/systemd. Host validation,
boot-kit retention and disk growth also encode the Arch factory contract.

## Decision

Retain the Swift launcher and the patched QEMU/HVF/Virtio/VirGL/ANGLE host stack.
Replace the guest with native Guix packages and services, using the pinned local
Guix Git channel with the official introduction and commit-signature
verification. Stage the keyring ref in a disposable bare repository, keeping
the vendor checkout read-only. Do not port pacman or emulate systemd. Preserve host-integration
protocols and existing security restrictions when porting guest agents.

Begin with a separately built development Guix image, then integrate its boot
and storage contract before switching the normal application build. The first
slice is not a distributable factory or a supported alternative guest. Its
password-protected development account does not substitute for release owner
provisioning. Do not touch existing Arch VM disks as part of image development.

### Boot and storage: UEFI with a partitioned disk (decided)

The Guix factory boots through UEFI firmware and GRUB from a GPT disk (ESP plus
ext4 root), not through direct `-kernel`/`-initrd` boot. Guix selects system
generations through its bootloader, so `guix system reconfigure` and rollback
keep working inside the guest without a host-side copy of a generation's kernel,
initrd and store-path command line that could go stale or be garbage-collected.
Consequently the launcher needs a separate, equally strict Guix validation
profile (trusted AArch64 firmware, partition layout, identities, hashes, sizes,
provenance) and real GPT growth (relocate the backup header, grow the root
partition, then ext4), never the Arch truncate-only path. Guix workspaces use a
distinct ABI; existing Arch workspaces are left untouched and reported
incompatible, with deletion only behind a confirmed reset. The Arch boot-kit
recovery mechanism is not reused.

### Launcher settings: SMBIOS OEM strings (decided)

The Arch guest learns its launcher-owned settings (`omarchy.qemu_virgl=1`,
`omarchy.shared_folder_name=<base64url>`, `tryomarchy.ssh_access=1`) from the
kernel command line. A UEFI guest boots its own GRUB, so the launcher passes
the same `name=value` strings as SMBIOS type 11 OEM strings (`-smbios
type=11,value=...`); EDK2 publishes them and the guest reads
`/sys/firmware/dmi/entries/11-*/raw` as root at boot, keeping only values of
that exact shape, and writes them to `/run/roguix/host-settings` in the
command line's format. The authority is unchanged: only the launcher sets
them, their values are the same, and `/run` keeps them for one boot, as the
command line does. QEMU's `fw_cfg` was not used because this checkout's
linux-libre is built without `CONFIG_FW_CFG_SYSFS`; a new virtio port would
need host code for what is static boot data.

### Touch ID for sudo: a static, gated PAM rule (decided)

The Arch guest opts in by inserting its `pam_exec` rule into `/etc/pam.d/sudo`
after enrolling, and removes it before disabling. Guix generates `/etc/pam.d`
from the system configuration, so the Guix guest carries the same
`sufficient pam_exec.so quiet seteuid stdout` rule permanently, and the program
it runs is a gate that fails immediately unless
`/var/lib/roguix/touch-id-enabled` (root, 0600, in a 0700 directory) exists;
only then does it run the broker. `roguix-touch-id-control enable` enrolls
with the host before writing that marker, and `disable` removes the marker
before revoking. Until the owner opts in the rule has no effect, and afterwards
any failure still falls back to the password, so the authority and fallback
match the Arch guest; the difference is that the rule is visible in
`/etc/pam.d/sudo` while inert. The broker is the Arch guest's, with only its
two `/usr/bin` OpenSSL references pointed at the store.

## Alternatives

- Direct kernel/initrd boot of an unpartitioned root: smaller launcher change,
  but it requires repacking Guix's gzip initrd and a generation-aware export on
  every reconfigure, and it breaks Guix's own generation switching. Rejected.

- Install Guix atop Arch: does not replace the guest OS and retains two package
  and service models.
- Replace QEMU/the macOS launcher with a generic VM frontend: loses the requested
  accelerated runtime and existing integrations.
- Label a Guix disk as an Arch artifact or weaken validation: violates boot,
  storage and provenance assumptions and risks existing data.

## Consequences

Host acceleration work remains reusable, but guest performance still requires
measurement. Native Guix packaging avoids carrying Arch's ABI pins and systemd
units. A Guix boot/storage contract, first-boot provisioning and guest-agent
ports are required before the app can honestly be called migrated. Once these
are verified, switch the existing build entry points and remove obsolete Arch
code rather than keeping dual-distribution support. Any migration of existing
user disks or changes to integration authority require a separate decision.
