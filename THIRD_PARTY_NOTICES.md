# Third-party notices

Try Roguix builds and redistributes third-party components under their own
licenses. The repository's MIT license applies only to this project's original
code.

- **Omarchy** — pinned from `basecamp/omarchy`; MIT. The package in
  `guest/guix/modules/roguix/omarchy.scm` installs its tree, including its
  license, at `/usr/share/omarchy` in the guest.
- **QEMU** — GPL-2.0 and other component licenses. Release maintainers must
  provide the corresponding source and notices required by the exact bundled
  build.
- **GNU Guix and Guix System packages** — each package retains its own license;
  the guest's store keeps every package's license and source identity. The
  pinned Guix commit is in `guest/guix/README.md`.
- **Hyprland** — BSD-3-Clause; the reviewed v0.56.1 source and rounded-border
  coverage backport are pinned in `guest/guix/modules/roguix/packages.scm`.
- **aquamarine** — BSD-3-Clause; the reviewed v0.14.0 source is pinned in
  `guest/guix/modules/roguix/packages.scm`.
- **Quickshell** — LGPL-3.0; the reviewed v0.3.1 source is pinned in
  `guest/guix/modules/roguix/packages.scm`.
- **JetBrains Mono Nerd Font** — OFL-1.1; the reviewed 3.5.1 release is pinned
  in `guest/guix/modules/roguix/omarchy.scm`.
- **ANGLE, VirGLRenderer, libepoxy, SDL, libslirp, GLib, Pixman, and other QEMU
  dependencies** — retain their respective upstream licenses.

See `guest/guix/modules/roguix/` and `macos/build-qemu-gpu-runtime.sh` for exact
source identities and checksums. Before distributing a release, follow
`docs/releasing.md` and audit the assembled bundle's notices and
corresponding-source obligations.
