$ErrorActionPreference = 'Continue'

$src = @"
using System;
using System.Runtime.InteropServices;
public class Mux4 {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int L; public int T; public int R; public int B; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct MONITORINFOEX {
    public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct PHYSICAL_MONITOR { public IntPtr hPhysicalMonitor; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szDescription; }
  public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);
  [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);
  [DllImport("dxva2.dll")] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, ref uint count);
  [DllImport("dxva2.dll")] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);
  [DllImport("dxva2.dll")] public static extern bool DestroyPhysicalMonitor(IntPtr hMonitor);
  [DllImport("dxva2.dll")] public static extern bool GetMonitorCapabilities(IntPtr hMonitor, ref uint caps, ref uint colorTemps);
  [DllImport("dxva2.dll", EntryPoint = "GetVCPFeatureAndVCPFeatureReply")]
  public static extern bool GetVcpReply(IntPtr hMonitor, byte vcpCode, ref uint type, ref uint current, ref uint max);
}
"@
Add-Type -TypeDefinition $src

$codes = @(0x01, 0x10, 0x52, 0x62, 0xD6, 0xDF)

$found = New-Object System.Collections.ArrayList
$cb = [Mux4+MonitorEnumProc] {
    param($hMon, $hdc, [ref]$rect, $data)
    $mi = New-Object Mux4+MONITORINFOEX
    $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][Mux4+MONITORINFOEX])
    [void][Mux4]::GetMonitorInfo($hMon, [ref]$mi)
    [void]$found.Add(@{ HMon = $hMon; Device = $mi.szDevice; Primary = (($mi.dwFlags -band 1) -ne 0) })
    return $true
}
[void][Mux4]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $cb, [IntPtr]::Zero)

foreach ($m in $found) {
    $tag = 'PRIMARY'; if (-not $m.Primary) { $tag = 'SECONDARY' }
    Write-Host ("== {0} [{1}]" -f $m.Device, $tag)
    $cnt = [uint32]0
    if ([Mux4]::GetNumberOfPhysicalMonitorsFromHMONITOR($m.HMon, [ref]$cnt)) {
        $arr = New-Object 'Mux4+PHYSICAL_MONITOR[]' ([int]$cnt)
        if ([Mux4]::GetPhysicalMonitorsFromHMONITOR($m.HMon, $cnt, $arr)) {
            $h = $arr[0].hPhysicalMonitor
            $caps = [uint32]0; $ct = [uint32]0
            $okc = [Mux4]::GetMonitorCapabilities($h, [ref]$caps, [ref]$ct)
            Write-Host ("  GetMonitorCapabilities: ok={0} caps=0x{1:X8}" -f $okc, $caps)
            foreach ($c in $codes) {
                $t = [uint32]0; $cur = [uint32]0; $mx = [uint32]0
                $ok = [Mux4]::GetVcpReply($h, [byte]$c, [ref]$t, [ref]$cur, [ref]$mx)
                Write-Host ("  VCP 0x{0:X2}: ok={1} cur={2} max={3}" -f $c, $ok, $cur, $mx)
            }
            [void][Mux4]::DestroyPhysicalMonitor($h)
        }
    }
}
Write-Host 'PROBE-DONE'
