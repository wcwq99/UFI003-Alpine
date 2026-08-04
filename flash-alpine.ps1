[CmdletBinding()]
param(
    [ValidateSet("SystemOnly", "Full")]
    [string]$Mode = "SystemOnly",
    [string]$BundleDirectory,
    [string]$FastbootPath,
    [string]$BackupDirectory,
    [switch]$ConfirmFullFlash,
    [switch]$NoReboot,
    [ValidateRange(10, 1800)]
    [int]$WaitTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FastbootExecutable {
    if ($FastbootPath) {
        if (-not (Test-Path -LiteralPath $FastbootPath -PathType Leaf)) {
            throw "fastboot executable not found: $FastbootPath"
        }
        return (Resolve-Path -LiteralPath $FastbootPath).Path
    }

    $bundledFastboot = Join-Path $PSScriptRoot "fastboot.exe"
    if (Test-Path -LiteralPath $bundledFastboot -PathType Leaf) {
        return $bundledFastboot
    }

    $command = Get-Command fastboot -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "fastboot was not found. Install Android platform-tools or pass -FastbootPath."
    }
    return $command.Source
}

function Resolve-BundleDirectory {
    if ($BundleDirectory) {
        if (-not (Test-Path -LiteralPath $BundleDirectory -PathType Container)) {
            throw "Firmware bundle directory not found: $BundleDirectory"
        }
        return (Resolve-Path -LiteralPath $BundleDirectory).Path
    }

    $filesDirectory = Join-Path $PSScriptRoot "files"
    if (Test-Path -LiteralPath $filesDirectory -PathType Container) {
        return (Resolve-Path -LiteralPath $filesDirectory).Path
    }
    return $PSScriptRoot
}

function Invoke-Fastboot {
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    Write-Host ("fastboot " + ($Arguments -join " ")) -ForegroundColor DarkGray
    $result = Invoke-FastbootCapture $Arguments
    $result.Output | ForEach-Object { Write-Host $_ }
    $exitCode = $result.ExitCode
    if (($exitCode -ne 0) -and (-not $AllowFailure)) {
        throw "fastboot failed with exit code ${exitCode}: $($Arguments -join ' ')"
    }
    return $exitCode
}

function Invoke-FastbootCapture {
    param(
        [Parameter(Mandatory, Position = 0)]
        [string[]]$Arguments
    )

    # fastboot writes normal progress and getvar output to stderr. Windows
    # PowerShell can otherwise promote those lines to terminating errors when
    # the script is running with ErrorActionPreference=Stop.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $script:FastbootExecutable @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    return [PSCustomObject]@{
        Output = $output
        ExitCode = $exitCode
    }
}

function Get-FastbootDevices {
    $result = Invoke-FastbootCapture @("devices")
    if ($result.ExitCode -ne 0) {
        throw "Unable to enumerate fastboot devices: $($result.Output -join [Environment]::NewLine)"
    }
    return @(
        $result.Output |
            ForEach-Object { $_.ToString().Trim() } |
            Where-Object { $_ -match "\s+fastboot$" } |
            ForEach-Object { ($_ -split "\s+")[0] }
    )
}

function Get-FastbootPartitionSize {
    param([Parameter(Mandatory)][string]$Partition)

    $result = Invoke-FastbootCapture @("getvar", "partition-size:$Partition")
    if ($result.ExitCode -ne 0) {
        throw "Unable to query the size of calibration partition $Partition"
    }
    $text = $result.Output -join "`n"
    $pattern = "(?im)partition-size:$([regex]::Escape($Partition)):\s*(0x[0-9a-f]+)"
    if ($text -notmatch $pattern) {
        throw "fastboot did not report a parseable size for calibration partition $Partition"
    }
    return [Convert]::ToInt64($Matches[1].Substring(2), 16)
}

function Wait-OneFastbootDevice {
    $deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
    do {
        $devices = @(Get-FastbootDevices)
        if ($devices.Count -eq 1) {
            Write-Host "Using fastboot device $($devices[0])." -ForegroundColor Green
            return $devices[0]
        }
        if ($devices.Count -gt 1) {
            throw "Expected exactly one fastboot device, but found $($devices.Count): $($devices -join ', ')"
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    throw "Expected exactly one fastboot device, but none appeared within $WaitTimeoutSeconds seconds."
}

function Get-BundleFile {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $script:ResolvedBundleDirectory $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required bundle file is missing: $path"
    }
    return $path
}

function Assert-BundleIntegrity {
    param([Parameter(Mandatory)][string[]]$RequiredNames)

    $manifestPath = Join-Path $script:ResolvedBundleDirectory "SHA256SUMS"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "SHA256SUMS is required beside the firmware images: $manifestPath"
    }

    $expectedHashes = @{}
    foreach ($line in Get-Content -LiteralPath $manifestPath) {
        if ($line -match '^([0-9A-Fa-f]{64})\s+\*?(.+)$') {
            $expectedHashes[$Matches[2].Trim()] = $Matches[1].ToLowerInvariant()
        }
    }

    foreach ($name in $RequiredNames) {
        if (-not $expectedHashes.ContainsKey($name)) {
            throw "SHA256SUMS has no entry for required file: $name"
        }
        $path = Get-BundleFile $name
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHashes[$name]) {
            throw "SHA-256 mismatch for $name. Expected $($expectedHashes[$name]), got $actualHash."
        }
    }
    Write-Host "Verified SHA-256 hashes for $($RequiredNames.Count) firmware files." -ForegroundColor Green
}

function Restart-FastbootBootloader {
    Invoke-Fastboot @("reboot", "bootloader") | Out-Null
    Start-Sleep -Seconds 2
    Wait-OneFastbootDevice | Out-Null
}

