# Upstream release binaries for Omarchy apps Guix lacks

## Context

Omarchy's default applications include lazygit, lazydocker, gum, dua and
cliamp, which the pinned Guix does not package. Packaging them from source
means Go and Rust dependency trees of hundreds of modules each, to maintain
on every update. Each project publishes an aarch64 Linux release binary.

## Decision

`guest/guix/modules/roguix/apps.scm` installs those release binaries, each
pinned by URL and SHA-256. Four are statically linked. cliamp links glibc and
ALSA dynamically; patchelf breaks this Go binary, so `bin/cliamp` runs the
untouched binary through the store's loader with an explicit library path.
The builder builds them and `roguix.frolow.dev` serves them like Roguix's
other packages (decision 0002).

Not provided: Pinta (.NET), LocalSend (Flutter), Signal and Obsidian
(Electron, Obsidian non-free), and LibreOffice, which Guix packages but has
no aarch64 substitutes for (hours to build).

## Alternatives

- Building from source in the roguix modules: the Guix way, but each needs
  its whole dependency graph packaged first.
- Leaving them out: Omarchy's Disk Usage and Docker entries, its music key
  binding and scripts using gum would not work.

## Consequences

- Guests run code built by the upstream projects' CI, not by Guix, and
  signed by the Roguix server key; the SHA-256 pins make any change visible.
- Updating one is a version, URL and hash change in `apps.scm`.
- The packages are `aarch64-linux` only.
