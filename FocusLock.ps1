[CmdletBinding()]
param(
    [ValidateSet('lock', 'lock-ui', 'lock-ask', 'tick', 'guard', 'unlock', 'settings', 'uninstall')]
    [string]$Mode = 'lock',
    [int]$Minutes = 0
)

$ErrorActionPreference = 'Stop'

$script:AppName    = 'FocusLock'
$script:Version    = '1.2.5'
$script:DataDir    = Join-Path $env:LOCALAPPDATA 'FocusLock'
$script:ConfigPath = Join-Path $script:DataDir 'config.json'
$script:StatePath  = Join-Path $script:DataDir 'state.json'
$script:ManualPath = Join-Path $script:DataDir 'manual.json'
$script:LogPath    = Join-Path $script:DataDir 'focuslock.log'
$script:TaskName   = 'FocusLockGuard'
$script:MutexUI    = 'Local\FocusLock.UI'
$script:MutexGuard = 'Local\FocusLock.Guard'

$script:SelfPath   = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }

$script:CsSource = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace FocusLockNative
{
    public static class Win32
    {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetProcessDPIAware();

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, StringBuilder pvParam, uint fWinIni);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern IntPtr GetModuleHandle(string lpModuleName);

        public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

        private const int WH_KEYBOARD_LL = 13;
        // 允许的组合：Win+L（用户锁屏去睡觉）
        private const int VK_L = 0x4C;
        private static IntPtr _hookId = IntPtr.Zero;
        private static LowLevelKeyboardProc _proc;
        private static bool _active = false;

        public static bool Install()
        {
            if (_hookId != IntPtr.Zero) return true;
            try
            {
                _proc = HookCallback;
                Process cur = Process.GetCurrentProcess();
                ProcessModule mod = cur.MainModule;
                _hookId = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(mod.ModuleName), 0);
                cur.Dispose();
                _active = (_hookId != IntPtr.Zero);
                return _active;
            }
            catch { return false; }
        }

        public static void Uninstall()
        {
            _active = false;
            if (_hookId != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_hookId);
                _hookId = IntPtr.Zero;
            }
        }

        private static bool Down(int vk)
        {
            return (GetAsyncKeyState(vk) & 0x8000) != 0;
        }

        private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 && _active)
            {
                int msg = wParam.ToInt32();
                bool isDown = (msg == 0x0100 || msg == 0x0104);
                int vk = Marshal.ReadInt32(lParam);

                if (isDown)
                {
                    bool alt = Down(0x12);
                    bool ctrl = Down(0x11);
                    bool win = Down(0x5B) || Down(0x5C);

                    if (vk == 0x5B || vk == 0x5C) return (IntPtr)1;
                    if (win && vk != VK_L) return (IntPtr)1;
                    if (alt && (vk == 0x09 || vk == 0x1B || vk == 0x20)) return (IntPtr)1;
                    if (alt && vk == 0x73) return (IntPtr)1;
                    if (ctrl && vk == 0x1B) return (IntPtr)1;
                }
            }
            return CallNextHookEx(_hookId, nCode, wParam, lParam);
        }
    }
}
'@


function ConvertTo-IsoDay {
    param([System.DayOfWeek]$DayOfWeek)
    $n = [int]$DayOfWeek
    if ($n -eq 0) { return 7 }
    return $n
}

function ConvertTo-TimeOfDay {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $ts = [timespan]::Zero
    if ([timespan]::TryParse($Text, [ref]$ts)) { return $ts }
    return $null
}

function Test-NeutralClassName {
    param([string]$ClassName)
    $neutral = @('Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'Progman', 'WorkerW', 'NotifyIconOverflowWindow', 'TopLevelWindowForOverflowXamlIsland')
    return ($neutral -contains $ClassName)
}

function Initialize-Native {

    if ('FocusLockNative.Win32' -as [type]) { return $true }

    # 编一次、落盘复用：原来每个 tick 都 Add-Type，等于每分钟拉起一次 csc.exe
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($script:CsSource))).Replace('-', '')
    $sha.Dispose()

    $dll   = Join-Path $script:DataDir 'native.dll'
    $stamp = Join-Path $script:DataDir 'native.hash'

    if ((Test-Path -LiteralPath $dll) -and (Test-Path -LiteralPath $stamp)) {
        try {
            if (([System.IO.File]::ReadAllText($stamp)).Trim() -eq $hash) {
                Add-Type -Path $dll -ErrorAction Stop
                return $true
            }
        } catch { }
    }

    if (Test-Path -LiteralPath $script:DataDir) {
        try {
            Add-Type -TypeDefinition $script:CsSource -Language CSharp -OutputAssembly $dll -OutputType Library -ErrorAction Stop
            [System.IO.File]::WriteAllText($stamp, $hash, (New-Object System.Text.UTF8Encoding($true)))
            Add-Type -Path $dll -ErrorAction Stop
            return $true
        } catch {
            Write-FocusLog 'native-build-fail' $_.Exception.Message
        }
    }

    try { Add-Type -TypeDefinition $script:CsSource -Language CSharp -ErrorAction Stop; return $true } catch { return $false }
}

function Write-FocusLog {
    param([string]$Event, [string]$Detail = '')
    try {
        if (-not (Test-Path $script:DataDir)) { return }

        try {
            $fi = [System.IO.FileInfo]::new($script:LogPath)
            if ($fi.Exists -and $fi.Length -gt 524288) {
                $keep = @(Get-Content $script:LogPath -Tail 200 -Encoding UTF8)
                [System.IO.File]::WriteAllLines($script:LogPath, [string[]]$keep, (New-Object System.Text.UTF8Encoding($true)))
            }
        } catch { }

        $line = '{0} | {1} | {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Event, $Detail
        [System.IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
}

function Get-FocusConfig {
    if (-not (Test-Path $script:ConfigPath)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($script:ConfigPath, [System.Text.Encoding]::UTF8)
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Save-FocusConfig {
    param([object]$Config)
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    $json = $Config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Clear-FocusState {
    if (Test-Path $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue }
}

function Test-NamedMutexHeld {
    param([string]$Name)
    $m = $null
    try {
        $m = [System.Threading.Mutex]::OpenExisting($Name)
        return $true
    } catch {
        return $false
    } finally {
        if ($m) { try { $m.Dispose() } catch { } }
    }
}


function Set-LockUiReady {

    # 记下"遮罩已经画出来"的时刻；unlock 用它判断这次点击是不是发生在遮罩之后
    try {
        $o = @{ pid = $PID; at = (Get-Date).ToString('o') } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText((Join-Path $script:DataDir 'ui-ready.json'), $o)
    } catch { }
}

function Clear-LockUiReady {
    try { Remove-Item -LiteralPath (Join-Path $script:DataDir 'ui-ready.json') -Force -ErrorAction SilentlyContinue } catch { }
}

function Get-LockUiReadyAt {

    # 读 lock-ui 在 Form.Shown 里写下的记录。pid 必须还活着，时间戳必须晚于该进程启动
    # （否则就是上一轮留下的旧记录，或者 PID 被别的进程复用）
    $readyFile = Join-Path $script:DataDir 'ui-ready.json'
    if (-not (Test-Path -LiteralPath $readyFile)) { return $null }
    try {
        $u = Get-Content -LiteralPath $readyFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $gp = Get-Process -Id ([int]$u.pid) -ErrorAction SilentlyContinue
        if (-not $gp) { return $null }
        $at = [datetime]$u.at
        if ($at -lt $gp.StartTime) { return $null }
        return $at
    } catch {
        return $null
    }
}

function Get-PowerShellExe {
    $candidates = @(
        (Join-Path $PSHOME 'powershell.exe'),
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return 'powershell.exe'
}

function Start-FocusChild {

    param([string]$ChildMode)

    $exe = Get-PowerShellExe
    $argStr = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Sta -File "{0}" -Mode {1}' -f $script:SelfPath, $ChildMode

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $argStr
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.WorkingDirectory = $script:DataDir
        [void][System.Diagnostics.Process]::Start($psi)
        return $true
    } catch {
        Write-FocusLog 'child-start-fail' "$ChildMode : $($_.Exception.Message)"
        return $false
    }
}

$script:ManualCache = @{ Stamp = $null; Value = $null }
$script:StateCache  = @{ Stamp = $null; Value = $null }

function Get-Stamp {
    param([string]$Path)
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return 'none' }
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
        return ([string]$fi.LastWriteTimeUtc.Ticks + '/' + [string]$fi.Length)
    } catch { return 'none' }
}

function Get-ManualLock {

    $stamp = Get-Stamp $script:ManualPath

    if ($script:ManualCache.Stamp -eq $stamp) {
        $cached = $script:ManualCache.Value
        if (-not $cached) { return $null }
        $e = [datetime]::MinValue
        if ([datetime]::TryParse([string]$cached.end, [ref]$e) -and $e -gt (Get-Date)) { return $cached }
        return $null
    }

    $script:ManualCache.Stamp = $stamp

    if ($stamp -eq 'none') { $script:ManualCache.Value = $null; return $null }

    try {
        $raw = [System.IO.File]::ReadAllText($script:ManualPath, [System.Text.Encoding]::UTF8)
        $m = $raw | ConvertFrom-Json
        $e = [datetime]::MinValue
        if ([datetime]::TryParse([string]$m.end, [ref]$e)) {
            if ($e -gt (Get-Date)) {
                $script:ManualCache.Value = $m
                return $m
            }
            Remove-Item -LiteralPath $script:ManualPath -Force -ErrorAction SilentlyContinue
            $script:ManualCache.Stamp = 'none'
            $script:ManualCache.Value = $null
            return $null
        }
        $script:ManualCache.Value = $null
        return $null
    } catch { $script:ManualCache.Value = $null; return $null }
}

function Get-Dismissed {

    $stamp = Get-Stamp $script:StatePath

    if ($script:StateCache.Stamp -eq $stamp) { return $script:StateCache.Value }

    $script:StateCache.Stamp = $stamp

    if ($stamp -eq 'none') { $script:StateCache.Value = $null; return $null }

    try {
        $s = [System.IO.File]::ReadAllText($script:StatePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $v = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$s.dismissed)) { $v = [string]$s.dismissed }
        $script:StateCache.Value = $v
        return $v
    } catch { $script:StateCache.Value = $null; return $null }
}
function New-ManualLock {
    param([int]$Minutes)
    if ($Minutes -lt 1) { $Minutes = 1 }
    if ($Minutes -gt 480) { $Minutes = 480 }
    $now = Get-Date
    $end = $now.AddMinutes($Minutes)
    $obj = [pscustomobject]@{
        start     = $now.ToString('o')
        end       = $end.ToString('o')
        minutes   = $Minutes
        createdAt = $now.ToString('o')
    }
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($script:ManualPath, ($obj | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true)))
    Write-FocusLog 'manual-lock' ("$Minutes 分钟，至 " + $end.ToString('yyyy-MM-dd HH:mm'))
    return $obj
}

function Set-Dismissed {
    param([string]$Key)
    if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    $obj = [pscustomobject]@{ dismissed = $Key; at = (Get-Date).ToString('o') }
    [System.IO.File]::WriteAllText($script:StatePath, ($obj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($true)))
}

function Get-WindowKey {
    param([datetime]$Start, [datetime]$End)
    return ('{0:yyyyMMddHHmm}-{1:yyyyMMddHHmm}' -f $Start, $End)
}

function Get-ManualWindow {

    param([datetime]$At = (Get-Date))

    $ml = Get-ManualLock
    if (-not $ml) { return $null }

    $ms = [datetime]::MinValue
    $me = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$ml.start, [ref]$ms)) { return $null }
    if (-not [datetime]::TryParse([string]$ml.end, [ref]$me)) { return $null }
    if ($At -lt $ms -or $At -ge $me) { return $null }

    return [pscustomobject]@{
        Active = $true
        Start  = $ms
        End    = $me
        Manual = $true
        Key    = (Get-WindowKey -Start $ms -End $me)
    }
}

