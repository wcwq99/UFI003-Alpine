#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

DEVICE=${DEVICE:-ufi003}
PREBUILT="prebuilt/$DEVICE"
OUTPUT=files

if [ ! -d "$PREBUILT" ]; then
    echo "ERROR: prebuilt device directory is missing: $PREBUILT" >&2
    exit 1
fi
mkdir -p "$OUTPUT"

# lk2nd.img is the only file we must keep from the build step.
if [ ! -s "$OUTPUT/lk2nd.img" ]; then
    echo "ERROR: generated firmware is missing: $OUTPUT/lk2nd.img" >&2
    exit 1
fi

# Use prebuilt aboot and hyp instead of compiled versions.
# The compiled aboot.mbn from current submodule revisions is incompatible
# with UFI003_MB hardware. The prebuilt aboot.bin has been hardware-verified.
for prebuilt_fw in aboot.bin hyp.mbn; do
    if [ ! -s "$PREBUILT/$prebuilt_fw" ]; then
        echo "ERROR: prebuilt firmware is missing: $PREBUILT/$prebuilt_fw" >&2
        exit 1
    fi
    cp "$PREBUILT/$prebuilt_fw" "$OUTPUT/$prebuilt_fw"
done

# Maintain compatibility: publish aboot.bin as aboot.mbn.
cp "$OUTPUT/aboot.bin" "$OUTPUT/aboot.mbn"

for firmware in rpm.mbn sbl1.mbn tz.mbn gpt_both0.bin; do
    source_file="$PREBUILT/$firmware"
    if [ ! -s "$source_file" ]; then
        echo "ERROR: required prebuilt firmware is missing: $source_file" >&2
        exit 1
    fi
    cp "$source_file" "$OUTPUT/$firmware"
done

# Add a raw 1 MiB misc partition in the existing fsg/aboot gap. The helper
# preserves all existing LBAs and GUIDs, updates both packed GPT tables, and
# recalculates the table/header CRCs before replacing the copied image.
python3 scripts/gpt.py add-misc "$OUTPUT/gpt_both0.bin"
python3 scripts/gpt.py validate "$OUTPUT/gpt_both0.bin"