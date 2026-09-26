# Releasing Try Roguix

Try Roguix changes reach people in two ways, and a change decides which one
it needs:

- **Channel publish** (`guest/guix/publish-channel`, after publishing the
  packages on roguix.frolow.dev; see `server/README.md`): anything a running
  VM can pick up with `roguix-update`, such as guest packages, services,
  Omarchy's desktop and Roguix's own guest commands. Existing VMs get it
  without a new app.
- **App release** (this page): the Mac app, its QEMU runtime, the launcher
  and its settings passed to the guest, and the factory image that new and
  reset VMs start from. A new app never replaces an existing VM's disk.

A change on both sides publishes the channel first, so a new app never
meets a guest without its half.

## Versions and tags

Try Roguix releases are tagged `vX.Y.Z`, independently of the three
upstreams it carries. The Mac app's `CFBundleShortVersionString` comes from
that tag (`scripts/app_version.py`) and must be three integers, and the
update checker (`AppRelease.swift`) only accepts such tags with a
`TryRoguix.dmg` asset, on a published release that is not marked as a
prerelease. The first Try Roguix release is `v0.5.0`: `v0.1.0` to `v0.4.1`
were Try Omarchy's.

Upstream's tags are kept under `try-omarchy/` so `v*` stays Try Roguix's:

```sh
git config remote.upstream.tagOpt --no-tags
git config --add remote.upstream.fetch '+refs/tags/*:refs/tags/try-omarchy/*'
```

Each build records its upstreams in `Info.plist` (`RoguixTryOmarchyBase`,
`RoguixOmarchyVersion`, `RoguixGuixCommit`), and the updates window shows
them. Release titles name them too, for example
"Try Roguix 0.5.0 (Try Omarchy v0.4.1+33, Omarchy 4.0.4, Guix 7e74121a)".

## The factory image

The compressed factory disk (about 3 GB) does not fit a GitHub release
asset, which is limited to 2 GiB. A release app is built without it
(`macos/build-app.sh --download-disk-from URL`) and downloads it from its
own release's assets the first time it creates a VM: the parts
`disk.raw.zst.00`, `disk.raw.zst.01`, ... are appended in order and must
match the size and SHA-256 that the app's signed `launch.plist` pins before
they are expanded. Development builds (`make app`) still bundle the disk.

## Signing

The maintainer has no Developer ID yet, so releases are signed ad hoc and
not notarized. The release notes say so, publish checksums, and tell people
to open the app with **System Settings > Privacy & Security > Open Anyway**
after the first attempt; never to turn Gatekeeper off.

## Steps

1. Publish the release's guest packages and channel (above).
2. Build and package the factory image (`guest/guix/README.md`,
   `make guix-package GUIX_IMAGE=...`) from the commit being released.
3. `make test`.
4. Tag the release commit: `git tag -a v0.5.0 -m "Try Roguix 0.5.0"`.
5. `macos/release.sh`: `TryRoguix.dmg`, the disk parts and `SHA256SUMS` in
   `dist/release`.
6. Push the tag and create the release as a prerelease with all of
   `dist/release/*`; prerelease assets are already downloadable.
7. Install `TryRoguix.dmg` on a clean account and launch it: the disk
   downloads, expands and boots, the first-start setup runs, and the
   updates window names the upstreams.
8. Clear the prerelease flag so `releases/latest`, and so the app's update
   checker, finds it.
