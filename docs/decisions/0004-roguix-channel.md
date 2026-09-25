# Roguix updates through a signed Guix channel

## Context

A Roguix VM reconfigures with the Roguix modules its image installed under
`/etc/roguix`. New Roguix releases (packages, integrations, menu changes)
therefore reached a VM only through a factory reset, which erases it.
`guix pull` would fetch and compile all of Guix inside the VM; the image
instead keeps the Guix that built it (`/var/guix/gcroots/roguix-guix`).

## Decision

Roguix's modules are published as the `roguix` Guix channel at
`https://github.com/rofrol/roguix-channel`, generated from `guest/guix` by
`guest/guix/publish-channel`. Every commit is signed with a key used only for
the channel (fingerprint `7D1A 8B40 0C26 0998 097F  63E5 28B8 3B16 11FA 815E`),
held in `~/.config/roguix-channel/gnupg` on the maintainer's Mac without a
passphrase so publishing can run unattended. The public key is on the
channel's `keyring` branch and `.guix-authorizations` names it; the channel
introduction is commit `bcc938512706d19de86dd8c6f50853fa80b063b8`.

In the VM, `roguix-update` fetches the channel, authenticates every commit
from the introduction with the image's own `guix git authenticate`, refuses a
channel whose `modules/roguix/guix-commit` differs from the image's, and
reconfigures `/etc/config.scm` with the channel's modules and the image's
Guix. Binaries come from `roguix.frolow.dev` as before, so a release publishes
its packages there before its channel commit.

## Alternatives

- `guix pull` with the Guix and roguix channels: the standard path, but it
  clones and compiles Guix in the VM, for hours on 8 GiB.
- Keeping factory reset as the only update: loses the VM's data.
- Channel modules inside the try-roguix repository: one source of truth, but
  every VM would clone the whole Mac app repository.

## Consequences

- Whoever holds the channel key can ship code to every Roguix VM that
  updates; it has the same weight as the substitute server's key.
  Rotating it means a new key in `.guix-authorizations`, signed by the old
  one.
- A release is: build and publish packages, then `publish-channel`.
- A new Guix pin still needs a new image until the pinned Guix itself is
  published; `roguix-update` says so rather than building Guix.
