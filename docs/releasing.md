# Releasing

Releases are Apple Silicon-only and require macOS 15 or newer.

## Build and verify

```sh
make doctor
make test
make guix-package GUIX_IMAGE=/path/to/roguix-image.raw
make build
# Choose the next version and tag the clean commit being packaged.
git tag -a vX.Y.Z -m "vX.Y.Z"
make package
```

Replace `vX.Y.Z` with the intended release version. Both `make package` and
`make release` require a clean checkout, including untracked files, with an
exact `vX.Y.Z` tag on HEAD. Neither command selects the next version or checks
whether that version has already been published. Ignored build output does
not make the checkout dirty.

After verifying the DMG, push the tag with `git push origin vX.Y.Z`, then create
the GitHub release manually using that existing tag and attach
`dist/TryRoguix.dmg`. Packaging does not create tags or publish GitHub releases.

The Roguix image is built with the pinned Guix in a Guix System builder
(`guest/guix/README.md`). When the release updates Omarchy itself, follow
"Updating Omarchy" in `CONTRIBUTING.md` first, and publish the release's
Roguix packages to `roguix.frolow.dev` (`server/README.md`).

Outputs are written to:

- `dist/app.noindex/Try Roguix.app`
- `dist/TryRoguix.dmg`
- `dist/guix/`

`make package` and `make release` both create distributable builds: they sign
the app and DMG with Developer ID, submit the DMG to Apple's notarization
service, and staple the resulting tickets. Neither command falls back to an
unnotarized build. Both commands first ensure the content-hashed runtime
is current and require the packaged `dist/guix` guest; packaging and signing themselves always run
freshly. Another maintainer can override the release defaults:

```sh
make release \
  RELEASE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  RELEASE_NOTARY_PROFILE=example-profile
```

## Release checklist

1. Confirm `main` is clean and all pinned inputs have reviewable provenance.
2. Run all tests and perform a first-boot provisioning test on a clean Mac user.
3. Verify networking, display scaling, keyboard/mouse, microphone and camera permission,
   on-demand FaceTime HD capture, audio-device changes, clipboard sharing in both
   directions, a shared folder read and written from both sides, persistence,
   reset, and ephemeral mode. Exercise the SSH preset with a provisioned guest:
   confirm the listener is bound only to `127.0.0.1`, normal and ephemeral TCP
   mappings to guest port 22 work, UDP port 22 does not request sshd, a normal
   restart preserves the persistent VM, and the documented endpoint-specific
   host-key recovery works after Reset/ephemeral replacement. Inspect the
   factory image to confirm it contains no SSH host private keys.
4. Install the release over a provisioned VM created by a different guest
   build. Confirm launch preserves its disk and user data and does not
   materialize or charge free space for the new factory disk. Separately
   confirm that new, reset, and ephemeral VMs use the current factory.
5. Verify the app and DMG signatures with Apple's tools and confirm notarization.
6. Audit `THIRD_PARTY_NOTICES.md`, the bundle's license material, the pinned
   Guix commit and Roguix package sources, and QEMU corresponding-source
   obligations.
7. State in release notes that installing the app preserves existing VM
   contents and that existing VMs change only through Guix inside the VM or a
   confirmed reset.
8. Record SHA-256 digests for the final app archive/DMG and publish them with the
   release notes.

Never publish generated artifacts from an unreviewed or locally modified build
input.
## macOS compatibility validation

Run `make test` and `make runtime` on macOS 15 and 26 (both covered by CI).
The runtime build runs the pinned VirGL dual-source shader
and blend-state regression tests and rejects bundled Mach-O files targeting a
version newer than 15.0 or strongly importing `strchrnul` (introduced in 15.4).
These binary checks do not replace testing on the supported operating systems.

Before publishing, boot the release app on macOS 15.0–15.3 and macOS 26. Check
desktop rendering, and test both new and existing guests. macOS 15 must
use EL1 without probing nested virtualization; on macOS 26, verify the existing
EL2 probe and fallback on supported and unsupported hardware respectively.
