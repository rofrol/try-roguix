# roguix.frolow.dev

The Roguix substitute server (docs/decisions/0002-roguix-substitute-server.md):
`guix publish` on a Debian 13 VPS behind nginx. It only serves; the aarch64
builder VM builds. The host also serves other sites, so `guix-publish.service`
is capped (one worker, `zstd:3`, `Nice=19`, idle I/O, one CPU, 700 MB).

## Files

- `guix-publish.service`: `/etc/systemd/system/guix-publish.service`.
- `roguix.frolow.dev.conf`: `/etc/nginx/conf.d/roguix.frolow.dev.conf`, as
  certbot left it.
- `roguix-prebake.sh`: bakes the publish cache one item at a time, so no
  guest request starts compression.

## Setup

1. `apt-get install uidmap`, then Guix with `guix-install.sh`
   (`https://guix.gnu.org/guix-install.sh`; it checks the release's signature).
2. `guix archive --generate-key`. The public key is
   `guest/guix/modules/roguix/roguix.frolow.dev.pub`; the secret key never
   leaves `/etc/guix/signing-key.sec`.
3. Install the unit and the nginx site, `nginx -t && systemctl reload nginx`,
   `systemctl enable --now guix-publish`, then
   `certbot --nginx -d roguix.frolow.dev --redirect`.
4. Authorize the builder's key: `guix archive --authorize <
   builder-signing-key.pub`.

## Publishing

Only ungrafted items: grafts are built with `#:substitutable? #f`
(`guix/grafts.scm`), so a guest never asks a server for them and grafts
locally, which copies without compiling.

In the builder VM, with the pinned Guix:

```sh
guix system build --no-grafts -L guest/guix/modules \
  --root=/root/roguix-system-ungrafted guest/guix/system.scm
guix gc -R /root/roguix-system-ungrafted > closure.txt
```

Split `closure.txt` by asking both servers for each item's `.narinfo`:
items neither serves go to `publish.txt`, items only bordeaux serves to
`vps-fetch.txt`. Then export and publish:

```sh
guix archive --export $(cat publish.txt) | zstd -T4 -12 > roguix.nar.zst
server/publish.sh EXPORT_DIR      # on the Mac; SSH settings from .env
```

`publish.sh` has the VPS substitute `vps-fetch.txt` from bordeaux (an import
needs every reference valid), import the archive, and bake the cache with
`roguix-prebake.sh`, all under `nice` and idle I/O.
