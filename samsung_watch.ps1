# Auto-return watcher for monitors that DO respond to DDC/CI.
# Polls the secondary monitor's DDC/CI: if the monitor stops responding (powered off),
# moves all its windows back to the primary display; when it responds again,
# moves them back. Safety design: it only acts after it has seen DDC respond at
# least once, so a monitor without DDC/CI stays idle forever (no false triggers).
# Note: useless for Samsung C27F390 (no DDC/CI on HDMI) - see README.

$ErrorActionPreference = 'SilentlyContinue'
$log   = Join-Path $PSScriptRoot 'samsung_watch.log'
$stopF = Join-Path $PSScriptRoot 'samsung_watch.stop'
$pollMs = 3000
$debounce = 2
$deadline = (Get-Date).AddHours(24)

$src = @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Mux3 {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int L; public int T; public int R; public int B; }
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct MONITORINFOEX {
    public int cbSize;
    public RECT rcMonitor;
    public RECT rcWork;
    public uint dwFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct PHYSICAL_MONITOR { public IntPtr hPhysicalMonitor; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szDescription; }
  [StructLayout(LayoutKind.Sequential)]
  public struct WINDOWPLACEMENT {
    public uint length; public uint flags; public uint showCmd;
    public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
  }
  public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc proc, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, ref RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT p);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, ref int val, int size);
  [DllImport("dxva2.dll")] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, ref uint count);
  [DllImport("dxva2.dll")] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);
  [DllImport("dxva2.dll")] public static extern bool DestroyPhysicalMonitor(IntPtr hMonitor);
  [DllImport("dxva2.dll")] public static extern bool GetMonitorBrightness(IntPtr hMonitor, ref uint minCur, ref uint current, ref uint maxCur);
}
"@
Add-Type -TypeDefinition $src

function Log-Line($s) { ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $s) | Out-File $log -Append -Encoding utf8 }

function Get-Targets {
    $list = New-Object System.Collections.ArrayList
    $cb = [Mux3+MonitorEnumProc] {
        param($hMon, $hdc, [ref]$rect, $data)
        $mi = New-Object Mux3+MONITORINFOEX
        $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][Mux3+MONITORINFOEX])
        [void][Mux3]::GetMonitorInfo($hMon, [ref]$mi)
        [void]$list.Add(@{ HMon = $hMon; Rect = $mi.rcMonitor; Primary = (($mi.dwFlags -band 1) -ne 0); Device = $mi.szDevice })
        return $true
    }
    [void][Mux3]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $cb, [IntPtr]::Zero)
    $prim = $list | Where-Object { $_.Primary } | Select-Object -First 1
    $sec  = $list | Where-Object { -not $_.Primary } | Select-Object -First 1
    return @{ Primary = $prim; Secondary = $sec }
}

function Test-DDC($hMon) {
    $cnt = [uint32]0
    if (-not [Mux3]::GetNumberOfPhysicalMonitorsFromHMONITOR($hMon, [ref]$cnt)) { return $false }
    $arr = New-Object 'Mux3+PHYSICAL_MONITOR[]' ([int]$cnt)
    if (-not [Mux3]::GetPhysicalMonitorsFromHMONITOR($hMon, $cnt, $arr)) { return $false }
    $ok = $false
    for ($i = 0; $i -lt $cnt; $i++) {
        $mn = [uint32]0; $cur = [uint32]0; $mx = [uint32]0
        if ([Mux3]::GetMonitorBrightness($arr[$i].hPhysicalMonitor, [ref]$mn, [ref]$cur, [ref]$mx)) { $ok = $true }
        [void][Mux3]::DestroyPhysicalMonitor($arr[$i].hPhysicalMonitor)
    }
    return $ok
}

