@echo off
cd /d "%~dp0"
if "%~1"=="" (
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "%~dp0FocusLock.ps1" -Mode lock-ask
) else (
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0FocusLock.ps1" -Mode lock -Minutes %~1
)