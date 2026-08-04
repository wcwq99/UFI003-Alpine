# Safe UFI003 Build and Flash Refactor

## Context and decision

The repository currently combines a UFI003MB-specific Android boot image, a
matching GPT/root PARTUUID, a generated lk1st bootloader, and an Alpine rootfs.
The known-good Alpine 3.19 package uses a different GPT, DTB, kernel, initramfs,
and nested rootfs layout. Mixing individual files from those packages is not a
safe migration path. This refactor therefore keeps the repository's UFI003MB
5.15 boot/GPT pair and uses the known-good package only as a reference for safe
calibration backup and flashing order.

The build will have one authoritative output contract. The generated, patched
`aboot.mbn` is the bootloader that is packaged and flashed; prebuilt `aboot.bin`
will no longer silently override it. Low-level device firmware remains
prebuilt. The GPT transformer will add `misc` without moving existing
partitions, assign a deterministic non-zero unique GUID, update both partition
table copies where present, and recalculate table/header CRCs. A validator will
then prove that the boot image root PARTUUID still matches GPT `rootfs` and
that all required artifacts are structurally valid.

## Runtime and flash behavior

The USB gadget will expose only NCM and RNDIS. FunctionFS/ADB is excluded until
a real `adbd` package and lifecycle exist. Both device-side MAC addresses get
their own NetworkManager profiles, so Windows RNDIS and Linux/macOS NCM receive
the same documented address. Gadget setup is idempotent, cleans partial state,
and fails if no UDC bind succeeds.

Fresh-device flashing is treated as a migration, not a blind write. The
Windows entry point will resolve all paths relative to itself, verify files,
wait for exactly one fastboot device, use temporary lk2nd to dump `fsc`, `fsg`,
`modemst1`, `modemst2`, and `cdt`, and refuse to rewrite GPT unless every backup
exists and is non-empty. It then flashes the matched firmware set and restores
device-specific data. A separate system-only mode updates `boot` and `rootfs`
without touching GPT or calibration data.

## Security, failure handling, and verification

All destructive build paths are resolved and checked before cleanup. Shell
variables are quoted, temporary mounts are always unmounted by traps, and the
build stops on missing firmware instead of emitting partial artifacts. SSH host
keys are generated on first boot rather than shared across every image. Serial
access uses a login prompt instead of a passwordless root shell. Default access
is documented consistently and can be overridden through build variables.

Tests cover GPT idempotency, CRCs, GUIDs, non-overlap, and unchanged rootfs
identity. Static contract tests cover USB gadget composition, build output
selection, and documentation/config agreement. Artifact validation runs after
the image build in CI. Local verification includes Python unit tests, shell
syntax checks, patch dry-run/application checks, PowerShell parser validation,
and a clean Git diff review. Hardware flashing remains a required manual test;
the scripts must fail closed before the first destructive command when their
preconditions cannot be proven.

