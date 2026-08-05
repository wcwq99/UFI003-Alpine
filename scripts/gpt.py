#!/usr/bin/env python3
"""Validate and safely mutate Qualcomm fastboot GPT bundle images."""

from __future__ import annotations

import argparse
import os
import struct
import tempfile
import uuid
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


LBA_SIZE = 512
GPT_SIGNATURE = b"EFI PART"
GPT_HEADER_OFFSET = LBA_SIZE
GPT_HEADER_MIN_SIZE = 92
LINUX_DATA_GUID = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")
ZERO_GUID = uuid.UUID(int=0)


class GptError(ValueError):
    """Raised when a GPT bundle is malformed or unsafe to modify."""


@dataclass(frozen=True)
class Partition:
    slot: int
    name: str
    type_guid: uuid.UUID
    unique_guid: uuid.UUID
    first_lba: int
    last_lba: int


@dataclass(frozen=True)
class Header:
    offset: int
    size: int
    current_lba: int
    backup_lba: int
    first_usable_lba: int
    last_usable_lba: int
    disk_guid: uuid.UUID
    entries_lba: int
    entry_count: int
    entry_size: int
    entries_crc32: int


@dataclass(frozen=True)
class GptImage:
    data: bytes
    primary_header: Header
    backup_header: Header
    primary_table_offset: int
    backup_table_offset: int
    primary_table: bytes
    backup_table: bytes
    partitions: tuple[Partition, ...]


def _crc32(data: bytes | bytearray) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def _parse_header(data: bytes, offset: int, label: str) -> Header:
    if offset < 0 or offset + GPT_HEADER_MIN_SIZE > len(data):
        raise GptError(f"{label} GPT header is outside the image")
    if data[offset : offset + 8] != GPT_SIGNATURE:
        raise GptError(f"{label} GPT signature is missing")

    revision, size, stored_crc, reserved = struct.unpack_from("<IIII", data, offset + 8)
    if revision != 0x00010000:
        raise GptError(f"{label} GPT revision is unsupported: 0x{revision:08x}")
    if not GPT_HEADER_MIN_SIZE <= size <= LBA_SIZE:
        raise GptError(f"{label} GPT header size is invalid: {size}")
    if reserved != 0:
        raise GptError(f"{label} GPT reserved field is non-zero")

    header_bytes = bytearray(data[offset : offset + size])
    header_bytes[16:20] = b"\0" * 4
    actual_crc = _crc32(header_bytes)
    if actual_crc != stored_crc:
        raise GptError(
            f"{label} GPT header CRC mismatch: stored=0x{stored_crc:08x}, "
            f"actual=0x{actual_crc:08x}"
        )

    current_lba, backup_lba, first_usable, last_usable = struct.unpack_from(
        "<QQQQ", data, offset + 24
    )
    disk_guid = uuid.UUID(bytes_le=data[offset + 56 : offset + 72])
    entries_lba, entry_count, entry_size, entries_crc = struct.unpack_from(
        "<QIII", data, offset + 72
    )
    if entry_count == 0 or entry_size < 128 or entry_size % 8:
        raise GptError(
            f"{label} GPT entry geometry is invalid: {entry_count} x {entry_size}"
        )

    return Header(
        offset=offset,
        size=size,
        current_lba=current_lba,
        backup_lba=backup_lba,
        first_usable_lba=first_usable,
        last_usable_lba=last_usable,
        disk_guid=disk_guid,
        entries_lba=entries_lba,
        entry_count=entry_count,
        entry_size=entry_size,
        entries_crc32=entries_crc,
    )


def _parse_partitions(table: bytes, header: Header) -> tuple[Partition, ...]:
    partitions = []
    for slot in range(header.entry_count):
        start = slot * header.entry_size
        entry = table[start : start + header.entry_size]
        type_guid = uuid.UUID(bytes_le=entry[0:16])
        if type_guid == ZERO_GUID:
            continue
        unique_guid = uuid.UUID(bytes_le=entry[16:32])
        first_lba, last_lba = struct.unpack_from("<QQ", entry, 32)
        name = entry[56:128].decode("utf-16-le", errors="strict").rstrip("\0")
        partitions.append(
            Partition(
                slot=slot,
                name=name,
                type_guid=type_guid,
                unique_guid=unique_guid,
                first_lba=first_lba,
                last_lba=last_lba,
            )
        )
    return tuple(partitions)


