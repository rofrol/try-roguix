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

## Publishing a pin

In the builder VM, with the pinned Guix:

```sh
guix gc -R GRAFTED-SYSTEM UNGRAFTED-SYSTEM | sort -u > closure.txt
# keep the items bordeaux.guix.gnu.org has no narinfo for: missing.txt
guix archive --export -r $(cat missing.txt) | zstd -T4 -12 > roguix.nar.zst
```

On the VPS: `zstd -dc roguix.nar.zst | guix archive --import`, then
`nice -n 19 ./roguix-prebake.sh HASHES` with the missing items' hashes.
