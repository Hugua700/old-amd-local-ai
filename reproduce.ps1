<#
  re-runs the measurements behind the documents in this repository.
  Read-only: it starts nothing, stops nothing, and changes no setting. It reports.

  Usage (Windows PowerShell, no admin needed):
      powershell -NoProfile -ExecutionPolicy Bypass -File .\reproduce.ps1
      powershell ... -File .\reproduce.ps1 -Seconds 60 -Port 8085

  Only the PowerShell-internal parts are reproduced here - device indices, the VRAM
  accounting, the model-server sizing, and a power/temperature sample. The two-GPU
  encoder measurement and the diffusion timings need the workloads themselves; see
  BENCH-PROTOCOL.md for how those were taken.
#>
[CmdletBinding()]
param(
    [int] $Seconds = 30,          # how long to sample power/temperature
    [int] $Port    = 8085,        # the local model server to inspect
    [string] $LhmDll = ''         # optional: path to LibreHardwareMonitorLib.dll
)

function Head($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Say($t)  { Write-Host "   $t" }

Head '1. Graphics devices as Windows sees them'
try {
    Get-CimInstance Win32_VideoController | ForEach-Object {
        Say ("{0}   driver {1}   VRAM(adapter) {2:N0} MB" -f $_.Name, $_.DriverVersion, ($_.AdapterRAM / 1MB))
    }
} catch { Say "unavailable: $($_.Exception.Message)" }

Head '2. Physical memory'
$os = Get-CimInstance Win32_OperatingSystem
Say ("total {0:N1} GB   free {1:N1} GB" -f ($os.TotalVisibleMemorySize / 1MB), ($os.FreePhysicalMemory / 1MB))

Head '3. Vulkan device enumeration (needs the Vulkan SDK or a llama.cpp build on PATH)'
$vi = Get-Command vulkaninfo, vulkaninfoSDK -ErrorAction SilentlyContinue | Select-Object -First 1
if ($vi) {
    & $vi.Source --summary 2>&1 | Select-String 'GPU\d|deviceName|deviceType' |
        Select-Object -First 12 | ForEach-Object { Say ($_.Line.Trim()) }
    Say 'NOTE: the index order here is what GGML_VK_VISIBLE_DEVICES selects from.'
    Say '      Do not assume 0 is the integrated GPU - enumerate.'
} else {
    $ls = Get-Command llama-server -ErrorAction SilentlyContinue
    if ($ls) { & $ls.Source --list-devices 2>&1 | Select-Object -First 12 | ForEach-Object { Say $_ } }
    else { Say 'no vulkaninfo and no llama-server found - skipping' }
}

Head "4. Is a model server listening on :$Port"
$conn = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if ($conn) {
    $p = Get-Process -Id $conn[0].OwningProcess -ErrorAction SilentlyContinue
    Say ("yes - pid {0} ({1}), working set {2:N0} MB" -f $conn[0].OwningProcess, $p.ProcessName, ($p.WorkingSet64 / 1MB))
    try {
        $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 8
        Say ("health: " + ($h | ConvertTo-Json -Compress))
    } catch { Say "health endpoint did not answer ($($_.Exception.Message))" }
} else {
    Say 'no - nothing is listening. A second model started now would take the VRAM.'
}

Head '5. GPU memory accounting'
if ($LhmDll -and (Test-Path $LhmDll)) {
    $py = @"
import pythonnet
pythonnet.load('coreclr')
import clr
clr.AddReference(r'$LhmDll')
from LibreHardwareMonitor.Hardware import Computer
c = Computer(); c.IsGpuEnabled = True; c.Open()
for hw in c.Hardware:
    hw.Update()
    for s in hw.Sensors:
        if str(s.SensorType) == 'SmallData' and 'Memory' in s.Name:
            print('   %-22s %-30s = %.0f' % (hw.Name, s.Name, s.Value))
c.Close()
"@
    $py | Out-File "$env:TEMP\_repro_lhm.py" -Encoding utf8
    $exe = (Get-Command python -ErrorAction SilentlyContinue).Source
    if ($exe) { & $exe "$env:TEMP\_repro_lhm.py" 2>&1 | Select-Object -First 12 | ForEach-Object { Say $_ } }
    else { Say 'python not on PATH - skipping' }
    Remove-Item "$env:TEMP\_repro_lhm.py" -Force -ErrorAction SilentlyContinue
} else {
    Say 'pass -LhmDll <path to LibreHardwareMonitorLib.dll> to include this'
}

Head "6. Sampling power and temperature for $Seconds s"
Say 'the documents were written from a 2 s-interval logger; the shape of the numbers is'
Say 'what matters - a peak against your adapter rating, and the hot spot under load.'
$samples = [math]::Max(3, [int]($Seconds / 2))
$peakCpu = 0; $peakGpu = 0; $peakHot = 0; $sum = 0; $n = 0
for ($i = 1; $i -le $samples; $i++) {
    # counters that exist on most AMD/NVIDIA Windows installs; silently skipped when absent
    try {
        $cpu = (Get-Counter '\Power Meter(*)\Power' -ErrorAction Stop).CounterSamples |
               Measure-Object CookedValue -Sum
        if ($cpu.Sum -gt 0) { $peakCpu = [math]::Max($peakCpu, $cpu.Sum); $sum += $cpu.Sum; $n++ }
    } catch { }
    Start-Sleep -Seconds 2
}
if ($n -gt 0) { Say ("CPU package power: peak {0:N1} W, mean {1:N1} W over {2} samples" -f $peakCpu, ($sum / $n), $n) }
else { Say 'power counters unavailable on this machine - use a hardware monitor instead' }

Head '7. Reminder for the reader'
Say 'If you are about to start a second large model, stop the first one and re-check step 5.'
Say 'If a run fails with a message that does not mention VRAM, check step 5 before debugging.'
Say 'If your loudest workload peaks above your adapter rating, that is the finding.'