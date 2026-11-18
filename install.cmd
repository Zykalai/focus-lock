@echo off
setlocal EnableExtensions
cd /d "%~dp0"

echo.
echo   FocusLock installer
echo   ========================
echo.

set "TARGET=%LOCALAPPDATA%\FocusLock"
set "FAIL=0"

if not exist "FocusLock.ps1" (
    echo   [x] FocusLock.ps1 not found. Run this from the repo folder.
    pause
    exit /b 1
)

if not exist "%TARGET%" mkdir "%TARGET%"

echo   Target: %TARGET%
echo.

echo   [1/6] Stopping task and running instances...
rem Stop the task before overwriting files, so a tick at the minute boundary cannot read a half-written script.
schtasks /change /tn "FocusLockGuard" /disable >nul 2>&1
schtasks /end /tn "FocusLockGuard" >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$me=$PID; Get-CimInstance Win32_Process -Filter \"Name='powershell.exe' or Name='wscript.exe'\" | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -and ($_.CommandLine -match [regex]::Escape('%TARGET%')) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
echo     ok
echo.

echo   [2/6] Copying files...
for %%F in (FocusLock.ps1 lock.cmd unlock.cmd settings.cmd settings.vbs tick.vbs README.md) do (
    if exist "%%F" (
        copy /y "%%F" "%TARGET%\" >nul && (echo     ok   %%F) || (echo     FAIL %%F & set "FAIL=1")
    ) else (
        echo     MISS %%F
        set "FAIL=1"
    )
)
if "%FAIL%"=="1" goto :fail
echo.

echo   [3/6] Cleaning legacy entries...
schtasks /delete /tn "FocusLockGuardBackup" /f >nul 2>&1
schtasks /delete /tn "FocusLockManualLock" /f >nul 2>&1
reg delete "HKCU\Software\FocusLock" /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" /v "FocusLock" /f >nul 2>&1
echo     ok
echo.

echo   [4/6] Registering task + Run key...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET%\FocusLock.ps1" -Mode lock
if errorlevel 1 (
    echo     FAIL registration, see %TARGET%\focuslock.log
    set "FAIL=1"
    goto :fail
)
schtasks /change /tn "FocusLockGuard" /enable >nul 2>&1
echo     ok
echo.

echo   [5/6] Verifying...
schtasks /query /tn "FocusLockGuard" >nul 2>&1
if errorlevel 1 (echo     FAIL scheduled task missing & set "FAIL=1") else (echo     ok   scheduled task)
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "FocusLock" >nul 2>&1
if errorlevel 1 (echo     FAIL Run key missing & set "FAIL=1") else (echo     ok   Run key)
if exist "%TARGET%\tick.vbs" (echo     ok   tick.vbs) else (echo     FAIL tick.vbs missing & set "FAIL=1")
if exist "%TARGET%\config.json" (echo     ok   config.json) else (echo     FAIL config.json missing & set "FAIL=1")
if exist "%TARGET%\native.dll" (echo     ok   native.dll) else (echo     warn native.dll not prebuilt, will compile on first lock)
if "%FAIL%"=="1" goto :fail
echo.

echo   [6/6] Done.
echo.
echo   lock.cmd      lock now
echo   unlock.cmd    unlock
echo   settings.cmd  change schedule
echo.
echo   Config: %TARGET%
echo.
pause
exit /b 0

:fail
echo.
echo   [x] Install failed, fix the messages above and re-run.
echo.
pause
exit /b 1