function Backup-CalibrationPartitions {
    param([Parameter(Mandatory)][string]$DestinationDirectory)

    foreach ($Partition in @("cdt", "sec", "fsc", "fsg", "modemst1", "modemst2")) {
        $Destination = Join-Path $DestinationDirectory "$Partition.bin"
        $expectedSize = Get-FastbootPartitionSize $Partition
        Invoke-Fastboot @("oem", "dump", $Partition) | Out-Null
        Invoke-Fastboot @("get_staged", $Destination) | Out-Null
        if ((-not (Test-Path -LiteralPath $Destination -PathType Leaf)) -or
            ((Get-Item -LiteralPath $Destination).Length -ne $expectedSize)) {
            throw "Calibration backup size mismatch for $Partition; expected $expectedSize bytes"
        }
    }

    Get-ChildItem -LiteralPath $DestinationDirectory -Filter "*.bin" -File |
        Get-FileHash -Algorithm SHA256 |
        ForEach-Object { "$($_.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($_.Path))" } |
        Set-Content -LiteralPath (Join-Path $DestinationDirectory "SHA256SUMS") -Encoding ascii
}

function Restore-CalibrationPartitions {
    param([Parameter(Mandatory)][string]$SourceDirectory)

    foreach ($Partition in @("cdt", "sec", "fsc", "fsg", "modemst1", "modemst2")) {
        $source = Join-Path $SourceDirectory "$Partition.bin"
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Calibration backup disappeared before restore: $source"
        }
        Invoke-Fastboot @("flash", $Partition, $source) | Out-Null
    }
}

function Flash-SystemImages {
    Invoke-Fastboot @("flash", "boot", (Get-BundleFile "boot.bin")) | Out-Null
    Invoke-Fastboot @("-S", "200m", "flash", "rootfs", (Get-BundleFile "alpine_rootfs.bin")) | Out-Null
}

function Flash-FullFirmware {
    if (-not $ConfirmFullFlash) {
        throw "Full mode rewrites the partition table and boot firmware. Re-run with -Mode Full -ConfirmFullFlash after reviewing the backup location."
    }

    if ($BackupDirectory) {
        $backupRoot = [IO.Path]::GetFullPath($BackupDirectory)
    }
    else {
        $backupRoot = Join-Path $PSScriptRoot "backups"
    }
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $deviceBackupDirectory = Join-Path $backupRoot (Get-Date -Format "yyyyMMdd-HHmmss-fff")
    New-Item -ItemType Directory -Path $deviceBackupDirectory | Out-Null

    Write-Host "Starting calibration backup in $deviceBackupDirectory" -ForegroundColor Yellow
    Invoke-Fastboot @("erase", "boot") | Out-Null
    Invoke-Fastboot @("flash", "boot", (Get-BundleFile "lk2nd.img")) | Out-Null
    # A normal reboot executes the temporary lk2nd image from boot. Using
    # "reboot bootloader" here would stay in lk1st and lose oem dump support.
    Invoke-Fastboot @("reboot") | Out-Null
    Start-Sleep -Seconds 2
    Wait-OneFastbootDevice | Out-Null

    try {
        Backup-CalibrationPartitions -DestinationDirectory $deviceBackupDirectory
    }
    catch {
        throw "Calibration backup failed; the GPT was not changed. The device remains in maintenance fastboot. Backup path: $deviceBackupDirectory. $($_.Exception.Message)"
    }

    Write-Host "Calibration backup completed. GPT writes are now enabled." -ForegroundColor Green
    Invoke-Fastboot @("erase", "lk2nd") -AllowFailure | Out-Null
    Invoke-Fastboot @("erase", "boot") | Out-Null
    Restart-FastbootBootloader

    Invoke-Fastboot @("flash", "partition", (Get-BundleFile "gpt_both0.bin")) | Out-Null
    Restart-FastbootBootloader

    foreach ($firmware in @(
        @{ Partition = "hyp"; File = "hyp.mbn" },
        @{ Partition = "rpm"; File = "rpm.mbn" },
        @{ Partition = "sbl1"; File = "sbl1.mbn" },
        @{ Partition = "tz"; File = "tz.mbn" },
        @{ Partition = "aboot"; File = "aboot.mbn" }
    )) {
        Invoke-Fastboot @("flash", $firmware.Partition, (Get-BundleFile $firmware.File)) | Out-Null
    }

    Flash-SystemImages
    Restore-CalibrationPartitions -SourceDirectory $deviceBackupDirectory
    Write-Host "Full flash and calibration restore completed. Backup: $deviceBackupDirectory" -ForegroundColor Green
}

$script:ResolvedBundleDirectory = Resolve-BundleDirectory
$script:FastbootExecutable = Resolve-FastbootExecutable

$systemFiles = @("boot.bin", "alpine_rootfs.bin")
$fullFiles = @(
    "gpt_both0.bin", "hyp.mbn", "rpm.mbn", "sbl1.mbn", "tz.mbn",
    "aboot.mbn", "lk2nd.img", "boot.bin", "alpine_rootfs.bin"
)

if ($Mode -eq "Full") {
    Assert-BundleIntegrity -RequiredNames $fullFiles
}
else {
    Assert-BundleIntegrity -RequiredNames $systemFiles
}

Wait-OneFastbootDevice | Out-Null
if ($Mode -eq "Full") {
    Flash-FullFirmware
}
else {
    Flash-SystemImages
    Write-Host "System images flashed successfully." -ForegroundColor Green
}

if (-not $NoReboot) {
    Invoke-Fastboot @("reboot") | Out-Null
}
