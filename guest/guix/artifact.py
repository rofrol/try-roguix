"""The Guix guest artifact: a zstd-compressed UEFI/GPT disk plus its manifest.

`inspect_disk` accepts only the exact layout `guix system image
--image-type=efi-raw` produces: a protective MBR, matching primary and backup
GPT headers, an EFI system partition (FAT) and one ext4 root partition labelled
ROOT_LABEL. `validate_artifacts` checks a packaged directory as strictly as the
launcher checks the Arch guest: exact file set, exact manifest keys, and every
checksum.
"""

import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import uuid
import zlib


SECTOR = 512
ESP_TYPE = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
LINUX_FS_TYPE = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")
# `guix system image` labels the root partition and file system with this.
ROOT_LABEL = "Guix_image"
ESP_FIRST_LBA = 2048
GPT_ENTRIES = 128
GPT_ENTRY_SIZE = 128
GPT_ENTRY_SECTORS = GPT_ENTRIES * GPT_ENTRY_SIZE // SECTOR

KIND = "roguix-guest-artifacts"
BOOT_ABI = "uefi-gpt-v1"
DISK = "disk.raw.zst"
MANIFEST = "guix-manifest.json"
SUMS = "SHA256SUMS"
FILES = frozenset({DISK, MANIFEST, SUMS})
# The image carries no password: roguix-first-boot asks for one on the first
# start (modules/roguix/services.scm).
CREDENTIALS = frozenset({"first-boot"})
ZSTD_MAGIC = bytes.fromhex("28b52ffd")
# The persistent workspace the launcher creates; the guest grows its root
# partition into the difference (roguix-grow-root). Matches the Arch guest's
# expandedSizeMiB.
WORKING_DISK_BYTES = 24576 << 20
CHUNK = 8 << 20


class ArtifactError(ValueError):
    pass


def _read(stream, offset, length):
    stream.seek(offset)
    data = stream.read(length)
    if len(data) != length:
        raise ArtifactError(f"disk is truncated at byte {offset}")
    return data


def _gpt_header(stream, lba, total_sectors):
    raw = _read(stream, lba * SECTOR, 92)
    (signature, revision, size, crc, reserved, current, backup, first_usable,
     last_usable, disk_guid, entries_lba, count, entry_size,
     entries_crc) = struct.unpack("<8sIIIIQQQQ16sQIII", raw)
    if signature != b"EFI PART" or revision != 0x10000 or size != 92 or reserved:
        raise ArtifactError(f"invalid GPT header at LBA {lba}")
    if zlib.crc32(raw[:16] + b"\0\0\0\0" + raw[20:]) != crc:
        raise ArtifactError(f"GPT header CRC mismatch at LBA {lba}")
    last = total_sectors - 1
    expected_backup = last if lba == 1 else 1
    expected_entries = 2 if lba == 1 else last - GPT_ENTRY_SECTORS
    if (current != lba or backup != expected_backup
            or entries_lba != expected_entries
            or first_usable != 2 + GPT_ENTRY_SECTORS
            or last_usable != last - 1 - GPT_ENTRY_SECTORS
            or count != GPT_ENTRIES or entry_size != GPT_ENTRY_SIZE):
        raise ArtifactError(f"unexpected GPT geometry at LBA {lba}")
    entries = _read(stream, entries_lba * SECTOR, count * entry_size)
    if zlib.crc32(entries) != entries_crc:
        raise ArtifactError(f"GPT partition array CRC mismatch for LBA {lba}")
    return uuid.UUID(bytes_le=disk_guid), first_usable, last_usable, entries


