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
# boot.img partition layout from UFI003). Do NOT regenerate the GPT.
