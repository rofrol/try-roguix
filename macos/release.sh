#!/bin/bash
# Build the release assets for the Try Roguix release tagged at HEAD
# (docs/releasing.md): TryRoguix.dmg without the disk, the compressed disk in
# parts below GitHub's 2 GiB asset limit, and SHA256SUMS, in dist/release.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"

python3 scripts/app_version.py --root "$root" --require-release
tag=$(git describe --exact-match --tags --match 'v[0-9]*' HEAD)
[[ -f dist/guix/guix-manifest.json && -f dist/guix/disk.raw.zst ]] || {
  echo "release: package the factory image first (make guix-package)" >&2
  exit 1
}

macos/build-app.sh --dmg \
  --download-disk-from "https://github.com/rofrol/try-roguix/releases/download/$tag/"
app="dist/app.noindex/Try Roguix.app"
part_bytes=$(/usr/bin/plutil -extract diskDownloadPartBytes raw \
  "$app/Contents/Resources/guest/launch.plist")

out=dist/release
rm -rf "$out"
mkdir -p "$out"
cp -c dist/TryRoguix.dmg "$out/TryRoguix.dmg"
# The app downloads disk.raw.zst.00, .01, ... and appends them in order.
split -b "$part_bytes" -a 2 -d dist/guix/disk.raw.zst "$out/disk.raw.zst."
(cd "$out" && shasum -a 256 TryRoguix.dmg disk.raw.zst.* > SHA256SUMS)
ls -l "$out"
echo "release: assets for $tag are in $out"
