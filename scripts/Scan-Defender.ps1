[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Files,
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$results = @()
$status = $null
try { $status = Get-MpComputerStatus -ErrorAction Stop } catch { }
$platform = "$env:ProgramData\Microsoft\Windows Defender\Platform"
$scanner = @(Get-ChildItem "$platform\*\MpCmdRun.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -ExpandProperty FullName)
if (!$scanner.Count) { $scanner = @("$env:ProgramFiles\Windows Defender\MpCmdRun.exe") }
$detected = $false
foreach ($file in $Files) {
    $item = Get-Item $file
    $record = [ordered]@{
        filename=$item.Name; sha256=(Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()
        timestamp_utc=(Get-Date).ToUniversalTime().ToString('o'); status='unavailable'
        signature_status=(Get-AuthenticodeSignature $file).Status.ToString()
        antivirus_signature_version=if ($status) { $status.AntivirusSignatureVersion } else { $null }
    }
    if ($status -and $status.AntivirusEnabled -and (Test-Path $scanner[0])) {
        $log = Join-Path $OutputDirectory "$($item.Name).defender.log"
        & $scanner[0] -Scan -ScanType 3 -File $item.FullName -DisableRemediation 2>&1 | Out-File -Encoding utf8 $log
        $record.exit_code = $LASTEXITCODE
        if ($LASTEXITCODE -eq 0) { $record.status='completed-no-threats-reported' }
        elseif ($LASTEXITCODE -eq 2) { $record.status='detections-or-scan-error'; $detected=$true }
        else { $record.status='scan-error' }
    }
    $results += [pscustomobject]$record
}
ConvertTo-Json -InputObject @($results) -Depth 8 | Set-Content -Encoding utf8 (Join-Path $OutputDirectory 'defender.json')
if ($detected) { throw 'Defender reported detections or a scan error. Inspect the saved log; no remediation was requested.' }
