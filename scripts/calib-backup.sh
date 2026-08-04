#!/bin/sh -e
# Calibration & firmware backup/restore with SHA-256 verification.
#
# Backup:
#   calib-backup.sh backup <output-dir>
#     - Reads fsc, fsg, modem, modemst1, modemst2, persist, sec via EDL
#     - Saves to <output-dir>/<name>.bin
#     - Generates <output-dir>/SHA256SUMS
#
# Restore:
#   calib-backup.sh restore <backup-dir>
#     - Verifies SHA256SUMS before flashing
#     - Flashes each partition via fastboot
#     - Requires fastboot device in fastboot mode
#
# Usage:
#   # Backup (device in EDL mode):
#   calib-backup.sh backup ./calib-backup
#
#   # Restore (device in fastboot mode):
#   calib-backup.sh restore ./calib-backup

PARTITIONS="fsc fsg modem modemst1 modemst2 persist sec"

do_backup() {
    OUTDIR="$1"
    mkdir -p "$OUTDIR"

    echo "Backing up calibration partitions to $OUTDIR ..."
    for n in $PARTITIONS; do
        echo "  Reading $n ..."
        edl r "$n" "$OUTDIR/${n}.bin"
    done

    # Generate SHA-256 checksums
    (cd "$OUTDIR" && sha256sum $(
        for n in $PARTITIONS; do printf '%s.bin ' "$n"; done
    ) > SHA256SUMS)

    echo "Backup complete. SHA256SUMS written to $OUTDIR/SHA256SUMS"
    echo "Keep this backup safe — it contains unique device calibration data."

    # Print checksums for manual verification
    echo ""
    echo "Checksums:"
    cat "$OUTDIR/SHA256SUMS"
}

do_restore() {
    BACKUPDIR="$1"

    if [ ! -f "$BACKUPDIR/SHA256SUMS" ]; then
        echo "ERROR: SHA256SUMS not found in $BACKUPDIR" >&2
        exit 1
    fi

    echo "Verifying backup integrity..."
    (cd "$BACKUPDIR" && sha256sum -c SHA256SUMS)

    # Verify sizes are non-zero
    for n in $PARTITIONS; do
        f="$BACKUPDIR/${n}.bin"
        if [ ! -f "$f" ]; then
            echo "ERROR: $f not found" >&2
            exit 1
        fi
        size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
        if [ "$size" -eq 0 ]; then
            echo "ERROR: $f is empty" >&2
            exit 1
        fi
        echo "  $n: $size bytes"
    done

    echo "All checks passed. Flashing calibration partitions..."

    for n in $PARTITIONS; do
        echo "  Flashing $n ..."
        fastboot flash "$n" "$BACKUPDIR/${n}.bin"
    done

    echo "Calibration restore complete."
}

case "${1:-}" in
    backup)
        do_backup "${2:-calib-backup}"
        ;;
    restore)
        do_restore "${2:-calib-backup}"
        ;;
    *)
        echo "Usage: $0 backup <output-dir>"
        echo "       $0 restore <backup-dir>"
        exit 1
        ;;
esac