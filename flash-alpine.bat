@echo off
setlocal
title UFI003 Alpine Flasher (fastboot mode)

echo ============================================================
echo   UFI003 Alpine Linux Flasher
echo   - Requires device in fastboot mode
echo   - Flashes firmware + boot + rootfs by partition name
echo ============================================================
echo.

REM --- locate fastboot ---
set "FB=%~dp0fastboot.exe"
if not exist "%FB%" set "FB=fastboot.exe"
where %FB% >nul 2>&1
if errorlevel 1 (
    echo ERROR: fastboot.exe not found.
    echo Put fastboot.exe + AdbWinApi.dll + AdbWinUsbApi.dll in this folder.
    pause
    exit /b 1
)

REM --- wait for device ---
echo Waiting for fastboot device...
%FB% wait-for-devices 2>nul
echo.
%FB% devices
echo.

REM --- files check ---
for %%f in (gpt_both0.bin hyp.mbn rpm.mbn sbl1.mbn tz.mbn aboot.bin boot.bin alpine_rootfs.bin) do (
    if not exist "%%f" (
        echo ERROR: %%f missing in current folder
        pause
        exit /b 1
    )
)

REM --- Step 1: partition table ---
echo [1/8] Flashing partition table...
%FB% flash partition gpt_both0.bin
if errorlevel 1 ( echo FAILED: partition & pause & exit /b 1 )

REM --- Step 2-5: low-level firmware ---
echo [2/8] Flashing hyp...
%FB% flash hyp hyp.mbn
if errorlevel 1 ( echo FAILED: hyp & pause & exit /b 1 )

echo [3/8] Flashing rpm...
%FB% flash rpm rpm.mbn
if errorlevel 1 ( echo FAILED: rpm & pause & exit /b 1 )

echo [4/8] Flashing sbl1...
%FB% flash sbl1 sbl1.mbn
if errorlevel 1 ( echo FAILED: sbl1 & pause & exit /b 1 )

echo [5/8] Flashing tz...
%FB% flash tz tz.mbn
if errorlevel 1 ( echo FAILED: tz & pause & exit /b 1 )

REM --- Step 6: aboot (bootloader) ---
echo [6/8] Flashing aboot...
%FB% flash aboot aboot.bin
if errorlevel 1 ( echo FAILED: aboot & pause & exit /b 1 )

REM --- Step 7: boot.img (kernel + initramfs) ---
echo [7/8] Flashing boot (Alpine kernel)...
%FB% flash boot boot.bin
if errorlevel 1 ( echo FAILED: boot & pause & exit /b 1 )

REM --- Step 8: rootfs (sparse, 200MB sparse-size for chunked transfer) ---
echo [8/8] Flashing rootfs (Alpine)...
%FB% -S 200m flash rootfs alpine_rootfs.bin
if errorlevel 1 ( echo FAILED: rootfs & pause & exit /b 1 )

echo.
echo ============================================================
echo   FLASH COMPLETE!
echo   Rebooting device into Alpine Linux...
echo ============================================================
%FB% reboot
echo.
echo After boot:
echo   SSH: ssh root@172.16.42.1   password: password
echo   USB gadget: NCM + RNDIS + ADB
echo.
pause
