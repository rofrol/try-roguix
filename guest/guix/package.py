#!/usr/bin/env python3
"""Package a built Guix EFI disk image as the launcher's guest artifact.

The raw image comes from build.py on a Linux Guix host (dereference its GC-root
symlink when copying it to the Mac). The output directory holds exactly
disk.raw.zst, guix-manifest.json and SHA256SUMS; it is written beside the
target and renamed into place only after a full validation, decompression
included.
"""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile

import artifact


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ZSTD = ROOT / "macos/.build/qemu-gpu-runtime/bin/zstd"
# The files that define the system; the same set the image installs under
# /etc/try-guix (see try-guix-source? in system.scm).
SYSTEM_FILES = (
    "system.scm",
    "hyprland.lua",
    "modules/try-guix/packages.scm",
    "modules/try-guix/display-sync",
    "modules/try-guix/hyprland-rounded-border-coverage.patch",
)


def guix_commit():
    spec = importlib.util.spec_from_file_location("guix_image_build", HERE / "build.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.COMMIT


def system_files_sha256(base=HERE):
    """Digest of the system definition, recorded as the packager declares it."""
    digest = hashlib.sha256()
    for name in SYSTEM_FILES:
        digest.update(f"{name}\0{artifact.sha256_file(base / name)}\n".encode())
    return digest.hexdigest()


def package(image, output, zstd, credentials):
    image = Path(image).resolve(strict=True)
    output = Path(output).absolute()
    if os.path.lexists(output):
        raise artifact.ArtifactError(f"output already exists; choose a new --output: {output}")
    if not Path(zstd).is_file():
        raise artifact.ArtifactError(f"zstd is missing; run `make runtime`: {zstd}")
    layout = artifact.inspect_disk(image)
    output.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".guix-package.", dir=output.parent))
    try:
        compressed = staging / artifact.DISK
        raw_sha256 = artifact.compress_and_hash(image, compressed, zstd)
        manifest = artifact.manifest_for(layout, raw_sha256, compressed,
                                         guix_commit(), system_files_sha256(),
                                         credentials)
        (staging / artifact.MANIFEST).write_text(artifact.canonical_json(manifest),
                                                 encoding="utf-8")
        (staging / artifact.SUMS).write_text(artifact.sums_text(staging),
                                             encoding="ascii")
        artifact.validate_artifacts(staging, zstd)
        for entry in staging.iterdir():
            entry.chmod(0o444)
        staging.chmod(0o755)  # mkdtemp creates it private
        os.rename(staging, output)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True,
                        help="raw efi-raw disk image produced by build.py")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/guix")
    parser.add_argument("--zstd", type=Path, default=ZSTD)
    parser.add_argument("--credentials", default="development-password",
                        choices=sorted(artifact.CREDENTIALS))
    args = parser.parse_args()
    try:
        manifest = package(args.image, args.output, args.zstd, args.credentials)
    except (OSError, artifact.ArtifactError) as error:
        parser.exit(1, f"guix-package: {error}\n")
    disk = manifest["disk"]
    print(f"Packaged {args.output}: {disk['bytes']} raw bytes "
          f"({disk['sha256']}), {disk['compressedBytes']} compressed")


if __name__ == "__main__":
    main()
