# One local command to test, build, benchmark, package, scan and generate manifests.
[CmdletBinding()]
param([switch]$Quick, [switch]$UploadVirusTotal, [string]$Python)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
if (!$Python) {
    $command = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source -notlike '*\WindowsApps\*') { $Python=$command.Source }
    else {
        $Python = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python*\python.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
}
if (!$Python) { throw 'Python 3 is needed only for release reports. Pass -Python <python.exe>.' }
$env:PATH = "$env:USERPROFILE\.cargo\bin;" + $env:PATH
Push-Location $root
try {
    cargo test --locked
    if ($LASTEXITCODE) { throw 'Rust tests failed.' }
    cargo clippy --locked --all-targets -- -D warnings
    if ($LASTEXITCODE) { throw 'Clippy failed.' }
    & $Python -m unittest discover -s tests -v
    if ($LASTEXITCODE) { throw 'Reporting tests failed.' }
    & "$PSScriptRoot\Test-Scripts.ps1"
    & "$PSScriptRoot\Build-Installer.ps1"
    if ($Quick) { & "$PSScriptRoot\Benchmark.ps1" -ExePath dist\TrayLuma.exe -Demo -IdleSeconds 3 -Cycles 5 -Launches 2 }
    else { & "$PSScriptRoot\Benchmark.ps1" -ExePath dist\TrayLuma.exe }
    & "$PSScriptRoot\Scan-Defender.ps1" -Files dist\TrayLuma.exe,dist\TrayLuma-Setup.exe -OutputDirectory dist\security
    $argsList = @('scripts/release_report.py','dist/TrayLuma.exe','dist/TrayLuma-Setup.exe','--output','dist','--defender','dist/security/defender.json')
    if ($UploadVirusTotal) { $argsList += '--upload-virustotal' }
    & $Python @argsList
    if ($LASTEXITCODE) { throw 'Scan/report verification failed.' }
    $version = (Get-Item dist\TrayLuma.exe).VersionInfo.ProductVersion
    & "$PSScriptRoot\New-PackageManifests.ps1" -Version $version -InstallerPath dist\TrayLuma-Setup.exe
    'Verification complete. Artifacts/reports: dist\. Local benchmarks: %LOCALAPPDATA%\TrayLuma\Benchmarks.'
} finally { Pop-Location }
