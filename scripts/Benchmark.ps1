<# Read-only benchmark. Does not change brightness or touch the installed app. #>
[CmdletBinding()]
param(
    [string]$ExePath = (Join-Path $PSScriptRoot '..\target\release\BrightnessTray.exe'),
    [ValidateRange(1,3600)][int]$IdleSeconds = 60,
    [ValidateRange(1,1000)][int]$Cycles = 30,
    [ValidateRange(1,50)][int]$Launches = 5,
    [ValidateRange(1,120)][int]$TimeoutSeconds = 30,
    [string]$OutputDirectory,
    [switch]$Demo
)
$ErrorActionPreference = 'Stop'
$ExePath = (Resolve-Path $ExePath).Path
$sha = (Get-FileHash $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()
$mode = if ($Demo) { 'demo' } else { 'hardware-read-only' }
if (!$OutputDirectory) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
    $OutputDirectory = Join-Path $env:LOCALAPPDATA "TrayLuma\Benchmarks\$stamp-$($sha.Substring(0,8))-$mode"
}
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
if (!( 'TrayLumaBenchmarkNative' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'BenchmarkNative.cs') }
$samples = [System.Collections.Generic.List[object]]::new()
$timings = [System.Collections.Generic.List[object]]::new()
$oldDemo = $env:BRIGHTNESS_TRAY_DEMO
$process = $null
$window = [IntPtr]::Zero
$failure = $null
$clock = [Diagnostics.Stopwatch]::StartNew()
$report = [ordered]@{
    schema_version = 1; timestamp_utc = (Get-Date).ToUniversalTime().ToString('o')
    mode = $mode; sha256 = $sha; exe_bytes = (Get-Item $ExePath).Length
    product_version = (Get-Item $ExePath).VersionInfo.ProductVersion
    os = [Environment]::OSVersion.VersionString; logical_processors = [Environment]::ProcessorCount
    powershell = $PSVersionTable.PSVersion.ToString()
    requested = @{ idle_seconds_per_phase = $IdleSeconds; cycles = $Cycles; launches = $Launches }
    status = 'running'; limitations = @(
        'Launch readiness means the application window responds to its test protocol, not proof Explorer rendered the tray icon.',
        'Launches use the current OS cache; they are not controlled cold-boot measurements.',
        'No brightness writes, hotkey stress, sleep/resume, unplugging, or power-consumption measurements are automated.',
        'Working set is explicitly trimmed by the app. Private bytes must also be reported.',
        'Demo timings do not measure DDC/CI or WMI; real hardware timings depend on connected monitors.'
    )
}
function Test-Alive {
    $process.Refresh()
    if ($process.HasExited) { throw "Benchmark process exited early (code $($process.ExitCode))." }
}
function Read-Sample([string]$Phase) {
    Test-Alive
    [pscustomobject]@{
        phase = $Phase; elapsed_ms = [math]::Round($clock.Elapsed.TotalMilliseconds,3)
        cpu_ms = $process.TotalProcessorTime.TotalMilliseconds
        working_set_bytes = $process.WorkingSet64; private_bytes = $process.PrivateMemorySize64
        peak_working_set_bytes = $process.PeakWorkingSet64
        handles = $process.HandleCount; threads = $process.Threads.Count
        gdi_objects = [TrayLumaBenchmarkNative]::GetGuiResources($process.Handle,0)
        user_objects = [TrayLumaBenchmarkNative]::GetGuiResources($process.Handle,1)
    }
}
function Wait-Loaded {
    $wait = [Diagnostics.Stopwatch]::StartNew()
    do {
        Test-Alive
        $state = [TrayLumaBenchmarkNative]::Command($window,0)
        if (($state -band 0xffff0000) -ne 0x544c0000) { throw 'Executable does not implement the TrayLuma benchmark protocol.' }
        if ($state -band 1) { return (($state -band 0xfffc) -shr 2) }
        Start-Sleep -Milliseconds 20
    } while ($wait.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    throw 'Display enumeration timed out.'
}
function Measure-Idle([string]$Phase) {
    $samples.Add((Read-Sample $Phase))
    for ($i = 0; $i -lt $IdleSeconds; $i++) {
        Start-Sleep -Seconds 1
        $samples.Add((Read-Sample $Phase))
    }
}
function Percentile($Values, [double]$Percent) {
    $sorted = @($Values | Sort-Object)
    if (!$sorted.Count) { return $null }
    return [math]::Round([double]$sorted[[math]::Max(0,[math]::Ceiling($Percent * $sorted.Count)-1)],3)
}
function Stop-TestProcess {
    if ($process) {
        try {
            if (!$process.HasExited) {
                if ($window -ne [IntPtr]::Zero) { [void][TrayLumaBenchmarkNative]::Command($window,3) }
                if (!$process.WaitForExit(5000)) { $process.Kill(); $process.WaitForExit() }
            }
        } catch { if (!$process.HasExited) { $process.Kill(); $process.WaitForExit() } }
        $process.Dispose()
    }
}
try {
    if ($Demo) { $env:BRIGHTNESS_TRAY_DEMO = '1' }
    elseif ($env:BRIGHTNESS_TRAY_DEMO -or $env:BRIGHTNESS_TRAY_SOFTWARE) { throw 'Clear BRIGHTNESS_TRAY_DEMO and BRIGHTNESS_TRAY_SOFTWARE before hardware benchmarking.' }
    Write-Host "Benchmarking $mode. Popups will open/close; avoid interacting with them. Reports: $OutputDirectory"
    for ($launch = 1; $launch -le $Launches; $launch++) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $process = Start-Process -FilePath $ExePath -ArgumentList '--benchmark','--background' -PassThru
        $window = [IntPtr]::Zero
        do {
            Test-Alive
            $window = [TrayLumaBenchmarkNative]::Find($process.Id)
            if ($window -ne [IntPtr]::Zero) {
                if (([TrayLumaBenchmarkNative]::Command($window,0) -band 0xffff0000) -eq 0x544c0000) { break }
            }
            Start-Sleep -Milliseconds 10
        } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
        if ($window -eq [IntPtr]::Zero -or $watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'Application readiness timed out.' }
        $timings.Add([pscustomobject]@{ phase='background-ready'; iteration=$launch; elapsed_ms=[math]::Round($watch.Elapsed.TotalMilliseconds,3); rows=$null })
        $watch.Restart()
        [void][TrayLumaBenchmarkNative]::Command($window,1)
        $rows = Wait-Loaded
        $timings.Add([pscustomobject]@{ phase='first-enumeration'; iteration=$launch; elapsed_ms=[math]::Round($watch.Elapsed.TotalMilliseconds,3); rows=$rows })
        [void][TrayLumaBenchmarkNative]::Command($window,2)
        if ($launch -lt $Launches) { Stop-TestProcess; $process=$null }
    }
    Start-Sleep -Seconds 2
    Measure-Idle 'idle-before'
    for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        [void][TrayLumaBenchmarkNative]::Command($window,1)
        $rows = Wait-Loaded
        $timings.Add([pscustomobject]@{ phase='refresh'; iteration=$cycle; elapsed_ms=[math]::Round($watch.Elapsed.TotalMilliseconds,3); rows=$rows })
        [void][TrayLumaBenchmarkNative]::Command($window,2)
        Start-Sleep -Milliseconds 250
        $samples.Add((Read-Sample 'cycle-closed'))
    }
    Start-Sleep -Seconds 2
    Measure-Idle 'idle-after'
    $idle = @($samples | Where-Object phase -like 'idle-*')
    $cpu = 0.0; $wall = 0.0
    foreach ($phase in @('idle-before','idle-after')) {
        $points = @($samples | Where-Object phase -eq $phase)
        $cpu += $points[-1].cpu_ms - $points[0].cpu_ms
        $wall += $points[-1].elapsed_ms - $points[0].elapsed_ms
    }
    $before = @($samples | Where-Object phase -eq 'idle-before')[-1]
    $after = @($samples | Where-Object phase -eq 'idle-after')[-1]
    $report.summary = [ordered]@{
        background_ready_p50_ms = Percentile @($timings | Where-Object phase -eq 'background-ready' | ForEach-Object elapsed_ms) 0.5
        enumeration_p50_ms = Percentile @($timings | Where-Object phase -eq 'first-enumeration' | ForEach-Object elapsed_ms) 0.5
        refresh_p95_ms = Percentile @($timings | Where-Object phase -eq 'refresh' | ForEach-Object elapsed_ms) 0.95
        idle_cpu_ms = $cpu; idle_wall_ms = [math]::Round($wall,3)
        idle_cpu_one_core_percent = [math]::Round(100 * $cpu / $wall,6)
        idle_cpu_total_machine_percent = [math]::Round(100 * $cpu / $wall / [Environment]::ProcessorCount,6)
        idle_working_set_median_bytes = Percentile @($idle | ForEach-Object working_set_bytes) 0.5
        idle_private_median_bytes = Percentile @($idle | ForEach-Object private_bytes) 0.5
        observed_private_delta_bytes = $after.private_bytes - $before.private_bytes
        observed_handle_delta = $after.handles - $before.handles
        observed_gdi_delta = $after.gdi_objects - $before.gdi_objects
        observed_user_delta = $after.user_objects - $before.user_objects
    }
    $report.status = 'completed'
} catch {
    $failure = $_.Exception.Message
    $report.status = 'failed'; $report.error = $failure
} finally {
    Stop-TestProcess
    $env:BRIGHTNESS_TRAY_DEMO = $oldDemo
    $report.timings = @($timings.ToArray()); $report.samples = @($samples.ToArray())
    $report | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8 (Join-Path $OutputDirectory 'report.json')
    $samples.ToArray() | Export-Csv -NoTypeInformation -Encoding utf8 (Join-Path $OutputDirectory 'samples.csv')
    $timings.ToArray() | Export-Csv -NoTypeInformation -Encoding utf8 (Join-Path $OutputDirectory 'timings.csv')
    $lines = @('# TrayLuma benchmark', '', "Mode: $mode", "Status: $($report.status)", "SHA-256: $sha", "Executable bytes: $($report.exe_bytes)", '')
    if ($report.summary) { foreach ($entry in $report.summary.GetEnumerator()) { $lines += "- $($entry.Key): $($entry.Value)" } }
    if ($failure) { $lines += "Error: $failure" }
    $lines += ''; $lines += '## Limitations'; $lines += @($report.limitations | ForEach-Object { "- $_" })
    $lines | Set-Content -Encoding utf8 (Join-Path $OutputDirectory 'summary.md')
}
if ($failure) { throw "Benchmark failed: $failure. Partial reports saved to $OutputDirectory" }
Get-Content (Join-Path $OutputDirectory 'summary.md')
if ((Split-Path (Resolve-Path $OutputDirectory).Path) -eq (Join-Path $env:LOCALAPPDATA 'TrayLuma\Benchmarks')) {
    & (Join-Path $PSScriptRoot 'Analyze-Benchmarks.ps1') | Out-Null
}
