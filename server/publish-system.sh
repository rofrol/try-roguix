#!/bin/bash
# Publish the store items of guest/guix/system.scm that neither bordeaux nor
# roguix.frolow.dev serves yet (server/README.md, "Publishing"). Run before
# guest/guix/publish-channel, so a VM updating from the channel finds every
# package on a substitute server. Needs the builder VM (guest/guix/vm-run).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
export_dir=.build/guix-validation/export
commit=$(cat guest/guix/modules/roguix/guix-commit)

guest/guix/vm-run --poll 10 "rm -f /root/roguix-system-ungrafted
guix time-machine --url=file:///root/guix.git --commit=$commit -- \
  system build --no-grafts -L /mnt/project/guest/guix/modules \
  --root=/root/roguix-system-ungrafted /mnt/project/guest/guix/system.scm > /dev/null
guix gc -R \$(readlink -f /root/roguix-system-ungrafted) > /mnt/export/ungrafted-closure.txt"

# HTTP status of each item's narinfo on bordeaux and on roguix.frolow.dev.
narinfo_status() {
  local hash
  hash=$(basename "$1" | cut -d- -f1)
  printf '%s %s %s\n' \
    "$(curl -s -o /dev/null -w '%{http_code}' "https://bordeaux.guix.gnu.org/$hash.narinfo")" \
    "$(curl -s -o /dev/null -w '%{http_code}' "https://roguix.frolow.dev/$hash.narinfo")" \
    "$1"
}
export -f narinfo_status
xargs -P 16 -I{} bash -c 'narinfo_status "$1"' _ {} \
  < "$export_dir/ungrafted-closure.txt" > "$export_dir/closure-status.txt"
awk '$1 != 200 && $2 != 200 { print $3 }' "$export_dir/closure-status.txt" > "$export_dir/publish.txt"
awk '$1 == 200 && $2 != 200 { print $3 }' "$export_dir/closure-status.txt" > "$export_dir/vps-fetch.txt"
echo "to publish: $(wc -l < "$export_dir/publish.txt"), VPS fetches: $(wc -l < "$export_dir/vps-fetch.txt")"
if [[ ! -s $export_dir/publish.txt ]]; then
  echo "publish-system: nothing to publish"
  exit 0
fi

guest/guix/vm-run --poll 5 'cd /mnt/export && guix archive --export $(cat publish.txt) | zstd -T4 -12 -q > roguix.nar.zst'
server/publish.sh "$export_dir"
xargs -P 16 -I{} bash -c 'narinfo_status "$1"' _ {} < "$export_dir/publish.txt" |
  awk '{ print "served by roguix: " $2 }' | sort | uniq -c
rm -f "$export_dir/roguix.nar.zst"
