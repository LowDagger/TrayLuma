[CmdletBinding()]
param([string]$Compiler, [switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
if (!$SkipBuild) { & (Join-Path $root 'build.ps1'); if ($LASTEXITCODE) { throw 'Release build failed.' } }
if (!$Compiler) {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$root\target\tools\inno\ISCC.exe"
    )
    $found = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($found) { $candidates = @($found.Source) + $candidates }
    $Compiler = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (!$Compiler -or !(Test-Path $Compiler)) { throw 'Install Inno Setup 6 (winget install --id JRSoftware.InnoSetup -e), or pass -Compiler <ISCC.exe>.' }
$exe = Join-Path $root 'dist\TrayLuma.exe'
if (!(Test-Path $exe)) { throw 'Build dist\TrayLuma.exe first.' }
$version = (Get-Item $exe).VersionInfo.ProductVersion
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Executable has invalid product version metadata.' }
& $Compiler "/DAppVersion=$version" (Join-Path $root 'packaging\TrayLuma.iss')
if ($LASTEXITCODE) { throw "Inno Setup failed ($LASTEXITCODE)." }
Get-Item (Join-Path $root 'dist\TrayLuma-Setup.exe') | Select-Object FullName,Length