def inspect_disk(path):
    """Return the validated layout of a raw Guix EFI disk image."""
    with open(path, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ArtifactError("disk image is not a regular file")
        size = info.st_size
        if size % SECTOR or size < (ESP_FIRST_LBA + 2 * 2048) * SECTOR:
            raise ArtifactError("disk image size is not a plausible sector count")
        total = size // SECTOR

        mbr = _read(stream, 0, SECTOR)
        first_type = mbr[446 + 4]
        first_lba = struct.unpack("<I", mbr[446 + 8:446 + 12])[0]
        if mbr[510:] != b"\x55\xaa" or first_type != 0xEE or first_lba != 1:
            raise ArtifactError("disk has no protective MBR")

        primary = _gpt_header(stream, 1, total)
        if _gpt_header(stream, total - 1, total) != primary:
            raise ArtifactError("backup GPT does not match the primary GPT")
        disk_guid, first_usable, last_usable, entries = primary

        used = []
        for index in range(GPT_ENTRIES):
            entry = entries[index * GPT_ENTRY_SIZE:(index + 1) * GPT_ENTRY_SIZE]
            if entry[:16] != bytes(16):
                used.append((index + 1, entry))
        if [index for index, _ in used] != [1, 2]:
            raise ArtifactError("disk must have exactly partitions 1 (ESP) and 2 (root)")

        partitions = []
        for (index, entry), expected_type in zip(used, (ESP_TYPE, LINUX_FS_TYPE)):
            first, last, _attributes = struct.unpack("<QQQ", entry[32:56])
            partition_type = uuid.UUID(bytes_le=entry[:16])
            if partition_type != expected_type:
                raise ArtifactError(f"partition {index} has type {partition_type}")
            if not first_usable <= first <= last <= last_usable:
                raise ArtifactError(f"partition {index} lies outside the usable area")
            partitions.append({
                "index": index,
                "typeGUID": str(partition_type),
                "uniqueGUID": str(uuid.UUID(bytes_le=entry[16:32])),
                "firstLBA": first,
                "lastLBA": last,
                "name": entry[56:].decode("utf-16-le").rstrip("\0"),
            })
        esp, root = partitions
        if esp["firstLBA"] != ESP_FIRST_LBA or root["firstLBA"] <= esp["lastLBA"]:
            raise ArtifactError("ESP and root partitions are not in the expected order")
        if esp["uniqueGUID"] == root["uniqueGUID"]:
            raise ArtifactError("partition GUIDs are not unique")

        boot = _read(stream, esp["firstLBA"] * SECTOR, SECTOR)
        is_fat = boot[0x36:0x3e] in (b"FAT12   ", b"FAT16   ") \
            or boot[0x52:0x5a] == b"FAT32   "
        if boot[510:] != b"\x55\xaa" or not is_fat:
            raise ArtifactError("ESP does not contain a FAT file system")
        esp.update(role="esp", fileSystem="vfat")

        superblock = _read(stream, root["firstLBA"] * SECTOR + 1024, 1024)
        if superblock[0x38:0x3a] != b"\x53\xef":
            raise ArtifactError("root partition does not contain ext4")
        blocks = struct.unpack("<I", superblock[0x04:0x08])[0]
        if struct.unpack("<I", superblock[0x60:0x64])[0] & 0x80:  # INCOMPAT_64BIT
            blocks |= struct.unpack("<I", superblock[0x150:0x154])[0] << 32
        block_size = 1024 << struct.unpack("<I", superblock[0x18:0x1c])[0]
        partition_bytes = (root["lastLBA"] - root["firstLBA"] + 1) * SECTOR
        if blocks * block_size > partition_bytes:
            raise ArtifactError("root file system is larger than its partition")
        label = superblock[0x78:0x88].rstrip(b"\0").decode("ascii", "replace")
        if label != ROOT_LABEL:
            raise ArtifactError(f"root file system label is {label!r}, not {ROOT_LABEL!r}")
        root.update(role="root", fileSystem="ext4", fileSystemLabel=label,
                    fileSystemUUID=str(uuid.UUID(bytes=superblock[0x68:0x78])))

        return {
            "bytes": size,
            "sectorSize": SECTOR,
            "partitionTable": "gpt",
            "diskGUID": str(disk_guid),
            "partitions": partitions,
        }


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compress_and_hash(image, destination, zstd):
    """Compress IMAGE to DESTINATION with ZSTD, hashing the raw bytes read."""
    digest = hashlib.sha256()
    with open(image, "rb") as source, open(destination, "xb") as output, \
            subprocess.Popen([str(zstd), "-q", "-T0", "-12", "-c", "-"],
                             stdin=subprocess.PIPE, stdout=output) as process:
        for chunk in iter(lambda: source.read(CHUNK), b""):
            digest.update(chunk)
            process.stdin.write(chunk)
        process.stdin.close()
    if process.returncode != 0:
        raise ArtifactError(f"zstd failed with status {process.returncode}")
    return digest.hexdigest()


def decompressed_sha256(path, zstd):
    digest = hashlib.sha256()
    total = 0
    with subprocess.Popen([str(zstd), "-q", "-d", "-c", str(path)],
                          stdout=subprocess.PIPE) as process:
        for chunk in iter(lambda: process.stdout.read(CHUNK), b""):
            digest.update(chunk)
            total += len(chunk)
    if process.returncode != 0:
        raise ArtifactError(f"zstd could not decompress {path}")
    return digest.hexdigest(), total


def canonical_json(value):
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def manifest_for(layout, raw_sha256, compressed, guix_commit, system_sha256,
                 credentials):
    if credentials not in CREDENTIALS:
        raise ArtifactError(f"unsupported credentials profile: {credentials}")
    return {
        "schemaVersion": 1,
        "kind": KIND,
        "bootABI": BOOT_ABI,
        "guest": {
            "architecture": "aarch64",
            "distribution": "Guix System",
            "credentials": credentials,
        },
        "source": {"guixCommit": guix_commit, "systemFilesSHA256": system_sha256},
        "disk": dict(layout, sha256=raw_sha256, path=DISK,
                     mediaType="application/zstd",
                     compressedBytes=compressed.stat().st_size,
                     compressedSHA256=sha256_file(compressed)),
    }


def sums_text(directory):
    return "".join(f"{sha256_file(directory / name)}  {name}\n"
                   for name in sorted((DISK, MANIFEST)))


def _require_keys(value, keys, where):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise ArtifactError(f"{where} must have exactly the keys {sorted(keys)}")


def _require_hex(value, where):
    if not isinstance(value, str) or len(value) != 64 or \
            value.strip("0123456789abcdef"):
        raise ArtifactError(f"{where} must be a lowercase SHA-256")


def validate_manifest(manifest):
    _require_keys(manifest, {"schemaVersion", "kind", "bootABI", "guest",
                             "source", "disk"}, "manifest")
    if manifest["schemaVersion"] != 1 or manifest["kind"] != KIND \
            or manifest["bootABI"] != BOOT_ABI:
        raise ArtifactError("manifest has an unsupported schema, kind or boot ABI")
    guest = manifest["guest"]
    _require_keys(guest, {"architecture", "distribution", "credentials"}, "guest")
    if guest["architecture"] != "aarch64" or guest["distribution"] != "Guix System" \
            or guest["credentials"] not in CREDENTIALS:
        raise ArtifactError("manifest describes an unsupported guest")
    source = manifest["source"]
    _require_keys(source, {"guixCommit", "systemFilesSHA256"}, "source")
    commit = source["guixCommit"]
    if not isinstance(commit, str) or len(commit) != 40 or \
            commit.strip("0123456789abcdef"):
        raise ArtifactError("source.guixCommit must be a full Git commit")
    _require_hex(source["systemFilesSHA256"], "source.systemFilesSHA256")
    disk = manifest["disk"]
    _require_keys(disk, {"bytes", "sectorSize", "partitionTable", "diskGUID",
                         "partitions", "sha256", "path", "mediaType",
                         "compressedBytes", "compressedSHA256"}, "disk")
    if disk["path"] != DISK or disk["mediaType"] != "application/zstd" \
            or disk["sectorSize"] != SECTOR or disk["partitionTable"] != "gpt":
        raise ArtifactError("disk record does not describe a zstd GPT image")
    for key in ("bytes", "compressedBytes"):
        if type(disk[key]) is not int or disk[key] <= 0:
            raise ArtifactError(f"disk.{key} must be a positive integer")
    if disk["bytes"] % SECTOR:
        raise ArtifactError("disk.bytes is not a whole number of sectors")
    _require_hex(disk["sha256"], "disk.sha256")
    _require_hex(disk["compressedSHA256"], "disk.compressedSHA256")
    partitions = disk["partitions"]
    if not isinstance(partitions, list) or len(partitions) != 2:
        raise ArtifactError("disk must record exactly two partitions")
    common = {"index", "typeGUID", "uniqueGUID", "firstLBA", "lastLBA", "name",
              "role", "fileSystem"}
    _require_keys(partitions[0], common, "ESP partition")
    _require_keys(partitions[1], common | {"fileSystemLabel", "fileSystemUUID"},
                  "root partition")
    esp, root = partitions
    if (esp["index"], esp["role"], esp["fileSystem"], esp["typeGUID"]) != \
            (1, "esp", "vfat", str(ESP_TYPE)) or \
            (root["index"], root["role"], root["fileSystem"], root["typeGUID"],
             root["fileSystemLabel"]) != (2, "root", "ext4", str(LINUX_FS_TYPE), ROOT_LABEL):
        raise ArtifactError("partition records do not match the Guix EFI layout")
    last_usable = disk["bytes"] // SECTOR - 2 - GPT_ENTRY_SECTORS
    if esp["firstLBA"] != ESP_FIRST_LBA or not \
            esp["firstLBA"] <= esp["lastLBA"] < root["firstLBA"] <= root["lastLBA"] <= last_usable:
        raise ArtifactError("partition extents are inconsistent with the disk size")
    return manifest


def validate_artifacts(directory, zstd=None):
    """Validate a packaged directory; with ZSTD, also hash the raw disk."""
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ArtifactError(f"artifact directory is missing or unsafe: {directory}")
    names = set()
    for entry in directory.iterdir():
        if entry.is_symlink() or not entry.is_file():
            raise ArtifactError(f"artifact entry is not a regular file: {entry.name}")
        names.add(entry.name)
    if names != FILES:
        raise ArtifactError(f"artifact files must be exactly {sorted(FILES)}")
    if (directory / SUMS).read_text(encoding="ascii") != sums_text(directory):
        raise ArtifactError(f"{SUMS} does not match the artifacts")
    text = (directory / MANIFEST).read_text(encoding="utf-8")
    manifest = validate_manifest(json.loads(text))
    if text != canonical_json(manifest):
        raise ArtifactError("manifest is not in canonical form")
    compressed = directory / DISK
    disk = manifest["disk"]
    if compressed.stat().st_size != disk["compressedBytes"] or \
            sha256_file(compressed) != disk["compressedSHA256"]:
        raise ArtifactError("compressed disk does not match its manifest record")
    with open(compressed, "rb") as stream:
        if stream.read(4) != ZSTD_MAGIC:
            raise ArtifactError("compressed disk is not a zstd frame")
    if zstd is not None:
        if decompressed_sha256(compressed, zstd) != (disk["sha256"], disk["bytes"]):
            raise ArtifactError("decompressed disk does not match its manifest record")
    return manifest


def launch_record(directory):
    """The tab-separated record run-qemu-gpu.sh consumes for this artifact.

    Fields: bundle identity (SHA-256 of the manifest file), raw disk SHA-256,
    raw bytes, compressed bytes and working-disk bytes. The launcher's
    materialization re-hashes the decompressed disk against the raw SHA-256.
    """
    manifest = validate_artifacts(directory)
    disk = manifest["disk"]
    return "\t".join([
        sha256_file(Path(directory) / MANIFEST), disk["sha256"], str(disk["bytes"]),
        str(disk["compressedBytes"]), str(max(disk["bytes"], WORKING_DISK_BYTES)),
    ])


if __name__ == "__main__":
    import sys

    if len(sys.argv) != 3 or sys.argv[1] != "launch-record":
        sys.exit("usage: artifact.py launch-record DIRECTORY")
    try:
        print(launch_record(sys.argv[2]))
    except (OSError, ValueError) as error:
        sys.exit(f"guix-artifact: {error}")