function Get-AutoWindow {

    param([object]$Config, [datetime]$At = (Get-Date))

    if (-not $Config) { return $null }
    if ($Config.autoEnabled -eq $false) { return $null }

    $startTs = ConvertTo-TimeOfDay $Config.window.start
    $endTs   = ConvertTo-TimeOfDay $Config.window.end
    if ($null -eq $startTs -or $null -eq $endTs) { return $null }
    if ($startTs -eq $endTs) { return $null }

    $skip = @()
    if ($Config.window.skipDays) { $skip = @($Config.window.skipDays | ForEach-Object { [int]$_ }) }

    $dismissed = Get-Dismissed

    for ($offset = -1; $offset -le 0; $offset++) {
        $d = $At.Date.AddDays($offset)
        $iso = ConvertTo-IsoDay $d.DayOfWeek
        if ($skip -contains $iso) { continue }

        $s = $d.Add($startTs)
        if ($startTs -lt $endTs) {
            $e = $d.Add($endTs)
        } else {
            $e = $d.AddDays(1).Add($endTs)
        }

        if ($At -ge $s -and $At -lt $e) {
            $k = Get-WindowKey -Start $s -End $e
            if ($dismissed -and $dismissed -eq $k) { return $null }
            return [pscustomobject]@{
                Active = $true
                Start  = $s
                End    = $e
                Manual = $false
                Key    = $k
            }
        }
    }
    return $null
}

function Get-ActiveWindows {

    param([object]$Config, [datetime]$At = (Get-Date))

    $out = New-Object System.Collections.Generic.List[object]

    $mw = Get-ManualWindow -At $At
    if ($mw) { [void]$out.Add($mw) }

    $aw = Get-AutoWindow -Config $Config -At $At
    if ($aw) { [void]$out.Add($aw) }

    return ,$out
}

function Get-LockWindow {

    param([object]$Config, [datetime]$At = (Get-Date))

    if (-not $Config) { return $null }

    $all = Get-ActiveWindows -Config $Config -At $At
    if ($all.Count -eq 0) { return $null }

    # 两个都命中时，用结束时间更晚的那个：保证锁屏在两者都过期后才退出
    $pick = $all[0]
    foreach ($w in $all) {
        if ($w.End -gt $pick.End) { $pick = $w }
    }
    return $pick
}

$script:FgCachedPid   = 0
$script:FgCachedName  = ''
$script:FgCachedPath  = ''
$script:FgClassName   = ''

function Get-ForegroundInfo {

    $info = [pscustomobject]@{
        Handle    = [IntPtr]::Zero
        ProcessId = 0
        ProcessName = ''
        ProcessPath = ''
        ClassName = ''
    }
    try {
        $hwnd = [FocusLockNative.Win32]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $info }
        $info.Handle = $hwnd

        $procId = [uint32]0
        [void][FocusLockNative.Win32]::GetWindowThreadProcessId($hwnd, [ref]$procId)
        $info.ProcessId = [int]$procId

        $sb = New-Object System.Text.StringBuilder 256
        [void][FocusLockNative.Win32]::GetClassName($hwnd, $sb, 256)
        $info.ClassName = $sb.ToString()

        if ($procId -gt 0) {
            if ($procId -ne $script:FgCachedPid) {
                $script:FgCachedPid = $procId
                $script:FgCachedName = ''
                $script:FgCachedPath = ''
                try {
                    $proc = Get-Process -Id ([int]$procId) -ErrorAction Stop
                    $script:FgCachedName = $proc.ProcessName
                    try { $script:FgCachedPath = [string]$proc.Path } catch { $script:FgCachedPath = '' }
                } catch {
                    $script:FgCachedName = ''
                }
            }
            $info.ProcessName = $script:FgCachedName
            $info.ProcessPath = $script:FgCachedPath
        }
    } catch { }
    return $info
}

function Test-ForegroundAllowed {

    param([object]$Config, [object]$Info)

    if (-not $Info) { return $false }

    $names = @()
    if ($Config.allow.processNames) { $names = @($Config.allow.processNames) }
    if ($Info.ProcessName) {
        foreach ($kw in $names) {
            if (-not $kw) { continue }
            if ($Info.ProcessName -like "*$kw*") { return $true }
        }
    }

    $kws = @()
    if ($Config.allow.pathKeywords) { $kws = @($Config.allow.pathKeywords) }
    if ($Info.ProcessPath) {
        $lp = $Info.ProcessPath.ToLowerInvariant()
        foreach ($kw in $kws) {
            if (-not $kw) { continue }
            if ($lp.Contains($kw.ToLowerInvariant())) { return $true }
        }
    }
    return $false
}

function Find-DoubaoPath {
    param([object]$Config)

    if ($Config -and $Config.allow -and $Config.allow.exePath) {
        if (Test-Path -LiteralPath $Config.allow.exePath) { return $Config.allow.exePath }
    }

    try {
        $p = Get-Process -Name 'Doubao' -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if (-not $p) { $p = Get-Process -Name 'Doubao' -ErrorAction Stop | Select-Object -First 1 }
        if ($p -and $p.Path -and (Test-Path -LiteralPath $p.Path)) { return $p.Path }
    } catch { }

    $regRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($r in $regRoots) {
        try {
            $items = Get-ItemProperty $r -ErrorAction Stop | Where-Object { $_.DisplayName -match '豆包|Doubao' -and $_.DisplayName -notmatch '工作' }
            foreach ($it in $items) {
                if ($it.DisplayIcon) {
                    $icon = [string]$it.DisplayIcon
                    $icon = $icon.Trim('"')
                    if ($icon -match '^(.+?\.exe)') {
                        $cand = $matches[1]
                        if (Test-Path -LiteralPath $cand) { return $cand }
                    }
                }
            }
        } catch { }
    }

    $smRoots = @(
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
    )
    foreach ($root in $smRoots) {
        if (-not (Test-Path $root)) { continue }
        try {
            $lnk = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match '豆包' -and $_.Name -notmatch '卸载|工作' } |
                   Select-Object -First 1
            if ($lnk) {
                $sh = New-Object -ComObject WScript.Shell
                $t = $sh.CreateShortcut($lnk.FullName).TargetPath
                if ($t -and (Test-Path -LiteralPath $t)) { return $t }
            }
        } catch { }
    }

    $common = @(
        "$env:LOCALAPPDATA\Programs\Doubao\Doubao.exe",
        "$env:LOCALAPPDATA\Doubao\Doubao.exe",
        "$env:ProgramFiles\Doubao\Doubao.exe",
        'D:\LenovoSoftstore\Install\doubao\app\Doubao.exe'
    )
    foreach ($c in $common) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

function Start-DoubaoApp {

    param([object]$Config, [switch]$AllowLaunch)

    $procs = @()
    try { $procs = @(Get-Process -Name 'Doubao' -ErrorAction Stop) } catch { $procs = @() }

    if ($procs.Count -gt 0) {
        return ($procs.Count -gt 0)
    }

    if (-not $AllowLaunch) { return $false }

    $exe = Find-DoubaoPath -Config $Config
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        try {
            Start-Process -FilePath $exe -ErrorAction Stop | Out-Null
            return $true
        } catch {
            Write-FocusLog 'doubao-start-fail' $_.Exception.Message
        }
    }
    return $false
}

$script:PolicyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'

$script:PolicyUnavailable = $false

function Set-TaskMgrBlocked {

    param([bool]$Blocked)
    if ($script:PolicyUnavailable -and $Blocked) { return }
    try {
        if ($Blocked) {

            $cur = $null
            try { $cur = (Get-ItemProperty -Path $script:PolicyKey -Name 'DisableTaskMgr' -ErrorAction Stop).DisableTaskMgr } catch { }
            if ($cur -ne 1) {
                if (-not (Test-Path $script:PolicyKey)) { New-Item -Path $script:PolicyKey -Force -ErrorAction Stop | Out-Null }
                New-ItemProperty -Path $script:PolicyKey -Name 'DisableTaskMgr' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            }
        } else {
            if (Test-Path $script:PolicyKey) {
                Remove-ItemProperty -Path $script:PolicyKey -Name 'DisableTaskMgr' -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        if ($Blocked) {
            $script:PolicyUnavailable = $true
            Write-FocusLog 'policy-unavailable' '注册表策略不可写，改用进程级拦截'
        }
    }
}

function Set-TaskbarHidden {

    param([bool]$Hidden)
    try {
        $flag = Join-Path $script:DataDir 'taskbar.hidden'
        if ($Hidden) {
            try {
                if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
                [System.IO.File]::WriteAllText($flag, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($true)))
            } catch { }
        } else {
            try { if (Test-Path $flag) { Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue } } catch { }
        }

        # unlock 模式下不会预先 Initialize-Native，这里自己补上
        if (-not ('FocusLockNative.Win32' -as [type])) { [void](Initialize-Native) }
        if (-not ('FocusLockNative.Win32' -as [type])) { return }
        $sw = 0
        if (-not $Hidden) { $sw = 5 }
        foreach ($cls in @('Shell_TrayWnd', 'Shell_SecondaryTrayWnd')) {
            $h = [FocusLockNative.Win32]::FindWindow($cls, $null)
            if ($h -ne [IntPtr]::Zero) {
                [void][FocusLockNative.Win32]::ShowWindow($h, $sw)
            }
        }
    } catch {
        Write-FocusLog 'taskbar-fail' $_.Exception.Message
    }
}

function New-DigitChallenge {
    param([int]$Groups, [int]$PerGroup)

    $total = $Groups * $PerGroup
    $bytes = New-Object byte[] $total
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    $digits = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $total; $i++) {
        [void]$digits.Append([string]([int]$bytes[$i] % 10))
    }
    $flat = $digits.ToString()

    $groupsList = New-Object System.Collections.ArrayList
    for ($g = 0; $g -lt $Groups; $g++) {
        [void]$groupsList.Add($flat.Substring($g * $PerGroup, $PerGroup))
    }

    $order = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Groups; $i++) { [void]$order.Add($i) }
    $rng2 = [System.Random]::new()
    for ($i = $order.Count - 1; $i -gt 0; $i--) {
        $j = $rng2.Next(0, $i + 1)
        $t = $order[$i]; $order[$i] = $order[$j]; $order[$j] = $t
    }

    return [pscustomobject]@{
        Groups    = @($groupsList)
        Order     = @($order)
        PerGroup  = $PerGroup
        Total     = $total
    }
}

