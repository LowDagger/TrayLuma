# Install the tested per-user package. No administrator rights required.
[CmdletBinding()]
param([switch]$StartWithWindows, [switch]$MigrateLegacy)
$ErrorActionPreference = 'Stop'
$setup = Join-Path $PSScriptRoot 'dist\TrayLuma-Setup.exe'
if (!(Test-Path $setup)) { throw 'Run .\scripts\Build-Installer.ps1 first.' }
if ($MigrateLegacy) {
    $legacy = "$env:LOCALAPPDATA\Programs\BrightnessTray\BrightnessTray.exe"
    Get-Process BrightnessTray -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $legacy } | Stop-Process
    # Keep the old executable and shared shortcut preferences for rollback.
}
$tasks = if ($StartWithWindows) { 'startup' } else { '' }
$p = Start-Process $setup -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/TASKS=`"$tasks`"" -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "Installer failed ($($p.ExitCode))." }
if ($MigrateLegacy) {
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $value = Get-ItemPropertyValue $run -Name BrightnessTray -ErrorAction SilentlyContinue
    if ($value -and $value.Contains($legacy)) { Remove-ItemProperty $run -Name BrightnessTray }
}
Start-Process "$env:LOCALAPPDATA\Programs\TrayLuma\TrayLuma.exe" -ArgumentList '--background'
& (Join-Path $PSScriptRoot 'scripts\Test-Installation.ps1')