function Move-AllWindowsOff($sec, $prim) {
    $S = $sec.Rect; $P = $prim.Rect
    $saved = New-Object System.Collections.ArrayList
    $cb = [Mux3+EnumWindowsProc] {
        param($h, $lp)
        if (-not [Mux3]::IsWindowVisible($h)) { return $true }
        $ex = [Mux3]::GetWindowLong($h, -20)
        if (($ex -band 0x80) -ne 0) { return $true }   # WS_EX_TOOLWINDOW
        $cloaked = 0
        [void][Mux3]::DwmGetWindowAttribute($h, 14, [ref]$cloaked, 4)
        if ($cloaked -ne 0) { return $true }
        $sb = New-Object System.Text.StringBuilder 64
        [void][Mux3]::GetClassName($h, $sb, 64)
        $cls = $sb.ToString()
        if ($cls -like 'Shell_Tray*' -or $cls -eq 'Progman' -or $cls -eq 'WorkerW') { return $true }
        $target = [Mux3]::MonitorFromWindow($h, 2)   # MONITOR_DEFAULTTONEAREST
        if ($target -ne $sec.HMon) { return $true }
        $r = New-Object Mux3+RECT
        [void][Mux3]::GetWindowRect($h, [ref]$r)
        $wp = New-Object Mux3+WINDOWPLACEMENT
        $wp.length = [System.Runtime.InteropServices.Marshal]::SizeOf([type][Mux3+WINDOWPLACEMENT])
        [void][Mux3]::GetWindowPlacement($h, [ref]$wp)
        $maximized = ($wp.showCmd -eq 3)
        [void]$saved.Add(@{ Hwnd = $h; Class = $cls; Max = $maximized; L = $r.L; T = $r.T; W = ($r.R - $r.L); Hh = ($r.B - $r.T) })
        return $true
    }
    [void][Mux3]::EnumWindows($cb, [IntPtr]::Zero)

    $moved = 0
    foreach ($w in $saved) {
        try {
            $nx = $P.L + ($w.L - $S.L)
            $ny = $P.T + ($w.T - $S.T)
            $nw = [Math]::Min($w.W, ($P.R - $P.L))
            $nh = [Math]::Min($w.Hh, ($P.B - $P.T))
            if ($nx -lt $P.L) { $nx = $P.L }
            if ($ny -lt $P.T) { $ny = $P.T }
            if ($nx + $nw -gt $P.R) { $nx = [Math]::Max($P.L, $P.R - $nw) }
            if ($ny + $nh -gt $P.B) { $ny = [Math]::Max($P.T, $P.B - $nh) }
            if ($w.Max) {
                [void][Mux3]::ShowWindow($w.Hwnd, 9)     # SW_RESTORE
                [void][Mux3]::SetWindowPos($w.Hwnd, [IntPtr]::Zero, $nx, $ny, $nw, $nh, 0x10 -bor 0x2 -bor 0x40)
                [void][Mux3]::ShowWindow($w.Hwnd, 3)     # SW_MAXIMIZE (on primary)
            } else {
                [void][Mux3]::SetWindowPos($w.Hwnd, [IntPtr]::Zero, $nx, $ny, $nw, $nh, 0x10 -bor 0x2 -bor 0x40)
            }
            $moved++
        } catch { Log-Line ("  move failed hwnd={0}: {1}" -f $w.Hwnd, $_.Exception.Message) }
    }
    $cp = New-Object Mux3+POINT
    [void][Mux3]::GetCursorPos([ref]$cp)
    if ($cp.X -ge $S.L -and $cp.X -lt $S.R -and $cp.Y -ge $S.T -and $cp.Y -lt $S.B) {
        [void][Mux3]::SetCursorPos([int](($P.L + $P.R) / 2), [int](($P.T + $P.B) / 2))
    }
    return $saved
}

function Restore-Windows($saved, $sec) {
    $S = $sec.Rect
    $restored = 0
    foreach ($w in $saved) {
        try {
            if ($w.Max) {
                [void][Mux3]::ShowWindow($w.Hwnd, 9)
                [void][Mux3]::SetWindowPos($w.Hwnd, [IntPtr]::Zero, $S.L, $S.T, ($S.R - $S.L), ($S.B - $S.T), 0x10 -bor 0x2 -bor 0x40)
                [void][Mux3]::ShowWindow($w.Hwnd, 3)
            } else {
                $nx = [Math]::Max($S.L, [Math]::Min($w.L, $S.R - 100))
                $ny = [Math]::Max($S.T, [Math]::Min($w.T, $S.B - 60))
                [void][Mux3]::SetWindowPos($w.Hwnd, [IntPtr]::Zero, $nx, $ny, $w.W, $w.Hh, 0x10 -bor 0x2 -bor 0x40)
            }
            $restored++
        } catch { Log-Line ("  restore failed hwnd={0}: {1}" -f $w.Hwnd, $_.Exception.Message) }
    }
    return $restored
}