function Format-Digits {
    param([string]$Digits)
    return (($Digits.ToCharArray()) -join ' ')
}

function New-DefaultConfig {
    $doubao = $null
    try { $doubao = Find-DoubaoPath -Config $null } catch { }

    return [pscustomobject]@{
        version     = 1
        autoEnabled = $true
        activeFrom  = '2020-01-01T00:00:00+08:00'
        window     = [pscustomobject]@{
            start    = '00:00'
            end      = '06:00'
            skipDays = @(6)
        }
        challenge  = [pscustomobject]@{
            groups         = 100
            digitsPerGroup = 10
        }
        release    = [pscustomobject]@{
            minutes = 30
        }
        allow      = [pscustomobject]@{
            processNames = @('Doubao', 'doubao', '豆包')
            pathKeywords = @('doubao')
            exePath      = $doubao
        }
        safety     = [pscustomobject]@{
            maxLockHours = 10
        }
        ui         = [pscustomobject]@{
            title    = '免打扰时间'
            subtitle = '本机现在只允许使用「豆包」'
        }
    }
}

function Get-WScriptExe {
    foreach ($c in @("$env:SystemRoot\System32\wscript.exe", 'C:\Windows\System32\wscript.exe')) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return 'wscript.exe'
}

function Set-AutostartEntry {

    # Run 键是「登录即触发」的那一路：Explorer 一起来就执行，不受任务计划节流影响
    param([bool]$Enable)

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    try {
        if (-not $Enable) {
            Remove-ItemProperty -Path $runKey -Name 'FocusLock' -Force -ErrorAction SilentlyContinue
            return
        }
        if (-not (Test-Path $runKey)) { New-Item -Path $runKey -Force | Out-Null }

        $vbs = Join-Path $script:DataDir 'tick.vbs'
        if (Test-Path -LiteralPath $vbs) {
            $value = '"{0}" "{1}"' -f (Get-WScriptExe), $vbs
        } else {
            $value = '"{0}" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Sta -File "{1}" -Mode tick' -f (Get-PowerShellExe), (Join-Path $script:DataDir 'FocusLock.ps1')
        }
        New-ItemProperty -Path $runKey -Name 'FocusLock' -Value $value -PropertyType String -Force | Out-Null

        # 清掉启动应用里的禁用记录，否则 Windows 会跳过这个 Run 键
        try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name 'FocusLock' -Force -ErrorAction SilentlyContinue } catch { }
    } catch {
        Write-FocusLog 'autostart-fail' $_.Exception.Message
    }
}

function Register-FocusTasks {

    # Run 键 + 计划任务两条都要：Run 键负责"登录那一刻"，任务负责每分钟轮询和兜底
    $vbsMain = Join-Path $script:DataDir 'tick.vbs'

    if (Test-Path -LiteralPath $vbsMain) {
        $action = New-ScheduledTaskAction -Execute (Get-WScriptExe) -Argument ('"{0}"' -f $vbsMain)
    } else {
        $sp = Join-Path $script:DataDir 'FocusLock.ps1'
        $action = New-ScheduledTaskAction -Execute (Get-PowerShellExe) -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Mode tick' -f $sp)
    }

    $user = "$env:USERDOMAIN\$env:USERNAME"

    $triggers = @()
    try { $triggers += New-ScheduledTaskTrigger -AtLogOn -User $user } catch { $triggers += New-ScheduledTaskTrigger -AtLogOn }
    $triggers += New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)

    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -Priority 10
    $settings.Hidden = $true

    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Force | Out-Null

    Set-AutostartEntry -Enable $true
}

function Get-AutoWindowRange {

    # 返回与 [$From, $To] 有交集（含首尾相接）的熬夜锁区间
    param([object]$Config, [datetime]$From, [datetime]$To)

    if (-not $Config) { return $null }
    if ($Config.autoEnabled -eq $false) { return $null }

    $startTs = ConvertTo-TimeOfDay $Config.window.start
    $endTs   = ConvertTo-TimeOfDay $Config.window.end
    if ($null -eq $startTs -or $null -eq $endTs) { return $null }
    if ($startTs -eq $endTs) { return $null }

    $skip = @()
    if ($Config.window.skipDays) { $skip = @($Config.window.skipDays | ForEach-Object { [int]$_ }) }

    for ($offset = -2; $offset -le 2; $offset++) {
        $d = $From.Date.AddDays($offset)
        $iso = ConvertTo-IsoDay $d.DayOfWeek
        if ($skip -contains $iso) { continue }

        $s = $d.Add($startTs)
        if ($startTs -lt $endTs) {
            $e = $d.Add($endTs)
        } else {
            $e = $d.AddDays(1).Add($endTs)
        }

        if ($s -le $To -and $From -le $e) {
            return [pscustomobject]@{
                Active = $true
                Start  = $s
                End    = $e
                Manual = $false
                Key    = (Get-WindowKey -Start $s -End $e)
            }
        }
    }
    return $null
}

function Get-LockChainEnd {

    # 从当前时刻出发，沿着「首尾相接或重叠」的区间一路往后延，
    # 返回整条连通链的终点。倒计时显示这个终点，而不是当前那一段的终点。
    #
    # 例：快速锁 17:55-18:10 + 熬夜锁 18:00-19:00
    #     17:55 时返回 19:00（18:10 那一刻熬夜锁接上了）
    param([object]$Config, [datetime]$At = (Get-Date))

    $win = Get-LockWindow -Config $Config -At $At
    if (-not $win) { return $null }

    $end = $win.End

    for ($i = 0; $i -lt 32; $i++) {
        # 看 $end 那一刻还有没有区间覆盖（左闭右开，所以相接的会命中）
        $next = Get-LockWindow -Config $Config -At $end
        if (-not $next) { break }
        if ($next.End -le $end) { break }
        $end = $next.End
    }

    return $end
}
function Get-UnlockSet {

    # 算出解锁要解除哪些区间。
    # 规则：两个区间只要有交集（并集连通），在并集内任何时刻解锁都同时解除两个。
    param([object]$Config, [datetime]$At = (Get-Date))

    $res = @{ Manual = $false; Auto = $false; ManualWin = $null; AutoWin = $null }

    $mw = Get-ManualWindow -At $At
    $aw = Get-AutoWindow -Config $Config -At $At

    # 1) 两个都覆盖当前
    if ($mw -and $aw) {
        $res.Manual = $true; $res.Auto = $true
        $res.ManualWin = $mw; $res.AutoWin = $aw
        return $res
    }

    # 2) 只有定时锁覆盖当前：看熬夜锁有没有跟它相交
    if ($mw) {
        $res.Manual = $true
        $res.ManualWin = $mw
        $near = Get-AutoWindowRange -Config $Config -From $mw.Start -To $mw.End
        if ($near) { $res.Auto = $true; $res.AutoWin = $near }
        return $res
    }

    # 3) 只有熬夜锁覆盖当前：看定时锁有没有跟它相交
    if ($aw) {
        $res.Auto = $true
        $res.AutoWin = $aw
        $ml = Get-ManualLock
        if ($ml) {
            $ms = [datetime]::MinValue
            $me = [datetime]::MinValue
            if ([datetime]::TryParse([string]$ml.start, [ref]$ms) -and [datetime]::TryParse([string]$ml.end, [ref]$me)) {
                if ($ms -le $aw.End -and $aw.Start -le $me) {
                    $res.Manual = $true
                    $res.ManualWin = [pscustomobject]@{
                        Active = $true
                        Start  = $ms
                        End    = $me
                        Manual = $true
                        Key    = (Get-WindowKey -Start $ms -End $me)
                    }
                }
            }
        }
        return $res
    }

    return $res
}
function Invoke-Unlock {

    $cfg = Get-FocusConfig
    $now = Get-Date
    $did = @()

    # 两个区间只要有交集（并集连通），在并集内任何时刻解锁都同时解除两个
    $set = Get-UnlockSet -Config $cfg -At $now

    # 解锁只认"看得见的锁"：遮罩的显示时刻必须早于这次双击。
    # 点得比遮罩早（开机那几秒、遮罩崩掉重启的空窗）都算抢跑，不写解锁状态，直接把遮罩补起来
    if (Get-LockWindow -Config $cfg -At $now) {
        $clickAt = (Get-Process -Id $PID).StartTime
        $readyAt = Get-LockUiReadyAt
        if (($null -eq $readyAt) -or ($readyAt -gt $clickAt)) {
            $detail = '遮罩 {0}' -f $(if ($readyAt) { $readyAt.ToString('HH:mm:ss') } else { '无记录' })
            Write-FocusLog 'unlock-refused' $detail
            Write-Host '正在锁定：遮罩启动后才能解锁。' -ForegroundColor Yellow
            [void](Start-FocusChild -ChildMode 'lock-ui')
            [void](Start-FocusChild -ChildMode 'guard')
            return
        }
    }
    if ($set.Manual) {
        Remove-Item -LiteralPath $script:ManualPath -Force -ErrorAction SilentlyContinue
        $did += '定时区间'
    }
    if ($set.Auto -and $set.AutoWin) {
        Set-Dismissed -Key $set.AutoWin.Key
        $did += '熬夜区间'
    }
    if ($did.Count -gt 0) {
        Write-FocusLog 'unlock-cli' (($did -join ' + ') + ' 已解除')
        Write-Host (($did -join '、') + ' 已解除。') -ForegroundColor Green
    } else {
        Clear-FocusState
        Write-Host '当前不在锁定状态。' -ForegroundColor DarkGray
    }

    # 先清策略：Stop-Process -Force 不会执行 finally，策略值只能在这里兜底
    Set-TaskMgrBlocked -Blocked $false

    # 连续多轮清理：guard 可能在几百毫秒内抢着拉起新的锁屏，单次杀不干净
    for ($i = 0; $i -lt 5; $i++) {
        $left = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-Mode\s+(lock-ui|lock|guard)' })
        if ($left.Count -eq 0 -and $i -gt 0) { break }
        foreach ($x in $left) {
            try { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Milliseconds 600
    }

    Set-TaskbarHidden -Hidden $false
    Write-FocusLog 'unlock-done' ''
}


# ---- 设置 / 选时长两个对话框共用的绘图助手（原来各自复制了一份） ----
function Px { param([double]$v) return [int]($v * $script:DlgScale) }

function P-Region {
    param($W, $H, $R)
    $d = $R * 2
    if ($d -gt $W) { $d = $W }
    if ($d -gt $H) { $d = $H }
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $d, $d, 180, 90)
    $p.AddArc($W - $d - 1, 0, $d, $d, 270, 90)
    $p.AddArc($W - $d - 1, $H - $d - 1, $d, $d, 0, 90)
    $p.AddArc(0, $H - $d - 1, $d, $d, 90, 90)
    $p.CloseFigure()
    return (New-Object System.Drawing.Region($p))
}

function P-Label {
    param($T, $Size, $Color, $Bold = $false)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $T
    $l.AutoSize = $true
    $l.ForeColor = $Color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $st = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $st = [System.Drawing.FontStyle]::Bold }
    try { $l.Font = New-Object System.Drawing.Font('幼圆', $Size, $st) } catch { }
    return $l
}

