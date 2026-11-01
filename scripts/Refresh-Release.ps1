# Only run on trusted release assets. Reads metadata and scans; never runs an uploaded executable.
[CmdletBinding()]
param([string]$Tag, [string]$Repository='LowDagger/TrayLuma', [switch]$Force)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
if (!$Tag) {
    $Tag = gh release view --repo $Repository --json tagName --jq .tagName
    if ($LASTEXITCODE) { throw 'No published release found. Create a release first.' }
}
if ($Tag -notmatch '^v\d+\.\d+\.\d+$') { throw 'Invalid release tag.' }
gh release download $Tag --repo $Repository --pattern TrayLuma.exe --dir $dist --clobber
if ($LASTEXITCODE) { throw 'Upload an asset named TrayLuma.exe before refreshing.' }
$release = gh release view $Tag --repo $Repository --json assets,body | ConvertFrom-Json
if ($LASTEXITCODE) { throw 'Unable to inspect release.' }
$previous = $null
if ($release.assets.name -contains 'release-report.json') {
    gh release download $Tag --repo $Repository --pattern release-report.json --dir $dist --clobber
    if ($LASTEXITCODE) { throw 'Could not download previous report.' }
    $previous = Get-Content "$dist\release-report.json" -Raw | ConvertFrom-Json
}
$exe = Join-Path $dist 'TrayLuma.exe'
$sha = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
$oldExe = @($previous.files | Where-Object filename -eq 'TrayLuma.exe') | Select-Object -First 1
$matches = $false
if ($oldExe -and $oldExe.sha256 -eq $sha -and $release.assets.name -contains 'TrayLuma-Setup.exe') {
    gh release download $Tag --repo $Repository --pattern TrayLuma-Setup.exe --dir $dist --clobber
    if ($LASTEXITCODE) { throw 'Could not download installer.' }
    $oldSetup = @($previous.files | Where-Object filename -eq 'TrayLuma-Setup.exe') | Select-Object -First 1
    $matches = $oldSetup -and $oldSetup.sha256 -eq (Get-FileHash "$dist\TrayLuma-Setup.exe" -Algorithm SHA256).Hash.ToLowerInvariant()
}
if ($matches -and $env:VT_API_KEY -and @($previous.files | Where-Object { $_.virustotal.status -in @('not-configured','pending','api-error','error') }).Count) {
    $Force = $true # Finish a previously unavailable/incomplete analysis once configured.
}
if ($matches -and !$Force) { 'Current binary hashes already have reports. Nothing changed.'; return }
$version = (Get-Item $exe).VersionInfo.ProductVersion
if ($version -ne $Tag.Substring(1)) { throw 'Uploaded executable product version must match the release tag.' }
if (!$oldExe -or $oldExe.sha256 -ne $sha -or !$matches) {
    & (Join-Path $PSScriptRoot 'Build-Installer.ps1') -SkipBuild
}
$defenderFailed = $false
try { & (Join-Path $PSScriptRoot 'Scan-Defender.ps1') -Files $exe,"$dist\TrayLuma-Setup.exe" -OutputDirectory "$dist\security" }
catch { $defenderFailed=$true; Write-Warning 'Defender reported an issue. Reports will still be attached.' }
python (Join-Path $PSScriptRoot 'release_report.py') $exe "$dist\TrayLuma-Setup.exe" --output $dist --defender "$dist\security\defender.json" --tag $Tag --repository $Repository --upload-virustotal
$scanCode = $LASTEXITCODE
if ($scanCode -notin @(0,2)) { throw 'Report generation failed.' }
& (Join-Path $PSScriptRoot 'New-PackageManifests.ps1') -Version $version -InstallerPath "$dist\TrayLuma-Setup.exe" -Repository $Repository
gh release upload $Tag "$dist\SHA256SUMS.txt" "$dist\release-report.json" "$dist\security-report.md" --repo $Repository --clobber
if ($LASTEXITCODE) { throw 'Report upload failed.' }
if (!$defenderFailed -and $scanCode -eq 0) {
    gh release upload $Tag "$dist\TrayLuma-Setup.exe" "$dist\package-manifests.zip" --repo $Repository --clobber
    if ($LASTEXITCODE) { throw 'Installer/package-manifest upload failed.' }
}
$notes = [string]$release.body
$notes = [regex]::Replace($notes,'(?s)\s*<!-- trayluma-verification:start -->.*?<!-- trayluma-verification:end -->','')
$url = "https://github.com/$Repository/releases/download/$Tag"
$notes += "`n`n<!-- trayluma-verification:start -->`n## Current binary verification`n[Scan report]($url/security-report.md) · [SHA-256]($url/SHA256SUMS.txt) · [Package manifests]($url/package-manifests.zip)`nReports are tied to file hashes; a missing or pending scan is not a clean result.`n<!-- trayluma-verification:end -->`n"
$notes | Set-Content -Encoding utf8 "$dist\release-notes.md"
gh release edit $Tag --repo $Repository --notes-file "$dist\release-notes.md"
if ($LASTEXITCODE) { throw 'Release note update failed.' }
if ($defenderFailed -or $scanCode -eq 2) { throw 'One or more scans reported a problem; inspect the attached report.' }