# ===== main =====
[void][Mux3]::SetProcessDPIAware()
Log-Line "samsung auto-return watcher started (poll=$($pollMs)ms, debounce=$debounce, runs 24h)"

$mode = 'CALIBRATING'
$calibTries = 0
$failStreak = 0
$okStreak = 0
$saved = $null
$lastStandbyProbe = Get-Date

while ((Get-Date) -lt $deadline) {
    if (Test-Path $stopF) { Log-Line 'stop file found, exiting'; break }

    $t = Get-Targets
    $sec = $t.Secondary; $prim = $t.Primary

    switch ($mode) {
        'CALIBRATING' {
            if ($null -eq $sec) { Start-Sleep -Milliseconds $pollMs; continue }
            $calibTries++
            if (Test-DDC $sec.HMon) {
                $mode = 'ON'; $failStreak = 0
                Log-Line 'DDC responded -> ARMED. Will move windows back to primary if this monitor stops responding (powered off).'
            } elseif ($calibTries -ge 4) {
                $mode = 'STANDBY'
                Log-Line 'DDC never responded during calibration -> STANDBY (idle). Will re-probe every 60s; no action until DDC works once. (DDC/CI may be disabled in the monitor OSD.)'
            }
        }
        'STANDBY' {
            if (((Get-Date) - $lastStandbyProbe).TotalSeconds -ge 60) {
                $lastStandbyProbe = Get-Date
                if ($null -ne $sec -and (Test-DDC $sec.HMon)) {
                    $mode = 'ON'
                    Log-Line 'DDC now responding -> ARMED.'
                }
            }
        }
        'ON' {
            if ($null -eq $sec) {
                $mode = 'DETACHED'
                Log-Line 'secondary monitor disappeared natively (HPD dropped) - Windows handles reconnection; nothing to do.'
                Start-Sleep -Milliseconds $pollMs; continue
            }
            if (Test-DDC $sec.HMon) { $failStreak = 0 }
            else {
                $failStreak++
                if ($failStreak -ge $debounce) {
                    Log-Line 'monitor stopped responding (likely powered off) -> moving its windows to primary...'
                    $saved = Move-AllWindowsOff $sec $prim
                    Log-Line ("moved {0} window(s) to primary; saved for restore." -f $saved.Count)
                    $mode = 'OFF_MOVED'
                    $failStreak = 0; $okStreak = 0
                }
            }
        }
        'OFF_MOVED' {
            if ($null -eq $sec) {
                $mode = 'DETACHED'
                Log-Line 'secondary monitor also natively disconnected after power-off; keeping saved list for restore on reconnect.'
                Start-Sleep -Milliseconds $pollMs; continue
            }
            if (Test-DDC $sec.HMon) {
                $okStreak++
                if ($okStreak -ge $debounce) {
                    $n = Restore-Windows $saved $sec
                    Log-Line ("monitor is back -> restored {0} window(s)." -f $n)
                    $saved = $null
                    $mode = 'ON'; $okStreak = 0
                }
            } else { $okStreak = 0 }
        }
        'DETACHED' {
            if ($null -ne $sec) {
                Log-Line 'secondary monitor reconnected.'
                if ($null -ne $saved -and $saved.Count -gt 0) {
                    $n = Restore-Windows $saved $sec
                    Log-Line ("restored {0} saved window(s) onto reconnected monitor." -f $n)
                    $saved = $null
                }
                $mode = 'ON'
            }
        }
    }
    Start-Sleep -Milliseconds $pollMs
}
Log-Line 'watcher exiting (deadline or stop file)'
