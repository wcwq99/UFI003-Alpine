#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT_DIR"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this build with sudo so chroot and image mounts are available" >&2
    exit 1
fi

printf '\n==> Run contract tests\n'
python3 -m unittest discover -s tests -v

printf '\n==> Install dependencies\n'
scripts/install_deps.sh

printf '\n==> Build hyp, lk1st and lk2nd\n'
scripts/build_hyp_aboot.sh

printf '\n==> Prepare validated MSM8916 firmware\n'
scripts/extract_fw.sh

printf '\n==> Create Alpine rootfs\n'
scripts/alpine_rootfs.sh

printf '\n==> Create boot and sparse rootfs images\n'
scripts/build_images.sh

printf '\n==> Validate publishable bundle\n'
python3 scripts/validate_artifacts.py files --write-manifest
cp flash-alpine.ps1 flash-alpine.bat README.md files/

printf '\nBuild completed: %s/files\n' "$ROOT_DIR"
