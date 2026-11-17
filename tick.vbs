Option Explicit
Dim fso, sh, dir, ps
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
sh.Run """" & ps & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\FocusLock.ps1"" -Mode tick", 0, False