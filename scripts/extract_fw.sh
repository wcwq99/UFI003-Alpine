#!/bin/sh -e

# Extract MSM8916 firmware from the device's prebuilt/ directory instead of
# downloading from Linaro. The prebuilt files come from the original flashing
# pack (aboot.bin, hyp.mbn, rpm.mbn, sbl1.mbn, tz.mbn, gpt_both0.bin).

DEVICE=${DEVICE=ufi003}
PREBUILT=prebuilt/${DEVICE}

mkdir -p files

# copy prebuilt low-level firmware
for f in aboot.bin hyp.mbn rpm.mbn sbl1.mbn tz.mbn gpt_both0.bin; do
    if [ -f "${PREBUILT}/${f}" ]; then
        cp "${PREBUILT}/${f}" files/
        echo "  copied ${f} -> files/"
    else
        echo "WARNING: ${PREBUILT}/${f} not found" >&2
    fi
done

# Note: extract_fw.sh in the upstream repo also generated a custom GPT with
# sfdisk, but we use the device's original gpt_both0.bin verbatim (matches the
# boot.img partition layout from UFI003), with one addition: a "misc" partition.
#
# The lk1st bootloader reads the misc partition's boot message ("boot-fastboot")
# to decide whether to enter fastboot mode (see src/lk2nd app/aboot/recovery.c).
# The stock UFI003 GPT has no misc partition, so we insert one in the free gap
# between fsg and aboot (LBA 397312, 1 MiB). We only append a partition entry
# and never move existing partitions.
#
# NOTE: this gpt_both0.bin is the fastboot-flash format: it carries the primary
# GPT header + entries only (backup header at the file end is a stub with
# current_lba=0/backup_lba=1). The aboot fastboot "flash partition" command
# regenerates the backup GPT on device from the primary table, so we only need
# to patch the primary entries.

python3 - <<'EOF'
import struct, sys

GPT_PATH = "files/gpt_both0.bin"
LBA_SIZE = 512
ENTRY_SIZE = 128

with open(GPT_PATH, "rb") as f:
    data = bytearray(f.read())

# primary entries start at LBA 2
base = 2 * LBA_SIZE

# scan existing entries
names = []
for i in range(16):
    ent = data[base + i*ENTRY_SIZE : base + (i+1)*ENTRY_SIZE]
    name = ent[56:128].decode("utf-16-le").rstrip("\x00")
    names.append(name)

if "misc" in names:
    print("misc partition already present, nothing to do")
    sys.exit(0)

# find first empty slot (entry with zeroed first_lba)
slot = -1
for i in range(16):
    ent = data[base + i*ENTRY_SIZE : base + (i+1)*ENTRY_SIZE]
    if ent[32:40] == b"\x00" * 8:
        slot = i
        break
if slot < 0:
    sys.stderr.write("ERROR: no free GPT entry slot for misc\n")
    sys.exit(1)

# misc partition: 1 MiB in the gap between fsg (ends LBA 397311) and aboot
MISC_FIRST = 397312
MISC_LAST = MISC_FIRST + 2048 - 1

ent = bytearray(ENTRY_SIZE)
# type GUID: standard Linux filesystem data (usable as raw misc)
ent[0:16] = bytes.fromhex("0FC63DAF848346628122500A40F35B3A")
ent[32:40] = struct.pack("<Q", MISC_FIRST)
ent[40:48] = struct.pack("<Q", MISC_LAST)
ent[56:128] = "misc".encode("utf-16-le").ljust(72, b"\x00")
data[base + slot*ENTRY_SIZE : base + (slot+1)*ENTRY_SIZE] = ent

with open(GPT_PATH, "wb") as f:
    f.write(data)
print(f"Added misc partition (LBA {MISC_FIRST}-{MISC_LAST}, slot {slot}) to gpt_both0.bin")
EOF
