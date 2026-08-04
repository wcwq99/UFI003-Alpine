# Safe UFI003 Build and Flash Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Produce a deterministic UFI003 image bundle with validated GPT/boot pairing, reliable USB networking, and a fail-closed calibration-preserving flash workflow.

**Architecture:** Keep the existing UFI003MB 5.15 boot and rootfs architecture. Replace inline binary mutation and ambiguous firmware selection with small testable tools, then make CI and the flasher consume one validated artifact manifest.

**Tech Stack:** POSIX shell, Python 3 standard library, Windows PowerShell/batch, GitHub Actions, Android fastboot/sparse images.

---

### Task 1: Make GPT mutation deterministic and verifiable

**Files:**
- Create: `scripts/gpt.py`
- Create: `tests/test_gpt.py`
- Modify: `scripts/extract_fw.sh`

1. Write tests that copy `prebuilt/ufi003/gpt_both0.bin` to a temporary file.
2. Assert adding `misc` preserves every existing partition and rootfs GUID.
3. Assert the new entry has a non-zero unique GUID, does not overlap, and is idempotent.
4. Assert partition-array and header CRCs validate after mutation.
5. Run `python -m unittest tests.test_gpt -v` and verify the tests fail.
6. Implement parsing, validation, CRC regeneration, mirrored table updates, and CLI handling.
7. Replace the inline Python in `extract_fw.sh` with the tested CLI.
8. Run the unit test and confirm it passes.

### Task 2: Establish one firmware artifact contract

**Files:**
- Modify: `scripts/build_hyp_aboot.sh`
- Modify: `scripts/extract_fw.sh`
- Modify: `scripts/build_images.sh`
- Create: `scripts/validate_artifacts.py`
- Create: `tests/test_artifact_contract.py`

1. Write contract tests asserting that generated `aboot.mbn` and `hyp.mbn` are not overwritten.
2. Build both the final patched lk1st image and temporary `lk2nd.img` used for backups.
3. Make firmware extraction copy only required prebuilt files and fail on omissions.
4. Add artifact validation for Android boot magic, sparse magic, GPT CRCs, required files, and root PARTUUID.
5. Run unit tests and shell syntax checks.

### Task 3: Harden rootfs and USB startup

**Files:**
- Modify: `scripts/alpine_rootfs.sh`
- Modify: `scripts/extract_networkmanager.sh`
- Modify: `scripts/build_images.sh`
- Modify: `scripts/setup_ncm_gadget.sh`
- Modify: `configs/usb.nmconnection`
- Modify: `configs/usb-rndis.nmconnection`

1. Add tests that reject `ffs.adb`, passwordless serial root, prebuilt SSH host keys, and the invalid `/boot` fstab entry.
2. Add a validated cleanup guard for `CHROOT`/`BASE` and quote every path.
3. Remove dead extlinux packaging and the rootfs-as-boot mount.
4. Generate SSH host keys at first boot and use a login getty on `ttyMSM0`.
5. Make gadget cleanup and UDC binding fail closed and configure both MAC profiles.
6. Add mount cleanup traps to rootfs image creation.
7. Run tests and shell syntax checks.

### Task 4: Replace blind flashing with safe modes

**Files:**
- Create: `flash-alpine.ps1`
- Modify: `flash-alpine.bat`
- Create: `tests/test_flash_contract.py`

1. Add contract tests for script-relative paths, device-count checks, mandatory backup-before-GPT, calibration restore, and system-only mode.
2. Implement a PowerShell flasher with checked fastboot invocation and timeouts.
3. Implement temporary-lk2nd backup of `fsc`, `fsg`, `modemst1`, `modemst2`, and `cdt`.
4. Refuse full flashing unless all backup files are present and non-empty.
5. Restore device-specific partitions after the matched GPT/firmware set.
6. Keep the batch file as a minimal PowerShell launcher.
7. Parse the script with the PowerShell AST and run contract tests.

### Task 5: Align documentation and CI

**Files:**
- Modify: `README.md`
- Modify: `.github/workflows/build.yml`
- Modify: `scripts/install_deps.sh`

1. Document supported hardware, matched-image rule, full/system-only modes, backup location, correct IP, and credentials.
2. Remove claims about ADB and runtime extlinux switching.
3. Install build/test dependencies required by fuse2fs and patching.
4. Run unit tests before build and artifact validation after build in CI.
5. Run all local verification commands and review the complete diff.

### Task 6: Commit and push

1. Commit the design and plan.
2. Commit implementation in coherent GPT/build, runtime, and flash/docs changes.
3. Fetch `origin` and verify the branch is a fast-forward of `origin/alpine`.
4. Push with `git push origin HEAD:alpine` without force.
5. Verify the remote branch and, if available, monitor the triggered build workflow.

