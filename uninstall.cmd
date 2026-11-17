@echo off
setlocal
echo.
echo   FocusLock uninstaller
echo   ========================
echo.

set "TARGET=%LOCALAPPDATA%\FocusLock"

echo   Removing scheduled task...
schtasks /delete /tn "FocusLockGuard" /f >nul 2>&1
echo     ok

echo   Removing autostart entry...
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "FocusLock" /f >nul 2>&1
echo     ok

echo   Killing running processes...
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { $_.CommandLine -match 'FocusLock' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>&1
echo     ok

echo   Restoring taskbar...
powershell -NoProfile -Command "Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class T{[DllImport(\"user32.dll\",CharSet=CharSet.Unicode)]public static extern IntPtr FindWindow(string c,string n);[DllImport(\"user32.dll\")]public static extern bool ShowWindow(IntPtr h,int n);}'; [T]::ShowWindow([T]::FindWindow('Shell_TrayWnd',0),5)" >nul 2>&1
echo     ok

echo   Deleting %TARGET% ...
if exist "%TARGET%" rmdir /s /q "%TARGET%"
echo     ok

echo.
echo   Done.
echo.
pause