[CmdletBinding()]
param([string]$Root = (Join-Path $env:LOCALAPPDATA 'TrayLuma\Benchmarks'))
$ErrorActionPreference = 'Stop'
if (!(Test-Path $Root)) { throw 'Benchmark directory does not exist yet.' }
$history = @()
foreach ($dir in Get-ChildItem $Root -Directory) {
    $file = Join-Path $dir.FullName 'report.json'
    if (!(Test-Path $file)) { continue }
    $r = Get-Content $file -Raw | ConvertFrom-Json
    if ($r.status -ne 'completed') { continue }
    $cycles = @($r.samples | Where-Object phase -eq 'cycle-closed')
    $tailCount = [math]::Max(1,[int][math]::Ceiling($cycles.Count / 4))
    $tail = @($cycles | Select-Object -Last $tailCount)
    $tailDelta = if ($tail.Count -gt 1) { $tail[-1].private_bytes - $tail[0].private_bytes } else { 0 }
    $history += [pscustomobject]@{
        timestamp_utc=$r.timestamp_utc; mode=$r.mode; sha256=$r.sha256; exe_bytes=$r.exe_bytes
        cycles=$r.requested.cycles; idle_cpu_ms=$r.summary.idle_cpu_ms
        idle_wall_ms=$r.summary.idle_wall_ms; private_median_bytes=$r.summary.idle_private_median_bytes
        working_set_median_bytes=$r.summary.idle_working_set_median_bytes
        refresh_p95_ms=$r.summary.refresh_p95_ms; private_delta_bytes=$r.summary.observed_private_delta_bytes
        final_quarter_private_delta_bytes=$tailDelta
        handle_delta=$r.summary.observed_handle_delta; gdi_delta=$r.summary.observed_gdi_delta; user_delta=$r.summary.observed_user_delta
        report_directory=$dir.Name
    }
}
$history = @($history | Sort-Object timestamp_utc)
ConvertTo-Json -InputObject @($history) -Depth 8 | Set-Content -Encoding utf8 (Join-Path $Root 'index.json')
$lines = @('# TrayLuma benchmark history','',
    'Compare only equivalent hardware/setup and mode. Growth is an observation, not a leak diagnosis.', '',
    '| UTC | Mode | Hash prefix | Cycles | Idle CPU ms | Private MiB | Working set KiB | Refresh p95 ms | Handles / GDI / USER delta |',
    '|---|---|---|---:|---:|---:|---:|---:|---|')
foreach ($r in $history) {
    $lines += "| $($r.timestamp_utc) | $($r.mode) | $($r.sha256.Substring(0,8)) | $($r.cycles) | $($r.idle_cpu_ms) | $([math]::Round($r.private_median_bytes/1MB,2)) | $([math]::Round($r.working_set_median_bytes/1KB)) | $($r.refresh_p95_ms) | $($r.handle_delta) / $($r.gdi_delta) / $($r.user_delta) |"
}
$lines += ''; $lines += 'Raw reports retain the SHA-256 and private-memory trend. A short stable run cannot prove the absence of a leak.'
$lines | Set-Content -Encoding utf8 (Join-Path $Root 'index.md')
Get-Content (Join-Path $Root 'index.md')