def _parse_image(data: bytes) -> GptImage:
    if len(data) < 67 * LBA_SIZE or len(data) % LBA_SIZE:
        raise GptError("GPT bundle size is invalid")

    primary = _parse_header(data, GPT_HEADER_OFFSET, "primary")
    backup = _parse_header(data, len(data) - LBA_SIZE, "backup")
    if (
        primary.entry_count != backup.entry_count
        or primary.entry_size != backup.entry_size
        or primary.disk_guid != backup.disk_guid
    ):
        raise GptError("primary and backup GPT header geometry differs")

    table_size = primary.entry_count * primary.entry_size
    primary_table_offset = primary.entries_lba * LBA_SIZE
    # Qualcomm gpt_both bundles pack the mirrored array immediately after the
    # 34-sector primary image. The backup header's entries_lba is a placeholder.
    backup_table_offset = primary.first_usable_lba * LBA_SIZE
    if primary_table_offset + table_size > len(data):
        raise GptError("primary partition table is outside the image")
    if backup_table_offset + table_size > backup.offset:
        raise GptError("backup partition table is outside the image")

    primary_table = data[primary_table_offset : primary_table_offset + table_size]
    backup_table = data[backup_table_offset : backup_table_offset + table_size]
    primary_crc = _crc32(primary_table)
    backup_crc = _crc32(backup_table)
    if primary_crc != primary.entries_crc32:
        raise GptError(
            "primary partition table CRC mismatch: "
            f"stored=0x{primary.entries_crc32:08x}, actual=0x{primary_crc:08x}"
        )
    if backup_crc != backup.entries_crc32:
        raise GptError(
            "backup partition table CRC mismatch: "
            f"stored=0x{backup.entries_crc32:08x}, actual=0x{backup_crc:08x}"
        )

    image = GptImage(
        data=data,
        primary_header=primary,
        backup_header=backup,
        primary_table_offset=primary_table_offset,
        backup_table_offset=backup_table_offset,
        primary_table=primary_table,
        backup_table=backup_table,
        partitions=_parse_partitions(primary_table, primary),
    )
    validate_image(image)
    return image


def read_image(path: str | os.PathLike[str]) -> GptImage:
    return _parse_image(Path(path).read_bytes())


def validate_image(image: GptImage) -> None:
    if image.primary_table != image.backup_table:
        raise GptError("primary and backup partition tables differ")

    names: set[str] = set()
    unique_guids: set[uuid.UUID] = set()
    finite: list[Partition] = []
    for part in image.partitions:
        if not part.name:
            raise GptError(f"partition slot {part.slot} has no name")
        if part.name in names:
            raise GptError(f"duplicate partition name: {part.name}")
        names.add(part.name)
        if part.unique_guid == ZERO_GUID:
            raise GptError(f"partition {part.name} has a zero unique GUID")
        if part.unique_guid in unique_guids:
            raise GptError(f"duplicate partition unique GUID: {part.name}")
        unique_guids.add(part.unique_guid)

        # A last_lba exactly one before first_lba is the Qualcomm fastboot
        # sentinel for a final grow-to-end partition.
        if part.last_lba + 1 == part.first_lba:
            continue
        if part.last_lba < part.first_lba:
            raise GptError(f"partition {part.name} has an invalid LBA range")
        finite.append(part)

    finite.sort(key=lambda item: item.first_lba)
    for left, right in zip(finite, finite[1:]):
        if left.last_lba >= right.first_lba:
            raise GptError(f"partitions overlap: {left.name} and {right.name}")


def _partition_by_name(partitions: Iterable[Partition], name: str) -> Partition:
    for part in partitions:
        if part.name == name:
            return part
    raise GptError(f"required partition is missing: {name}")


def _update_header_crc(data: bytearray, header: Header, table_crc: int) -> None:
    struct.pack_into("<I", data, header.offset + 88, table_crc)
    struct.pack_into("<I", data, header.offset + 16, 0)
    crc = _crc32(data[header.offset : header.offset + header.size])
    struct.pack_into("<I", data, header.offset + 16, crc)


