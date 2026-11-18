@echo off
setlocal EnableExtensions

echo.
echo   FocusLock uninstaller
echo   ========================
echo.

set "TARGET=%LOCALAPPDATA%\FocusLock"
set "FAIL=0"

echo   [1/5] Removing task, autostart, policy and processes...
rem Prefer the copy next to this script (always current), else the installed one.
set "CLEANER=%~dp0FocusLock.ps1"
if not exist "%CLEANER%" set "CLEANER=%TARGET%\FocusLock.ps1"
if exist "%CLEANER%" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CLEANER%" -Mode uninstall
    if errorlevel 1 (
        echo     warn script clean-up failed, using registry fallback
        call :regcleanup
    ) else (
        echo     ok
    )
) else (
    echo     [!] FocusLock.ps1 not found, registry-only cleanup
    call :regcleanup
)
echo.

echo   [2/5] Deleting files...
if exist "%TARGET%" (
    for /l %%I in (1,1,6) do (
        rmdir /s /q "%TARGET%" 2>nul
        if not exist "%TARGET%" goto :gone
        timeout /t 1 /nobreak >nul
    )
)
:gone
if exist "%TARGET%" (
    echo     FAIL folder still present: %TARGET%
    set "FAIL=1"
) else (
    echo     ok
)
echo.

echo   [3/5] Verifying registry...
schtasks /query /tn "FocusLockGuard" >nul 2>&1
if errorlevel 1 (echo     ok   scheduled task gone) else (echo     FAIL scheduled task still exists & set "FAIL=1")
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "FocusLock" >nul 2>&1
if errorlevel 1 (echo     ok   Run key gone) else (echo     FAIL Run key still exists & set "FAIL=1")
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" /v "FocusLock" >nul 2>&1
if errorlevel 1 (echo     ok   startup record gone) else (echo     FAIL startup record still exists & set "FAIL=1")
reg query "HKCU\Software\FocusLock" >nul 2>&1
if errorlevel 1 (echo     ok   legacy key gone) else (echo     FAIL legacy key still exists & set "FAIL=1")
echo.

echo   [4/5] Verifying policy and processes...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "if (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'DisableTaskMgr' -ErrorAction SilentlyContinue) { exit 1 } else { exit 0 }"
if errorlevel 1 (echo     FAIL DisableTaskMgr still set & set "FAIL=1") else (echo     ok   DisableTaskMgr clear)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$me=$PID; $c=@(Get-CimInstance Win32_Process -Filter \"Name='powershell.exe' or Name='wscript.exe'\" | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -and ($_.CommandLine -match [regex]::Escape('%TARGET%')) }); if ($c.Count -gt 0) { exit 1 } else { exit 0 }"
if errorlevel 1 (echo     FAIL FocusLock processes still running & set "FAIL=1") else (echo     ok   no processes)
echo.

echo   [5/5] Result
if "%FAIL%"=="1" goto :fail
echo   Done. FocusLock is fully removed.
echo.
pause
exit /b 0

:regcleanup
schtasks /delete /tn "FocusLockGuard" /f >nul 2>&1
schtasks /delete /tn "FocusLockGuardBackup" /f >nul 2>&1
schtasks /delete /tn "FocusLockManualLock" /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "FocusLock" /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run" /v "FocusLock" /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System" /v "DisableTaskMgr" /f >nul 2>&1
reg delete "HKCU\Software\FocusLock" /f >nul 2>&1
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$me=$PID; Get-CimInstance Win32_Process -Filter \"Name='powershell.exe' or Name='wscript.exe'\" | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -and ($_.CommandLine -match [regex]::Escape('%TARGET%')) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
goto :eof

:fail
echo.
echo   [x] Uninstall incomplete, see FAIL lines above.
echo.
pause
exit /b 1
