#!/bin/bash
# Publish Roguix store items on roguix.frolow.dev (server/README.md).
# Usage: server/publish.sh EXPORT_DIR
#
# EXPORT_DIR holds what the builder prepared:
#   roguix.nar.zst  `guix archive --export` of the items in publish.txt
#   publish.txt     ungrafted items neither bordeaux nor the VPS serves
#   vps-fetch.txt   their references the VPS lacks but bordeaux serves
# The VPS substitutes vps-fetch.txt from bordeaux first, because
# `guix archive --import` needs every reference to be valid, then imports
# and bakes the publish cache. SSH settings come from .env (.env.example).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export_dir=$(cd "${1:?usage: server/publish.sh EXPORT_DIR}" && pwd)
set -a && . "$root/.env" && set +a
remote() { ssh -o BatchMode=yes -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "$@"; }

sed 's|/gnu/store/\([a-z0-9]*\)-.*|\1|' "$export_dir/publish.txt" \
  > "$export_dir/publish-hashes.txt"
rsync -a --partial -e "ssh -p $SSH_PORT" \
  "$export_dir/roguix.nar.zst" "$export_dir/vps-fetch.txt" \
  "$export_dir/publish-hashes.txt" "$root/server/roguix-prebake.sh" \
  "$SSH_USER@$SSH_HOST:/root/"
remote 'bash -s' <<'EOF'
set -euo pipefail
cd /root
if [ -s vps-fetch.txt ]; then
  nice -n 19 ionice -c3 guix build \
    --substitute-urls=https://bordeaux.guix.gnu.org $(cat vps-fetch.txt) \
    > /dev/null
fi
zstd -dc roguix.nar.zst | nice -n 19 ionice -c3 guix archive --import
# Items the server could not bake print with their HTTP status.
nice -n 19 ./roguix-prebake.sh publish-hashes.txt | grep -v ' 200$' || true
df -h / | tail -1
EOF
echo "published $(wc -l < "$export_dir/publish.txt") items"
