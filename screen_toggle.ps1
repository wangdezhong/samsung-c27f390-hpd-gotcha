# Toggle between "PC screen only" and "Extend" topology.
# "PC screen only" makes Windows pull every window back to the primary display,
# and the secondary monitor enters standby by itself after losing the signal.
# This is the programmatic equivalent of Win+P.

param([switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'screen_toggle.log'

function Log-Line($s) { ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $s) | Out-File $log -Append -Encoding utf8 }

$src = @"
using System;
using System.Runtime.InteropServices;
public class Topo {
  [DllImport("user32.dll")]
  public static extern int SetDisplayConfig(uint numPathArrayElements, IntPtr pathArray, uint numModeArrayElements, IntPtr modeArray, uint flags);
}
"@
Add-Type -TypeDefinition $src

if ($ValidateOnly) { Log-Line 'validate ok: SetDisplayConfig loaded'; Write-Host 'VALIDATE-OK'; exit 0 }

Add-Type -AssemblyName System.Windows.Forms
$n = [System.Windows.Forms.Screen]::AllScreens.Count

if ($n -gt 1) {
    # SDC_TOPOLOGY_INTERNAL (0x1) | SDC_APPLY (0x80): PC screen only
    $r = [Topo]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0x81)
    Log-Line ("screens={0} -> PC-SCREEN-ONLY, result=0x{1:X8}" -f $n, $r)
} else {
    # SDC_TOPOLOGY_EXTEND (0x4) | SDC_APPLY (0x80): extend to secondary
    $r = [Topo]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, 0x84)
    Log-Line ("screens={0} -> EXTEND, result=0x{1:X8}" -f $n, $r)
}
exit 0
