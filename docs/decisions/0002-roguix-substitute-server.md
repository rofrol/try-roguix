# Roguix substitute server at roguix.frolow.dev

## Context

Roguix packages Hyprland 0.56, Quickshell, Omarchy and the VM agents itself.
Guix's substitute servers do not build them, so any Guix whose derivations
differ from the image's (a later pin, a reconfigure that grafts again) would
compile Hyprland and Quickshell in the VM, for hours. The image already keeps
the ungrafted system as a GC root for the pinned Guix, but updates need
binaries from somewhere the guest trusts.

## Decision

The author's VPS publishes Roguix's store items at `https://roguix.frolow.dev`:
Guix 1.5.0 from `guix-install.sh` on Debian 13, `guix publish` on
`127.0.0.1:8181` with a zstd cache in `/var/cache/guix/publish`, nginx and a
Let's Encrypt certificate in front, as the host's other sites. The VPS
(x86_64, 2 CPUs, 2.4 GB) only serves: the aarch64 builder VM builds, exports
the items Guix's servers lack with their closure (`guix archive --export -r`),
and the VPS imports them (the builder's key is in the VPS's `/etc/guix/acl`).

The host also serves other sites. The first setup compressed at `zstd:19`
on demand; a guest's reconfigure asked for many uncached items and the host
stopped responding for 15 minutes until a reboot. `guix publish` now runs
with one worker at `zstd:3` under `Nice=19`, idle I/O, one CPU and 700 MB,
and `server/roguix-prebake.sh` fills its cache ahead of guests
(`server/README.md`).

The guest adds the URL after Guix's own servers and authorizes the server's
public key, `guest/guix/modules/roguix/roguix.frolow.dev.pub`. The private key
exists only on the VPS.

## Alternatives

- Building on the VPS: aarch64 through QEMU emulation on 2 CPUs and 2.4 GB
  would take days per Hyprland build and likely run out of memory.
- Shipping every grafting input in the image: several GB more per download,
  and no path for updates.
- Disabling grafts: fast, but drops Guix's security fixes applied as grafts.

## Consequences

- Every guest trusts binaries signed by the VPS key; whoever holds
  `/etc/guix/signing-key.sec` there can serve code to all Roguix VMs.
  Rotating it needs a new image or a reconfigure with the new key.
- A Guix pin moves only after the builder has built and uploaded that pin's
  Roguix packages.
- The server is a single point of failure for updates, not for running VMs;
  without it the guest falls back to building.
- Serving is direct from the VPS for now: guests fetch only Roguix's own
  items from it. Put it behind a CDN (Cloudflare proxy with long caching for
  `/nar/*`, short for `*.narinfo`) when the VPS's transfer allowance or
  distant download speed becomes the limit; signatures make the transport
  untrusted either way.