function P-Btn {
    param($T, $W, $H, $Back, $Fore, $Size)
    $w = Px $W
    $h = Px $H
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $T
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Back
    $b.ForeColor = $Fore
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    try { $b.Font = New-Object System.Drawing.Font('幼圆', $Size, [System.Drawing.FontStyle]::Bold) } catch { }
    try { $b.Region = P-Region $w $h (Px 12) } catch { }
    return $b
}

function Invoke-Settings {

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $S = 1.0
    try {
        $ap = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction SilentlyContinue).AppliedDPI
        if ($ap) { $S = [double]$ap / 96.0 }
    } catch { }
    if ($S -lt 1.0) { $S = 1.0 }
    $script:DlgScale = $S

    $C = @{
        Bg     = [System.Drawing.Color]::FromArgb(255, 246, 236)
        Card   = [System.Drawing.Color]::White
        Text   = [System.Drawing.Color]::FromArgb(91, 74, 111)
        Muted  = [System.Drawing.Color]::FromArgb(170, 156, 190)
        Accent = [System.Drawing.Color]::FromArgb(255, 138, 173)
        Blue   = [System.Drawing.Color]::FromArgb(118, 199, 226)
        Line   = [System.Drawing.Color]::FromArgb(252, 228, 216)
        Input  = [System.Drawing.Color]::FromArgb(243, 238, 255)
    }


    $cfg = Get-FocusConfig
    if (-not $cfg) {
        $cfg = New-DefaultConfig
        Save-FocusConfig -Config $cfg
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'FocusLock 设置'
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.ClientSize = New-Object System.Drawing.Size((Px 460), (Px 440))
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false
    $form.BackColor = $C.Bg
    $form.ForeColor = $C.Text

    $X = Px 28
    $lTitle = P-Label '熬夜锁时段' 18 $C.Text $true
    $lTitle.Left = $X; $lTitle.Top = Px 18

    $lFrom = P-Label '从' 11 $C.Muted
    $lFrom.Left = $X; $lFrom.Top = Px 68

    $mkTimeBox = {
        param([string]$Val)
        $w = Px 96
        $h = Px 40
        $pnl = New-Object System.Windows.Forms.Panel
        $pnl.Size = New-Object System.Drawing.Size($w, $h)
        $pnl.BackColor = $C.Input
        try { $pnl.Region = P-Region $w $h (Px 10) } catch { }
        $tx = New-Object System.Windows.Forms.TextBox
        $tx.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $tx.BackColor = $C.Input
        $tx.ForeColor = $C.Text
        $tx.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
        $tx.Width = Px 76
        $tx.Left = Px 10
        $tx.Top = Px 8
        $tx.Text = $Val
        try { $tx.Font = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold) } catch { }
        $pnl.Controls.Add($tx)
        return @{ Panel = $pnl; Box = $tx }
    }

    $tbFrom = & $mkTimeBox ([string]$cfg.window.start)
    $tbFrom.Panel.Left = Px 66; $tbFrom.Panel.Top = Px 58

    $lTo = P-Label '到' 11 $C.Muted
    $lTo.Left = Px 178; $lTo.Top = Px 68

    $tbTo = & $mkTimeBox ([string]$cfg.window.end)
    $tbTo.Panel.Left = Px 210; $tbTo.Panel.Top = Px 58

    $lTip = P-Label '格式 HH:mm，例如 00:00 到 06:00' 8 $C.Muted
    $lTip.Left = $X; $lTip.Top = Px 108

    $sep1 = New-Object System.Windows.Forms.Panel
    $sep1.Size = New-Object System.Drawing.Size((Px 404), [Math]::Max(1, (Px 2)))
    $sep1.BackColor = $C.Line
    $sep1.Left = $X; $sep1.Top = Px 138

    $lWeek = P-Label '哪几天上锁' 11 $C.Text $true
    $lWeek.Left = $X; $lWeek.Top = Px 152

    $dayNames = @('周一', '周二', '周三', '周四', '周五', '周六', '周日')
    $skip = @()
    if ($cfg.window.skipDays) { $skip = @($cfg.window.skipDays | ForEach-Object { [int]$_ }) }
    $checks = @()
    for ($i = 0; $i -lt 7; $i++) {
        $iso = $i + 1
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $dayNames[$i]
        $cb.AutoSize = $true
        $cb.ForeColor = $C.Text
        $cb.BackColor = [System.Drawing.Color]::Transparent
        $cb.Left = Px (28 + ($i * 58))
        $cb.Top = Px 188
        try { $cb.Font = New-Object System.Drawing.Font('幼圆', 11) } catch { }
        $cb.Checked = -not ($skip -contains $iso)
        $checks += ,@($iso, $cb)
        $form.Controls.Add($cb)
    }

    $sep2 = New-Object System.Windows.Forms.Panel
    $sep2.Size = New-Object System.Drawing.Size((Px 404), [Math]::Max(1, (Px 2)))
    $sep2.BackColor = $C.Line
    $sep2.Left = $X; $sep2.Top = Px 282


    $bSave = P-Btn '保存' 120 44 $C.Accent ([System.Drawing.Color]::White) 12
    $bSave.Left = $X; $bSave.Top = Px 312

    $bCancel = P-Btn '取消' 120 44 $C.Input $C.Text 12
    $bCancel.Left = Px 164; $bCancel.Top = Px 312

    $lMsg = P-Label '' 9 $C.Muted
    $lMsg.Left = Px 300; $lMsg.Top = Px 324

    $lFoot = P-Label '改完立即生效，不用重装。' 8 $C.Muted
    $lFoot.Left = $X; $lFoot.Top = Px 382

    foreach ($ctl in @($lTitle, $lFrom, $tbFrom.Panel, $lTo, $tbTo.Panel, $lTip, $sep1, $lWeek, $sep2, $bSave, $bCancel, $lMsg, $lFoot)) {
        $form.Controls.Add($ctl)
    }

    $bSave.Add_Click({
        try {
            $hs = [string]$tbFrom.Box.Text
            $he = [string]$tbTo.Box.Text
            if ($hs -notmatch '^\d{1,2}:\d{2}$' -or $he -notmatch '^\d{1,2}:\d{2}$') {
                $lMsg.Text = '时间格式不对'
                $lMsg.ForeColor = $C.Accent
                return
            }
            $mins = 0
            $skipDays = @()
            foreach ($pair in $checks) {
                if (-not $pair[1].Checked) { $skipDays += $pair[0] }
            }

            $c2 = Get-FocusConfig
            if (-not $c2) { $c2 = New-DefaultConfig }
            $c2.window.start = $hs
            $c2.window.end = $he
            $c2.window.skipDays = @($skipDays)
            Save-FocusConfig -Config $c2

            # 保存设置 = 主动重置：清掉"今天这份已作废"的记录，
            # 这样如果当前时间落在区间内，tick 会立刻重新锁上。
            Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue
            Write-FocusLog 'settings-saved' ("$hs-$he skip=" + ($skipDays -join ',') + " release=$mins")

            $lMsg.Text = '已保存'
            $lMsg.ForeColor = $C.Blue

            # 立刻按新时段判断一次：起完全独立的进程，UI 一秒都不等
            try {
                $tv = Join-Path $script:DataDir 'tick.vbs'
                if (Test-Path -LiteralPath $tv) {
                    Start-Process -FilePath (Get-WScriptExe) -ArgumentList "`"$tv`"" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
                }
            } catch { }
            Start-Sleep -Milliseconds 300
            $form.Close()
        } catch {
            $lMsg.Text = '保存失败'
            $lMsg.ForeColor = $C.Accent
        }
    })

    $bCancel.Add_Click({ $form.Close() })

    # 抢焦点：某些启动方式下窗口会躲在后台，看起来像"没弹出来"
    $form.Add_Shown({
        try {
            $form.Activate()
            $form.BringToFront()
            $form.TopMost = $true
            $form.TopMost = $false
            [void][FocusLockNative.Win32]::SetForegroundWindow($form.Handle)
        } catch { }
    })

    try { [System.Windows.Forms.Application]::Run($form) }
    finally { try { $form.Dispose() } catch { } }
}

function Get-NextBoundary {

    param([object]$Config, [datetime]$At = (Get-Date))

    $list = New-Object System.Collections.Generic.List[datetime]

    # 1) 手动区间（定时锁）：开始和结束都是切换点
    $ml = Get-ManualLock
    if ($ml) {
        $ms = [datetime]::MinValue
        $me = [datetime]::MinValue
        if ([datetime]::TryParse([string]$ml.start, [ref]$ms) -and [datetime]::TryParse([string]$ml.end, [ref]$me)) {
            if ($ms -gt $At) { [void]$list.Add($ms) }
            if ($me -gt $At) { [void]$list.Add($me) }
        }
    }

    # 2) 熬夜锁：把未来两天的窗口边界都算出来
    if ($Config -and $Config.autoEnabled -ne $false) {
        $startTs = ConvertTo-TimeOfDay $Config.window.start
        $endTs   = ConvertTo-TimeOfDay $Config.window.end
        if ($null -ne $startTs -and $null -ne $endTs -and $startTs -ne $endTs) {
            $skip = @()
            if ($Config.window.skipDays) { $skip = @($Config.window.skipDays | ForEach-Object { [int]$_ }) }
            for ($off = 0; $off -le 2; $off++) {
                $d = $At.Date.AddDays($off)
                $iso = ConvertTo-IsoDay $d.DayOfWeek
                if ($skip -contains $iso) { continue }

                $s = $d.Add($startTs)
                if ($startTs -lt $endTs) {
                    $e = $d.Add($endTs)
                } else {
                    $e = $d.AddDays(1).Add($endTs)
                }
                if ($s -gt $At) { [void]$list.Add($s) }
                if ($e -gt $At) { [void]$list.Add($e) }
            }
        }
    }

    if ($list.Count -eq 0) { return $null }
    $sorted = @($list | Sort-Object)
    return $sorted[0]
}
function Invoke-LockAsk {

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $S = 1.0
    try {
        $ap = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction SilentlyContinue).AppliedDPI
        if ($ap) { $S = [double]$ap / 96.0 }
    } catch { }
    if ($S -lt 1.0) { $S = 1.0 }
    $script:DlgScale = $S

    $C = @{
        Bg     = [System.Drawing.Color]::FromArgb(255, 246, 236)
        Input  = [System.Drawing.Color]::FromArgb(243, 238, 255)
        Text   = [System.Drawing.Color]::FromArgb(91, 74, 111)
        Muted  = [System.Drawing.Color]::FromArgb(170, 156, 190)
        Accent = [System.Drawing.Color]::FromArgb(255, 138, 173)
    }


    $picked = 0

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'FocusLock'
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.ClientSize = New-Object System.Drawing.Size((Px 420), (Px 300))
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = $C.Bg
    $form.ForeColor = $C.Text

    $lTitle = P-Label '锁多久？' 20 $C.Text $true
    $lTitle.Left = Px 30; $lTitle.Top = Px 24

    $quick = @(15, 30, 60, 120)
    $qbtns = @()
    for ($i = 0; $i -lt 4; $i++) {
        $b = P-Btn (([string]$quick[$i]) + ' 分钟') 84 46 $C.Input $C.Text 11
        $b.Left = Px (30 + ($i * 92))
        $b.Top = Px 70
        $idx = $quick[$i]
        $b.Tag = $idx
        $qbtns += $b
        $form.Controls.Add($b)
    }

    $lCustom = P-Label '自定义' 11 $C.Muted
    $lCustom.Left = Px 30; $lCustom.Top = Px 140

    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Size = New-Object System.Drawing.Size((Px 120), (Px 42))
    $pnl.Left = Px 88; $pnl.Top = Px 132
    $pnl.BackColor = $C.Input
    try { $pnl.Region = P-Region (Px 120) (Px 42) (Px 10) } catch { }
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $tb.BackColor = $C.Input
    $tb.ForeColor = $C.Text
    $tb.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
    $tb.Width = Px 96
    $tb.Left = Px 12
    $tb.Top = Px 9
    $tb.Text = '30'
    try { $tb.Font = New-Object System.Drawing.Font('Consolas', 14, [System.Drawing.FontStyle]::Bold) } catch { }
    $pnl.Controls.Add($tb)

    $lUnit = P-Label '分钟' 11 $C.Muted
    $lUnit.Left = Px 216; $lUnit.Top = Px 140

    $lHint = P-Label '期间只能用豆包　·　1000 位数字 或 unlock.cmd 可解' 9 $C.Muted
    $lHint.Left = Px 30; $lHint.Top = Px 190

    $bOK = P-Btn '开始' 110 44 $C.Accent ([System.Drawing.Color]::White) 12
    $bOK.Left = Px 30; $bOK.Top = Px 226

    $bNo = P-Btn '取消' 110 44 $C.Input $C.Text 12
    $bNo.Left = Px 156; $bNo.Top = Px 226

    foreach ($ctl in @($lTitle, $lCustom, $pnl, $lUnit, $lHint, $bOK, $bNo)) { $form.Controls.Add($ctl) }

    # 快捷按钮：点了直接填进输入框
    foreach ($b in $qbtns) {
        $b.Add_Click({
            param($sender, $e)
            $tb.Text = [string]$sender.Tag
            $tb.Focus()
            $tb.SelectAll()
        })
    }

    $bOK.Add_Click({
        $v = 0
        if ([int]::TryParse($tb.Text.Trim(), [ref]$v)) {
            if ($v -ge 1 -and $v -le 1440) {
                $script:AskResult = $v
                $form.Close()
                return
            }
        }
        $lHint.Text = '请输入 1 到 1440 之间的整数'
        $lHint.ForeColor = $C.Accent
    })

    $bNo.Add_Click({ $script:AskResult = 0; $form.Close() })
    $tb.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $bOK.PerformClick() }
    })

    $script:AskResult = 0

    $form.Add_Shown({
        try {
            $form.Activate()
            $form.BringToFront()
            $form.TopMost = $true
            $form.TopMost = $false
            [void][FocusLockNative.Win32]::SetForegroundWindow($form.Handle)
        } catch { }
        $tb.Focus()
        $tb.SelectAll()
    })

    try { [System.Windows.Forms.Application]::Run($form) }
    finally { try { $form.Dispose() } catch { } }

    $mins = [int]$script:AskResult
    if ($mins -le 0) {
        Write-FocusLog 'lock-ask' '用户取消'
        return
    }

    [void](New-ManualLock -Minutes $mins)
    Write-FocusLog 'lock-ask' ("锁定 $mins 分钟")

    $cfg = Get-FocusConfig
    if (-not (Test-NamedMutexHeld $script:MutexUI)) {
        [void](Start-FocusChild -ChildMode 'lock-ui')
        [void](Start-FocusChild -ChildMode 'guard')
    }
}
function Invoke-TickCore {

    $cfg = Get-FocusConfig
    if (-not $cfg) { return }

    $now = Get-Date
    $win = Get-LockWindow -Config $cfg -At $now

    if (-not $win) {
        # 算出下一个状态切换的确切时刻，睡到那一刻（不是每 N 秒问一次）
        $next = Get-NextBoundary -Config $cfg -At $now
        if ($next) {
            $gapMs = ($next - $now).TotalMilliseconds
            if ($gapMs -gt 0 -and $gapMs -le 90000) {
                Start-Sleep -Milliseconds ([int]$gapMs + 120)
                $now = Get-Date
                $win = Get-LockWindow -Config $cfg -At $now
            }
        }
    }

    if (-not $win) {
        # 解锁态：只有确实留下痕迹时才去恢复，不再每个 tick 都加载 native
        if (-not (Test-NamedMutexHeld $script:MutexUI)) {
            $pol = $null
            try { $pol = (Get-ItemProperty -Path $script:PolicyKey -Name 'DisableTaskMgr' -ErrorAction Stop).DisableTaskMgr } catch { }
            if ($pol -eq 1) { Set-TaskMgrBlocked -Blocked $false }

            $tbFlag = Join-Path $script:DataDir 'taskbar.hidden'
            if (Test-Path -LiteralPath $tbFlag) {
                Set-TaskbarHidden -Hidden $false
                Write-FocusLog 'taskbar-restored' ''
            }
        }
        return
    }

    $uiAlive = Test-NamedMutexHeld $script:MutexUI
    $gdAlive = Test-NamedMutexHeld $script:MutexGuard

    if (-not $gdAlive) { [void](Start-FocusChild -ChildMode 'guard') }
    if (-not $uiAlive) { [void](Start-FocusChild -ChildMode 'lock-ui') }
}

function Invoke-Tick {
    # 超过 800ms 才记一笔，方便下次排查开机/唤醒时的卡顿
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { Invoke-TickCore } finally {
        if ($sw.ElapsedMilliseconds -gt 800) {
            Write-FocusLog 'tick-slow' ("{0} ms" -f $sw.ElapsedMilliseconds)
        }
    }
}

function Invoke-Guard {
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, $script:MutexGuard, [ref]$createdNew)
    if (-not $createdNew) { return }

    $cfg = Get-FocusConfig
    if (-not $cfg) { $mutex.Dispose(); return }

    Write-FocusLog 'guard-start' ''
    $started = Get-Date
    $lastUiCheck = Get-Date

    try {
        while ($true) {
            Start-Sleep -Milliseconds 900

            $now = Get-Date
            $cfg = Get-FocusConfig
            if (-not $cfg) { break }

            $win = Get-LockWindow -Config $cfg -At $now
            if (-not $win) { break }

            $maxH = 10
            if ($cfg.safety -and $cfg.safety.maxLockHours) { $maxH = [double]$cfg.safety.maxLockHours }
            if (($now - $started).TotalHours -gt $maxH) {
                Write-FocusLog 'safety-release' "连续锁定超过 $maxH 小时，自动释放"
                Set-TaskMgrBlocked -Blocked $false
                break
            }

            if (-not (Test-NamedMutexHeld $script:MutexUI)) {
                [void](Start-FocusChild -ChildMode 'lock-ui')
            }
        }
    } finally {
        Write-FocusLog 'guard-exit' ''
        try { Set-TaskMgrBlocked -Blocked $false } catch { }
        try { $mutex.Dispose() } catch { }
    }
}

function Confirm-Shutdown {

    param([object]$Colors)

    # 自己算缩放，不依赖调用方的局部变量
    $u2 = 1.0
    try {
        $ap = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction SilentlyContinue).AppliedDPI
        if ($ap) { $u2 = [double]$ap / 96.0 }
    } catch { }
    if ($u2 -lt 1.0) { $u2 = 1.0 }

    $colCard = [System.Drawing.Color]::FromArgb(24, 28, 40)
    $colText = [System.Drawing.Color]::FromArgb(200, 198, 194)
    $colMuted = [System.Drawing.Color]::FromArgb(104, 110, 128)
    if ($Colors) {
        try { $colCard = $Colors.Card; $colText = $Colors.Text; $colMuted = $Colors.Muted } catch { }
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '确认关机'
    $dlg.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dlg.ClientSize = New-Object System.Drawing.Size([int](380 * $u2), [int](216 * $u2))
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $colCard
    $dlg.ForeColor = $colText
    $dlg.TopMost = $true

    function New-DlgLabel {
        param([string]$T, [single]$Sz, [System.Drawing.Color]$C, [switch]$Bold)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $T
        $l.AutoSize = $true
        $l.BackColor = [System.Drawing.Color]::Transparent
        $l.ForeColor = $C
        $st = [System.Drawing.FontStyle]::Regular
        if ($Bold) { $st = [System.Drawing.FontStyle]::Bold }
        try { $l.Font = New-Object System.Drawing.Font('幼圆', $Sz, $st) } catch { }
        return $l
    }

    function New-DlgButton {
        param([string]$T, [int]$W, [int]$H, [System.Drawing.Color]$Back, [System.Drawing.Color]$Fore, [single]$Sz)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $T
        $b.Size = New-Object System.Drawing.Size($W, $H)
        $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $b.FlatAppearance.BorderSize = 0
        $b.BackColor = $Back
        $b.ForeColor = $Fore
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        try { $b.Font = New-Object System.Drawing.Font('幼圆', $Sz, [System.Drawing.FontStyle]::Bold) } catch { }
        return $b
    }

    $lQ = New-DlgLabel -T '真的要关机吗？' -Sz 17 -C $colText -Bold
    $lQ.Left = [int](30 * $u2); $lQ.Top = [int](28 * $u2)

    $lWarn = New-DlgLabel -T '未保存的文档会丢失，无法撤销。' -Sz 11 -C $colMuted
    $lWarn.Left = [int](30 * $u2); $lWarn.Top = [int](74 * $u2)

    $bYes = New-DlgButton -T '关机' -W ([int](130 * $u2)) -H ([int](44 * $u2)) -Back ([System.Drawing.Color]::FromArgb(150, 76, 84)) -Fore ([System.Drawing.Color]::FromArgb(240, 232, 230)) -Sz 12
    $bYes.Left = [int](30 * $u2); $bYes.Top = [int](136 * $u2)

    $bNo = New-DlgButton -T '取消' -W ([int](130 * $u2)) -H ([int](44 * $u2)) -Back ([System.Drawing.Color]::FromArgb(42, 48, 62)) -Fore $colText -Sz 12
    $bNo.Left = [int](180 * $u2); $bNo.Top = [int](136 * $u2)

    $dlg.Controls.Add($lQ)
    $dlg.Controls.Add($lWarn)
    $dlg.Controls.Add($bYes)
    $dlg.Controls.Add($bNo)

    $dlg.KeyPreview = $true

    $bYes.Add_Click({ $dlg.Tag = 'yes'; $dlg.Close() })
    $bNo.Add_Click({ $dlg.Tag = 'no'; $dlg.Close() })
    $dlg.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $dlg.Tag = 'no'; $dlg.Close() }
    })

    $dlg.Add_Shown({
        try {
            $dlg.Activate()
            $dlg.BringToFront()
            if ('FocusLockNative.Win32' -as [type]) { [void][FocusLockNative.Win32]::SetForegroundWindow($dlg.Handle) }
        } catch { }
        try { $bNo.Focus() } catch { }
    })

    # 用 ShowDialog 而不是 Application::Run ——
    # 锁屏本身已经跑着 Application::Run，再嵌一层会把主消息循环搞坏，
    # 之后在事件里调 Start-Process 会抛异常。
    try {
        [void]$dlg.ShowDialog()
    } catch {
        Write-FocusLog 'confirm-fail' $_.Exception.Message
        return $false
    } finally {
        try { $dlg.Dispose() } catch { }
    }

    return ([string]$dlg.Tag -eq 'yes')
}
function Get-WallpaperPath {

    # 桌面壁纸路径（用户级可读）。Windows 的"锁屏图"放在
    # %ProgramData%\Microsoft\Windows\SystemData\S-1-5-18\ReadOnly 下，需要 SYSTEM 权限读不到，
    # 所以默认拿桌面壁纸；想用别的图可以在 config.ui.backdrop 里指定路径
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        if ([FocusLockNative.Win32]::SystemParametersInfo([uint32]0x0073, [uint32]$sb.Capacity, $sb, [uint32]0)) {
            $v = $sb.ToString()
            if ($v -and (Test-Path -LiteralPath $v)) { return $v }
        }
    } catch { }
    try {
        $v = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name WallPaper -ErrorAction Stop).WallPaper
        if ($v) {
            $v = [Environment]::ExpandEnvironmentVariables($v)
            if (Test-Path -LiteralPath $v) { return $v }
        }
    } catch { }
    return $null
}

function New-LockBackdrop {

    # 壁纸 -> 缩到 1/14 再放大 = 廉价模糊，然后压暗，保证白字可读。
    # 失败一律返回 $null，调用方退回纯色底，不影响上锁
    param([string]$Path, [int]$W, [int]$H)

    if (-not $Path) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if ($W -lt 64 -or $H -lt 64) { return $null }

    $src = $null; $small = $null; $big = $null; $g1 = $null; $g2 = $null
    try {
        $src = [System.Drawing.Image]::FromFile($Path)
        $sw = [Math]::Max(24, [int]($W / 14))
        $sh = [Math]::Max(14, [int]($H / 14))
        $small = [System.Drawing.Bitmap]::new($sw, $sh)
        $g1 = [System.Drawing.Graphics]::FromImage($small)
        $g1.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $g1.DrawImage($src, 0, 0, $sw, $sh)
        $g1.Dispose(); $g1 = $null

        $big = [System.Drawing.Bitmap]::new($W, $H)
        $g2 = [System.Drawing.Graphics]::FromImage($big)
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g2.DrawImage($small, 0, 0, $W, $H)
        $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(175, 8, 10, 16))
        $g2.FillRectangle($brush, 0, 0, $W, $H)
        $brush.Dispose()
        $g2.Dispose(); $g2 = $null
        return $big
    } catch {
        if ($big) { try { $big.Dispose() } catch { } }
        return $null
    } finally {
        if ($g1) { try { $g1.Dispose() } catch { } }
        if ($g2) { try { $g2.Dispose() } catch { } }
        if ($small) { try { $small.Dispose() } catch { } }
        if ($src) { try { $src.Dispose() } catch { } }
    }
}

function Invoke-LockUI {
    param([object]$Config)

    [void](Initialize-Native)
    try { [void][FocusLockNative.Win32]::SetProcessDPIAware() } catch { }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($false, $script:MutexUI, [ref]$createdNew)
    if (-not $createdNew) {
        try { $mutex.Dispose() } catch { }
        return
    }



    $C = @{
        Bg      = [System.Drawing.Color]::FromArgb(10, 12, 18)
        Card    = [System.Drawing.Color]::FromArgb(24, 28, 40)
        Text    = [System.Drawing.Color]::FromArgb(200, 198, 194)
        Muted   = [System.Drawing.Color]::FromArgb(104, 110, 128)
        Accent  = [System.Drawing.Color]::FromArgb(104, 122, 184)
        Accent2 = [System.Drawing.Color]::FromArgb(76, 122, 150)
        Accent3 = [System.Drawing.Color]::FromArgb(184, 150, 92)
        Purple  = [System.Drawing.Color]::FromArgb(148, 138, 208)
        Danger  = [System.Drawing.Color]::FromArgb(190, 104, 112)
        OK      = [System.Drawing.Color]::FromArgb(88, 156, 128)
        Line    = [System.Drawing.Color]::FromArgb(38, 44, 60)
        InputBg = [System.Drawing.Color]::FromArgb(30, 35, 48)
    }

    $cg = [int]$Config.challenge.groups
    $pg = [int]$Config.challenge.digitsPerGroup
    if ($cg -le 0) { $cg = 100 }
    if ($pg -le 0) { $pg = 10 }

    $script:CH = @{
        Data    = New-DigitChallenge -Groups $cg -PerGroup $pg
        Index   = 0
        Locked  = $false
        Message = ''
    }
    $script:CH.Current = $script:CH.Data.Groups[$script:CH.Data.Order[0]]
    $script:AllowClose = $false

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $form = New-Object System.Windows.Forms.Form
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Bounds = New-Object System.Drawing.Rectangle($wa.X, $wa.Y, $wa.Width, $wa.Height)
    $form.BackColor = $C.Bg
    $form.ForeColor = $C.Text
    $form.TopMost = $true

    # 底图：config.ui.backdrop 优先，否则用桌面壁纸；都失败就保持纯色
    $backdrop = $null
    try {
        $imgPath = ''
        if ($Config.ui -and $Config.ui.backdrop) { $imgPath = [string]$Config.ui.backdrop }
        if (-not $imgPath) { $imgPath = Get-WallpaperPath }
        $backdrop = New-LockBackdrop -Path $imgPath -W ([int]($wa.Width / 2)) -H ([int]($wa.Height / 2))
        if ($backdrop) {
            $form.BackgroundImage = $backdrop
            $form.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::Stretch
        }
    } catch { $backdrop = $null }
    $form.ShowInTaskbar = $false
    $form.ControlBox = $false
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.KeyPreview = $true
    $form.Text = 'FocusLock'

    $script:UIScale = 1.0
    try {
        $gfx = $form.CreateGraphics()
        $script:UIScale = [double]$gfx.DpiX / 96.0
        $gfx.Dispose()
    } catch {
        try {
            $applied = (Get-ItemProperty 'HKCU:\Control Panel\Desktop\WindowMetrics' -Name AppliedDPI -ErrorAction SilentlyContinue).AppliedDPI
            if ($applied) { $script:UIScale = [double]$applied / 96.0 }
        } catch { }
    }
    if ($script:UIScale -lt 1.0) { $script:UIScale = 1.0 }
    $S = $script:UIScale

    $cardW = [int](860 * $S)
    $cardH = [int](620 * $S)

    function New-RoundRegion {
        param([int]$W, [int]$H, [int]$R)
        $d = $R * 2
        if ($d -gt $W) { $d = $W }
        if ($d -gt $H) { $d = $H }
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc(0, 0, $d, $d, 180, 90)
        $path.AddArc($W - $d - 1, 0, $d, $d, 270, 90)
        $path.AddArc($W - $d - 1, $H - $d - 1, $d, $d, 0, 90)
        $path.AddArc(0, $H - $d - 1, $d, $d, 90, 90)
        $path.CloseFigure()
        return (New-Object System.Drawing.Region($path))
    }

    function New-Label {
        param([string]$Text, [string]$FontName, [single]$Size, [System.Drawing.Color]$Color, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text
        $l.AutoSize = $true
        $l.BackColor = [System.Drawing.Color]::Transparent
        $l.ForeColor = $Color
        try { $l.Font = New-Object System.Drawing.Font($FontName, $Size, $Style) } catch { }
        return $l
    }

    function New-RoundButton {
        param([string]$Text, [int]$W, [int]$H, [System.Drawing.Color]$Back, [System.Drawing.Color]$Fore, [single]$FontSize, [string]$FontName = '幼圆')
        $pw = [int]($W * $S)
        $ph = [int]($H * $S)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text
        $b.Size = New-Object System.Drawing.Size($pw, $ph)
        $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $b.FlatAppearance.BorderSize = 0
        $b.BackColor = $Back
        $b.ForeColor = $Fore
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        try { $b.Font = New-Object System.Drawing.Font($FontName, $FontSize, [System.Drawing.FontStyle]::Bold) } catch { }
        try { $b.Region = New-RoundRegion -W $pw -H $ph -R ([int](16 * $S)) } catch { }
        return $b
    }

    function New-Separator {
        $p = New-Object System.Windows.Forms.Panel
        $p.Size = New-Object System.Drawing.Size([int](700 * $S), [Math]::Max(1, [int](2 * $S)))
        $p.BackColor = $C.Line
        return $p
    }

    function New-InputBox {
        param([int]$W, [int]$H, [single]$FontSize)
        $pw = [int]($W * $S)
        $ph = [int]($H * $S)
        $panel = New-Object System.Windows.Forms.Panel
        $panel.Size = New-Object System.Drawing.Size($pw, $ph)
        $panel.BackColor = $C.InputBg
        try { $panel.Region = New-RoundRegion -W $pw -H $ph -R ([int](12 * $S)) } catch { }
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $tb.BackColor = $C.InputBg
        $tb.ForeColor = $C.Text
        $tb.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
        try { $tb.Font = New-Object System.Drawing.Font('Arial Rounded MT Bold', $FontSize) } catch { }
        $tb.Width = $pw - [int](24 * $S)
        $tb.Left = [int](12 * $S)
        $tb.Top = [int](($ph - $tb.Height) / 2)
        $panel.Controls.Add($tb)
        return [pscustomobject]@{ Panel = $panel; Text = $tb }
    }

    $card = New-Object System.Windows.Forms.Panel
    $card.Size = New-Object System.Drawing.Size($cardW, $cardH)
    $card.BackColor = $C.Card
    $card.Region = New-RoundRegion -W $cardW -H $cardH -R ([int](34 * $S))
    $form.Controls.Add($card)

    $lblClock     = New-Label -Text '00:00:00' -FontName 'Arial Rounded MT Bold' -Size 46 -Color $C.Purple
    $lblRemain    = New-Label -Text '' -FontName '幼圆' -Size 14 -Color $C.Muted
    $lblTitle     = New-Label -Text $Config.ui.title -FontName '幼圆' -Size 26 -Color $C.Purple -Style ([System.Drawing.FontStyle]::Bold)
    $lblSub       = New-Label -Text $Config.ui.subtitle -FontName '幼圆' -Size 12 -Color $C.Muted
    $lblChTitle   = New-Label -Text '' -FontName '幼圆' -Size 12 -Color $C.Accent -Style ([System.Drawing.FontStyle]::Bold)
    $lblDigits    = New-Label -Text '' -FontName 'Arial Rounded MT Bold' -Size 30 -Color $C.Purple -Style ([System.Drawing.FontStyle]::Bold)
    $lblMsg       = New-Label -Text '' -FontName '幼圆' -Size 11 -Color $C.Muted
    $lblFooter    = New-Label -Text '' -FontName '幼圆' -Size 9 -Color $C.Muted

    $sep1 = New-Separator
    $sep2 = New-Separator

    $btnDoubao = New-RoundButton -Text '打开豆包' -W 200 -H 46 -Back $C.Accent -Fore ([System.Drawing.Color]::White) -FontSize 13
    $btnShutdown = New-RoundButton -Text '立刻关机' -W 200 -H 46 -Back ([System.Drawing.Color]::FromArgb(62, 68, 86)) -Fore ([System.Drawing.Color]::FromArgb(176, 176, 186)) -FontSize 13
    $btnSubmit = New-RoundButton -Text '确认' -W 108 -H 44 -Back $C.Accent2 -Fore ([System.Drawing.Color]::White) -FontSize 13

    $codeBox = New-InputBox -W 340 -H 50 -FontSize 17
    $txtCode = $codeBox.Text
    $txtCode.MaxLength = $pg

    $card.Controls.Add($lblClock)
    $card.Controls.Add($lblRemain)
    $card.Controls.Add($sep1)
    $card.Controls.Add($lblTitle)
    $card.Controls.Add($lblSub)
    $card.Controls.Add($btnDoubao)
    $card.Controls.Add($btnShutdown)
    $card.Controls.Add($sep2)
    $card.Controls.Add($lblChTitle)
    $card.Controls.Add($lblDigits)
    $card.Controls.Add($codeBox.Panel)
    $card.Controls.Add($btnSubmit)
    $card.Controls.Add($lblMsg)
    $card.Controls.Add($lblFooter)

    function Center-InCard {
        param($Ctl, [int]$Y)
        $Ctl.Left = [int](($cardW - $Ctl.Width) / 2)
        $Ctl.Top = $Y
    }

    function Layout-OnCard {
        $u = $S
        Center-InCard $lblClock ([int](26 * $u))
        Center-InCard $lblRemain ($lblClock.Top + $lblClock.Height + [int](2 * $u))
        Center-InCard $sep1 ($lblRemain.Top + $lblRemain.Height + [int](14 * $u))
        Center-InCard $lblTitle ($sep1.Top + [int](16 * $u))
        Center-InCard $lblSub ($lblTitle.Top + $lblTitle.Height + [int](6 * $u))
        $btnY = $lblSub.Top + $lblSub.Height + [int](18 * $u)
        $btnGap = [int](18 * $u)
        $rowW = $btnDoubao.Width + $btnGap + $btnShutdown.Width
        $rowX = [int](($cardW - $rowW) / 2)
        $btnDoubao.Left = $rowX
        $btnDoubao.Top = $btnY
        $btnShutdown.Left = $rowX + $btnDoubao.Width + $btnGap
        $btnShutdown.Top = $btnY
        Center-InCard $sep2 ($btnY + $btnDoubao.Height + [int](22 * $u))
        Center-InCard $lblChTitle ($sep2.Top + [int](14 * $u))
        Center-InCard $lblDigits ($lblChTitle.Top + $lblChTitle.Height + [int](8 * $u))

        $gap = [int](14 * $u)
        $inputY = $lblDigits.Top + $lblDigits.Height + [int](12 * $u)
        $totalW = $codeBox.Panel.Width + $gap + $btnSubmit.Width
        $startX = [int](($cardW - $totalW) / 2)
        $codeBox.Panel.Left = $startX
        $codeBox.Panel.Top = $inputY
        $btnSubmit.Left = $startX + $codeBox.Panel.Width + $gap
        $btnSubmit.Top = $inputY + [int](2 * $u)

        Center-InCard $lblMsg ($inputY + [int](58 * $u))

        Center-InCard $lblFooter ($cardH - [int](46 * $u))
    }

    function Layout-Screen {
        $W = $form.ClientSize.Width
        $H = $form.ClientSize.Height
        $card.Left = [int](($W - $cardW) / 2)
        $card.Top = [int](($H - $cardH) / 2)
        Layout-OnCard
    }

    function Update-ChallengeText {
        $cur = $script:CH.Data.Order[$script:CH.Index]
        $script:CH.Current = $script:CH.Data.Groups[$cur]
        $done = $script:CH.Index * $pg
        $totalDigits = $cg * $pg
        $filled = [math]::Floor(($script:CH.Index / $cg) * 10)
        $bar = ('●' * $filled) + ('○' * (10 - $filled))
        $lblChTitle.Text = "第 $($script:CH.Index + 1) / $cg 组 · 已确认 $done / $totalDigits 位 · $bar"
        $lblDigits.Text = Format-Digits $script:CH.Current
        $txtCode.Clear()
        Layout-OnCard
        $txtCode.Focus() | Out-Null
    }

    function Reset-Challenge {
        $script:CH.Data = New-DigitChallenge -Groups $cg -PerGroup $pg
        $script:CH.Index = 0
        $script:CH.Message = '输入错误，1000 位已全部作废，从头开始。'
        Update-ChallengeText
        $lblMsg.ForeColor = $C.Danger
        $lblMsg.Text = $script:CH.Message
    }

    function Invoke-Submit {
        if ($script:CH.Locked) { return }

        $val = $txtCode.Text.Trim()
        if ($val.Length -ne $pg) {
            $lblMsg.ForeColor = $C.Danger
            $lblMsg.Text = ("需要输入 $pg 个数字，当前 $($val.Length) 个。")
            return
        }
        if ($val -notmatch '^\d+$') {
            $lblMsg.ForeColor = $C.Danger
            $lblMsg.Text = '只能输入数字。'
            return
        }

        if ($val -cne $script:CH.Current) {
            Reset-Challenge
            return
        }

        $script:CH.Index++

        if ($script:CH.Index -ge $cg) {
            $script:CH.Locked = $true
            $lblMsg.ForeColor = $C.OK
            $lblMsg.Text = '校准完成。正在解锁…'
            $btnSubmit.Enabled = $false
            $txtCode.Enabled = $false

            # 输对了 1000 位：和 Unlock.cmd 走同一套「删区间」逻辑
            # 输对了 1000 位：和 Unlock.cmd 一样，解除所有覆盖当前时刻的区间
            $nowU = Get-Date
            $setU = Get-UnlockSet -Config $Config -At $nowU
            if ($setU.Manual) {
                Remove-Item -LiteralPath $script:ManualPath -Force -ErrorAction SilentlyContinue
                Write-FocusLog 'manual-released' '定时区间已移除'
            }
            if ($setU.Auto -and $setU.AutoWin) {
                Set-Dismissed -Key $setU.AutoWin.Key
                Write-FocusLog 'dismissed' $setU.AutoWin.Key
            }
            $script:AllowClose = $true
            $form.Close()
            return
        }

        $lblMsg.ForeColor = $C.OK
        $lblMsg.Text = "第 $($script:CH.Index) 组正确。"
        Update-ChallengeText
    }

    $script:MaskVisible = $true
    $script:MaskShouldYield = $false
    $script:LastForced = Get-Date
    $script:LastAllowedAt = (Get-Date).AddSeconds(-10)
    $script:WantsDoubao = $false
    $script:DoubaoTries = 0

    function Update-MaskState {

        $now = Get-Date
        $info = Get-ForegroundInfo

        if (Test-NeutralClassName $info.ClassName) { return }

        $allowed = Test-ForegroundAllowed -Config $Config -Info $info

        if ($allowed) {
            $script:LastAllowedAt = $now
            $script:WantsDoubao = $false

        }

        $script:MaskShouldYield = $false

        if (-not $script:MaskVisible) {
            $script:MaskVisible = $true
            try { $form.Visible = $true } catch { }
            try { $form.TopMost = $true } catch { }
        }

        if (($now - $script:LastForced).TotalMilliseconds -ge 1200) {
            $fg = [FocusLockNative.Win32]::GetForegroundWindow()
            if ($fg -ne $form.Handle) {
                try { $form.TopMost = $true } catch { }
                try { $form.BringToFront() } catch { }
                try { [void][FocusLockNative.Win32]::SetForegroundWindow($form.Handle) } catch { }
                try { $form.Activate() } catch { }
                try { $txtCode.Focus() | Out-Null } catch { }
            }
            $script:LastForced = $now
        }
    }

    $script:TickCount = 0
    $script:CfgNow = $Config
    $script:CfgAt = Get-Date
    $script:LastClockText = ''
    $script:LastRemainText = ''
    $script:LastFooterText = ''
    $script:LastWakeCheck = Get-Date
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        $script:TickCount++
        $now = Get-Date

        # 息屏/睡眠回来后 timer 会跳一大格：重排、重绘、重新置顶，避免整块黑、任务栏回来
        if (($now - $script:LastWakeCheck).TotalSeconds -gt 5) {
            $script:LastWakeCheck = $now
            try { Set-TaskbarHidden -Hidden $true } catch { }
            try { $form.Bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds } catch { }
            try { $form.TopMost = $false; $form.TopMost = $true } catch { }
            try { $form.Invalidate($true) } catch { }
        }
        $script:LastWakeCheck = $now

        $needLayout = $false

        $clockText = $now.ToString('HH:mm:ss')
        if ($script:LastClockText -ne $clockText) {
            $script:LastClockText = $clockText
            $oldW = $lblClock.Width
            $lblClock.Text = $clockText

            if ($lblClock.Width -ne $oldW) { $needLayout = $true }
        }

        if (($now - $script:CfgAt).TotalSeconds -ge 10) {
            $fresh = Get-FocusConfig
            if ($fresh) { $script:CfgNow = $fresh }
            $script:CfgAt = $now
        }
        $cfgNow = $script:CfgNow

        if ($cfgNow) {
            $win = Get-LockWindow -Config $cfgNow -At $now
            $remainText = '当前不在锁定时段'
            if ($win) {
                # 沿着相接/重叠的区间往后延，显示整条链的终点
                $chainEnd = Get-LockChainEnd -Config $cfgNow -At $now
                if (-not $chainEnd) { $chainEnd = $win.End }
                $span = $chainEnd - $now
                if ($span.TotalSeconds -lt 0) { $span = [timespan]::Zero }
                $remainText = ('距离自动解锁还有 {0:hh\:mm\:ss}' -f $span)
                $footerTime = $chainEnd.ToString('HH:mm')
            } else {
                $footerTime = '--:--'
            }

            # 底栏跟着当前生效区间的终点走，不再固定显示熬夜锁配置的结束时间
            $footerText = ('FocusLock v{0}　·　{1} 自动解锁　·　也可运行 Unlock.cmd 立即解锁' -f $script:Version, $footerTime)
            if ($script:LastFooterText -ne $footerText) {
                $script:LastFooterText = $footerText
                try { $lblFooter.Text = $footerText } catch { }
            }

            # 倒计时那行
            if ($script:LastRemainText -ne $remainText) {
                $script:LastRemainText = $remainText
                try { $lblRemain.Text = $remainText } catch { }
                $needLayout = $true
            }
        }

        if ($needLayout) { Layout-OnCard }


        Update-MaskState

        $wantInterval = 250
        if ($script:MaskShouldYield) { $wantInterval = 500 }
        if ($timer.Interval -ne $wantInterval) { $timer.Interval = $wantInterval }

        if ($script:WantsDoubao) {
            if ($script:TickCount % 5 -eq 0) {
                $script:DoubaoTries++
                if ($script:DoubaoTries -gt 30) {
                    $script:WantsDoubao = $false
                    $lblMsg.ForeColor = [System.Drawing.Color]::FromArgb(255, 180, 90)
                    $lblMsg.Text = '豆包启动超时，请点击按钮重试。'
                } elseif (Start-DoubaoApp -Config $Config) {
                    $script:WantsDoubao = $false
                    $script:DoubaoTries = 0
                }
            }
        }

        if ($script:TickCount % 25 -eq 0) {
                if (-not $cfgNow) { $script:AllowClose = $true; $form.Close(); return }
                $winNow = Get-LockWindow -Config $cfgNow -At $now
                if (-not $winNow) { $script:AllowClose = $true; $form.Close(); return }
        }

        if ($script:TickCount % 40 -eq 0) {
            if (-not (Test-NamedMutexHeld $script:MutexGuard)) {
                [void](Start-FocusChild -ChildMode 'guard')
            }
        }

        if ($script:TickCount % 8 -eq 0) {
            $tm = Get-Process -Name 'taskmgr' -ErrorAction SilentlyContinue
            if ($tm) {
                $tm | Stop-Process -Force -ErrorAction SilentlyContinue
                Write-FocusLog 'taskmgr-blocked' ''
            }
        }

        if ($script:TickCount % 120 -eq 5) {
            Set-TaskMgrBlocked -Blocked $true
            if ($script:MaskVisible) {
                Set-TaskbarHidden -Hidden $true
                $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                if ($form.Bounds.Width -ne $b.Width -or $form.Bounds.Height -ne $b.Height) {
                    $form.Bounds = New-Object System.Drawing.Rectangle($b.X, $b.Y, $b.Width, $b.Height)
                }
            }
        }
    })

    $form.Add_FormClosing({
        param($sender, $e)

        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::WindowsShutDown) {
            $script:AllowClose = $true
        }
        if (-not $script:AllowClose) { $e.Cancel = $true }
    })

    $txtCode.Add_KeyPress({
        param($sender, $e)
        if ($e.KeyChar -eq [char]13) { return }
        if ($e.KeyChar -eq [char]8) { return }
        if ($e.KeyChar -notmatch '^\d$') { $e.Handled = $true }
    })

    $txtCode.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $e.SuppressKeyPress = $true
            Invoke-Submit
        }
    })

    $btnSubmit.Add_Click({ Invoke-Submit })

    $btnDoubao.Add_Click({
        $ok = Start-DoubaoApp -Config $Config -AllowLaunch
        if (-not $ok) {
            $lblMsg.ForeColor = $C.Danger
            $lblMsg.Text = '未找到豆包客户端，请检查安装。'
            Layout-OnCard
        }
    })

    $btnShutdown.Add_Click({
        try {
            # 先确认，防止误触
            if (-not (Confirm-Shutdown -Colors $C)) {
                Write-FocusLog 'shutdown-cancel' '用户取消关机'
                return
            }


            $sdExe = Join-Path $env:SystemRoot 'System32\shutdown.exe'
            if (-not (Test-Path -LiteralPath $sdExe)) { $sdExe = 'shutdown.exe' }
            $r = Start-Process -FilePath $sdExe -ArgumentList '/s','/t','0','/f' -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
            if ($r.ExitCode -eq 0) {
                $lblMsg.ForeColor = $C.OK
                $lblMsg.Text = '正在关机…'
                Write-FocusLog 'shutdown-now' ''
            } else {
                $lblMsg.ForeColor = $C.Danger
                $lblMsg.Text = ('关机失败，退出码 {0}。' -f $r.ExitCode)
                Write-FocusLog 'shutdown-fail' ('exit=' + $r.ExitCode)
            }
            Layout-OnCard
        } catch {
            $lblMsg.ForeColor = $C.Danger
            $lblMsg.Text = '关机指令发送失败。'
            Write-FocusLog 'shutdown-fail' $_.Exception.Message
            Layout-OnCard
        }
    })



    $form.Add_Shown({
        Layout-Screen
        Update-ChallengeText
        $timer.Start()
        try { $form.Activate() } catch { }
        try { [void][FocusLockNative.Win32]::SetForegroundWindow($form.Handle) } catch { }
        try { Set-LockUiReady } catch { }
    })

    $form.Add_Resize({ Layout-Screen })

    # 底栏由 timer 动态刷新（显示当前实际生效区间的终点），这里只放个初值
    $lblFooter.Text = ('FocusLock v{0}　·　也可运行 Unlock.cmd 立即解锁' -f $script:Version)

    Write-FocusLog 'lock-ui-start' ''

    try {
        [System.Windows.Forms.Application]::Run($form)
    } finally {
        try { $timer.Stop(); $timer.Dispose() } catch { }
        try { Set-TaskbarHidden -Hidden $false } catch { }
            try { [FocusLockNative.Win32]::Uninstall() } catch { }
            try { Set-TaskMgrBlocked -Blocked $false } catch { }
        try { Clear-LockUiReady } catch { }
        try { if ($backdrop) { $backdrop.Dispose() } } catch { }
        try { $mutex.Dispose() } catch { }

        Write-FocusLog 'lock-ui-exit' ''
        try { $form.Dispose() } catch { }
    }
}

function Invoke-Uninstall {

    # 锁机时段内不许卸载（uninstall.cmd 会把退出码 3 当成"拒绝"直接中止）
    $cfgNow = Get-FocusConfig
    if ($cfgNow -and (Get-LockWindow -Config $cfgNow -At (Get-Date))) {
        Write-FocusLog 'uninstall-refused' '锁定中'
        Write-Host '锁定期间不能卸载，请先在遮罩上解锁。' -ForegroundColor Yellow
        exit 3
    }

    # 清掉程序自己留下的所有痕迹；目录本身由 uninstall.cmd 在本进程退出后删除
    $me = $PID

    foreach ($n in @($script:TaskName, 'FocusLockGuardBackup', 'FocusLockManualLock')) {
        try { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    }

    # 杀掉还在跑的 tick / guard / 遮罩；不杀自己
    try {
        $pat = [regex]::Escape($script:DataDir)
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' or Name='wscript.exe'" -ErrorAction SilentlyContinue)) {
            if ($p.ProcessId -eq $me) { continue }
            if ($p.CommandLine -and ($p.CommandLine -match $pat)) {
                try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    } catch { }
    Start-Sleep -Milliseconds 400

    # DisableTaskMgr + 空壳策略键
    Set-TaskMgrBlocked -Blocked $false
    try {
        $k = $script:PolicyKey
        if (Test-Path $k) {
            $vals = @((Get-ItemProperty $k).PSObject.Properties.Name | Where-Object { $_ -notlike 'PS*' })
            $subs = @(Get-ChildItem $k -ErrorAction SilentlyContinue)
            if ($vals.Count -eq 0 -and $subs.Count -eq 0) { Remove-Item $k -Force -ErrorAction SilentlyContinue }
        }
    } catch { }

    # 自启：Run 键 + “启动应用”记录
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $appKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    try { Remove-ItemProperty -Path $runKey -Name 'FocusLock' -Force -ErrorAction SilentlyContinue } catch { }
    try { Remove-ItemProperty -Path $appKey -Name 'FocusLock' -Force -ErrorAction SilentlyContinue } catch { }

    # v1 遗留
    try { Remove-Item -LiteralPath 'HKCU:\Software\FocusLock' -Recurse -Force -ErrorAction SilentlyContinue } catch { }

    Set-TaskbarHidden -Hidden $false
}

switch ($Mode) {

    'lock' {
        $cfgNow = Get-FocusConfig
        if (-not $cfgNow) {
            $cfgNow = New-DefaultConfig
            Save-FocusConfig -Config $cfgNow
        }
        if ($Minutes -gt 0) { [void](New-ManualLock -Minutes $Minutes) }

        # 每次上锁都把任务和 Run 键对齐一遍，保证登录秒锁
        $ok = $true
        try { Register-FocusTasks; Write-FocusLog 'setup' '' } catch { Write-FocusLog 'setup-fail' $_.Exception.Message; $ok = $false }
        if (-not $ok) { exit 1 }
        [void](Initialize-Native)

        # 不在锁定时段就只做部署，不再拉起遮罩空转 6 秒
        if ((Get-LockWindow -Config $cfgNow -At (Get-Date)) -and -not (Test-NamedMutexHeld $script:MutexUI)) {
            [void](Start-FocusChild -ChildMode 'lock-ui')
            [void](Start-FocusChild -ChildMode 'guard')
        }
    }

    'lock-ask' {
        Invoke-LockAsk
    }

    'lock-ui' {
        $c = Get-FocusConfig
        if ($c) { Invoke-LockUI -Config $c }
    }

    'unlock' { Invoke-Unlock }
    'uninstall' { Invoke-Uninstall }
    'tick'     { Invoke-Tick }
    'settings' { Invoke-Settings }
    'guard'  { Invoke-Guard }
}
