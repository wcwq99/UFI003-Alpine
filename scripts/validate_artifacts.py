#!/usr/bin/env python3
"""Validate a complete UFI003 firmware bundle before publishing or flashing."""

from __future__ import annotations

import argparse
import hashlib
import re
import struct
from pathlib import Path

try:
    from scripts import gpt
except ImportError:  # Direct execution: python3 scripts/validate_artifacts.py
    import gpt  # type: ignore


ANDROID_MAGIC = b"ANDROID!"
SPARSE_MAGIC = 0xED26FF3A
REQUIRED_FILES = (
    "gpt_both0.bin",
    "hyp.mbn",
    "rpm.mbn",
    "sbl1.mbn",
    "tz.mbn",
    "aboot.mbn",
    "lk2nd.img",
    "boot.bin",
    "alpine_rootfs.bin",
)


class ArtifactError(ValueError):
    """Raised when an artifact bundle violates its format contract."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _android_cmdline(path: Path, *, require_ramdisk: bool = True) -> str:
    data = path.read_bytes()
    if len(data) < 1632 or data[:8] != ANDROID_MAGIC:
        raise ArtifactError(f"{path.name} is not an Android boot image")
    page_size = struct.unpack_from("<I", data, 36)[0]
    kernel_size = struct.unpack_from("<I", data, 8)[0]
    ramdisk_size = struct.unpack_from("<I", data, 16)[0]
    if page_size < 512 or page_size & (page_size - 1):
        raise ArtifactError(f"{path.name} has an invalid page size")
    if kernel_size == 0:
        raise ArtifactError(f"{path.name} is missing a kernel")
    if require_ramdisk and ramdisk_size == 0:
        raise ArtifactError(f"{path.name} is missing a ramdisk")
    command = data[64:576] + data[608:1632]
    return command.split(b"\0", 1)[0].decode("ascii", errors="strict")


def _validate_sparse(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    if len(data) < 28:
        raise ArtifactError(f"{path.name} is too small")
    (
        magic,
        major,
        _minor,
        file_header_size,
        chunk_header_size,
        block_size,
        total_blocks,
        total_chunks,
        _checksum,
    ) = struct.unpack_from("<IHHHHIIII", data)
    if magic != SPARSE_MAGIC or major != 1:
        raise ArtifactError(f"{path.name} is not an Android sparse image")
    if file_header_size < 28 or chunk_header_size < 12:
        raise ArtifactError(f"{path.name} has invalid sparse header sizes")
    if block_size == 0 or total_blocks == 0 or total_chunks == 0:
        raise ArtifactError(f"{path.name} has empty sparse geometry")

    offset = file_header_size
    expanded_blocks = 0
    for index in range(total_chunks):
        if offset + chunk_header_size > len(data):
            raise ArtifactError(f"{path.name} sparse chunk {index} is truncated")
        chunk_type, _reserved, chunk_blocks, total_size = struct.unpack_from(
            "<HHII", data, offset
        )
        if total_size < chunk_header_size or offset + total_size > len(data):
            raise ArtifactError(f"{path.name} sparse chunk {index} has an invalid size")
        payload_size = total_size - chunk_header_size
        if chunk_type == 0xCAC1 and payload_size != chunk_blocks * block_size:
            raise ArtifactError(f"{path.name} RAW chunk {index} has an invalid payload")
        if chunk_type == 0xCAC2 and payload_size != 4:
            raise ArtifactError(f"{path.name} FILL chunk {index} has an invalid payload")
        if chunk_type == 0xCAC3 and payload_size != 0:
            raise ArtifactError(
                f"{path.name} DONT_CARE chunk {index} has an invalid payload"
            )
        if chunk_type == 0xCAC4:
            if payload_size != 4 or chunk_blocks != 0:
                raise ArtifactError(f"{path.name} CRC chunk {index} is invalid")
        elif chunk_type not in (0xCAC1, 0xCAC2, 0xCAC3):
            raise ArtifactError(f"{path.name} has unknown sparse chunk type")
        else:
            expanded_blocks += chunk_blocks
        offset += total_size

    if expanded_blocks != total_blocks:
        raise ArtifactError(
            f"{path.name} expands to {expanded_blocks} blocks, expected {total_blocks}"
        )
    if offset != len(data):
        raise ArtifactError(f"{path.name} has trailing data after sparse chunks")
    return block_size, total_blocks


def validate_directory(directory: str | Path) -> dict[str, str]:
    root = Path(directory)
    missing = [name for name in REQUIRED_FILES if not (root / name).is_file()]
    if missing:
        raise ArtifactError(f"required artifacts are missing: {', '.join(missing)}")
    empty = [name for name in REQUIRED_FILES if (root / name).stat().st_size == 0]
    if empty:
        raise ArtifactError(f"artifacts are empty: {', '.join(empty)}")

    gpt_image = gpt.read_image(root / "gpt_both0.bin")
    partitions = {part.name: part for part in gpt_image.partitions}
    if "misc" not in partitions or "rootfs" not in partitions:
        raise ArtifactError("GPT must contain misc and rootfs partitions")

    command_line = _android_cmdline(root / "boot.bin")
    match = re.search(r"(?:^|\s)root=PARTUUID=([0-9a-fA-F-]{36})(?:\s|$)", command_line)
    if not match:
        raise ArtifactError("boot.bin has no root=PARTUUID kernel argument")
    boot_root_guid = match.group(1).lower()
    gpt_root_guid = str(partitions["rootfs"].unique_guid).lower()
    if boot_root_guid != gpt_root_guid:
        raise ArtifactError(
            f"boot PARTUUID {boot_root_guid} does not match GPT rootfs {gpt_root_guid}"
        )

    # lk2nd is distributed as an Android boot container with a kernel payload
    # and an intentionally empty ramdisk (matching the known-good 3.19 bundle).
    _android_cmdline(root / "lk2nd.img", require_ramdisk=False)
    if (root / "aboot.mbn").stat().st_size < 64 * 1024:
        raise ArtifactError("aboot.mbn is unexpectedly small")
    if (root / "hyp.mbn").stat().st_size < 4 * 1024:
        raise ArtifactError("hyp.mbn is unexpectedly small")
    block_size, total_blocks = _validate_sparse(root / "alpine_rootfs.bin")

    return {
        "rootfs_partition": "rootfs",
        "root_partuuid": boot_root_guid,
        "gpt_rootfs_guid": gpt_root_guid,
        "rootfs_expanded_bytes": str(block_size * total_blocks),
    }


def write_manifest(directory: str | Path) -> Path:
    root = Path(directory)
    manifest = root / "SHA256SUMS"
    lines = [f"{_sha256(root / name)}  {name}\n" for name in REQUIRED_FILES]
    manifest.write_text("".join(lines), encoding="ascii", newline="\n")
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--write-manifest", action="store_true")
    args = parser.parse_args()
    report = validate_directory(args.directory)
    if args.write_manifest:
        report["manifest"] = str(write_manifest(args.directory))
    for key, value in sorted(report.items()):
        print(f"{key}: {value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