def add_misc_partition(
    path: str | os.PathLike[str], size_lba: int = 2048
) -> bool:
    target = Path(path)
    image = read_image(target)
    existing = [part for part in image.partitions if part.name == "misc"]
    if existing:
        if len(existing) != 1:
            raise GptError("multiple misc partitions found")
        return False
    if size_lba <= 0:
        raise GptError("misc partition size must be positive")

    fsg = _partition_by_name(image.partitions, "fsg")
    aboot = _partition_by_name(image.partitions, "aboot")
    first_lba = fsg.last_lba + 1
    last_lba = first_lba + size_lba - 1
    if last_lba >= aboot.first_lba:
        raise GptError("no safe gap between fsg and aboot for misc")

    slot = None
    for index in range(image.primary_header.entry_count):
        start = index * image.primary_header.entry_size
        if image.primary_table[start : start + 16] == b"\0" * 16:
            slot = index
            break
    if slot is None:
        raise GptError("no free GPT entry slot for misc")

    entry = bytearray(image.primary_header.entry_size)
    entry[0:16] = LINUX_DATA_GUID.bytes_le
    entry[16:32] = uuid.uuid5(image.primary_header.disk_guid, "misc").bytes_le
    struct.pack_into("<QQQ", entry, 32, first_lba, last_lba, 0)
    name = "misc".encode("utf-16-le")
    entry[56 : 56 + len(name)] = name

    table = bytearray(image.primary_table)
    entry_offset = slot * image.primary_header.entry_size
    table[entry_offset : entry_offset + image.primary_header.entry_size] = entry
    table_crc = _crc32(table)

    output = bytearray(image.data)
    for offset in (image.primary_table_offset, image.backup_table_offset):
        output[offset : offset + len(table)] = table
    _update_header_crc(output, image.primary_header, table_crc)
    _update_header_crc(output, image.backup_header, table_crc)

    # Validate the complete result before replacing the caller's file.
    _parse_image(bytes(output))
    mode = target.stat().st_mode
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix=f".{target.name}.", dir=target.parent, delete=False
        ) as temp_file:
            temp_name = temp_file.name
            temp_file.write(output)
            temp_file.flush()
            os.fsync(temp_file.fileno())
        os.chmod(temp_name, mode)
        os.replace(temp_name, target)
    finally:
        if temp_name and os.path.exists(temp_name):
            os.unlink(temp_name)
    return True


def normalize_image(path: str | os.PathLike[str]) -> bool:
    """Fix backup_lba, current_lba, and last_usable in both GPT headers.

    The Qualcomm fastboot gpt_both0.bin format uses zero placeholder values
    for backup_lba, current_lba, and last_usable.  When the image is written
    directly to disk (e.g. 9006 passthrough or emmcdl), the PBL sees these
    zeros and treats the backup GPT as missing, then falls back to a stale
    backup at an unrelated sector.  This function sets every field to a
    self-consistent value that works for direct raw-disk deployment.
    """
    image = read_image(path)
    ph = image.primary_header
    bh = image.backup_header

    # The backup header lives in the last sector of the 67-sector bundle.
    backup_lba = bh.offset // LBA_SIZE
    last_usable = backup_lba - 1

    needs_fix = (
        ph.backup_lba != backup_lba
        or ph.last_usable_lba != last_usable
        or bh.current_lba != backup_lba
        or bh.last_usable_lba != last_usable
        or bh.entries_lba == 0
    )
    if not needs_fix:
        return False

    output = bytearray(image.data)

    # --- primary header ---
    struct.pack_into("<Q", output, ph.offset + 32, backup_lba)
    struct.pack_into("<Q", output, ph.offset + 48, last_usable)
    _update_header_crc(
        output, ph, _crc32(output[image.primary_table_offset : image.primary_table_offset + ph.entry_count * ph.entry_size])
    )

    # --- backup header ---
    backup_entries_lba = ph.first_usable_lba
    struct.pack_into("<Q", output, bh.offset + 24, backup_lba)
    struct.pack_into("<Q", output, bh.offset + 48, last_usable)
    struct.pack_into("<Q", output, bh.offset + 72, backup_entries_lba)
    _update_header_crc(
        output, bh, _crc32(output[image.backup_table_offset : image.backup_table_offset + bh.entry_count * bh.entry_size])
    )

    _parse_image(bytes(output))

    mode = Path(path).stat().st_mode
    temp_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix=f".{Path(path).name}.", dir=Path(path).parent, delete=False
        ) as temp_file:
            temp_name = temp_file.name
            temp_file.write(output)
            temp_file.flush()
            os.fsync(temp_file.fileno())
        os.chmod(temp_name, mode)
        os.replace(temp_name, path)
    finally:
        if temp_name and os.path.exists(temp_name):
            os.unlink(temp_name)
    return True


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("validate", "add-misc", "normalize"):
        command_parser = subparsers.add_parser(command)
        command_parser.add_argument("image", type=Path)
    return parser


def main() -> int:
    args = _build_parser().parse_args()
    if args.command == "validate":
        image = read_image(args.image)
        print(f"valid GPT bundle: {len(image.partitions)} partitions")
        return 0
    if args.command == "normalize":
        changed = normalize_image(args.image)
        state = "normalized" if changed else "already consistent"
        print(f"GPT headers: {state}")
        return 0
    changed = add_misc_partition(args.image)
    state = "added" if changed else "already present"
    print(f"misc partition: {state}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
