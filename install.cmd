@echo off
setlocal
cd /d "%~dp0"

echo.
echo   FocusLock installer
echo   ========================
echo.

set "TARGET=%LOCALAPPDATA%\FocusLock"

if not exist "FocusLock.ps1" (
    echo   [x] FocusLock.ps1 not found. Run this from the repo folder.
    pause
    exit /b 1
)

if not exist "%TARGET%" mkdir "%TARGET%"
echo   Target: %TARGET%
echo.

echo   Copying files...
for %%F in (FocusLock.ps1 lock.cmd unlock.cmd settings.cmd settings.vbs tick.vbs FocusLock.md README.md) do (
    if exist "%%F" (
        copy /y "%%F" "%TARGET%\" >nul
        echo     ok  %%F
    ) else (
        echo     miss %%F
    )
)
echo.

echo   Registering scheduled task and autostart...
start "" /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET%\FocusLock.ps1" -Mode lock
echo.

echo   ========================
echo   Done.
echo.
echo   lock.cmd      lock now
echo   unlock.cmd    unlock
echo   settings.cmd  change schedule
echo.
echo   Config: %TARGET%
echo.
pause