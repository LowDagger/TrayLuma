[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$InstallerPath,
    [string]$Repository = 'LowDagger/TrayLuma',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist\packages')
)
$ErrorActionPreference = 'Stop'
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Use a numeric three-part version.' }
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid repository.' }
$sha = (Get-FileHash $InstallerPath -Algorithm SHA256).Hash
$url = "https://github.com/$Repository/releases/download/v$Version/TrayLuma-Setup.exe"
$winget = Join-Path $OutputDirectory "winget\manifests\l\LowDagger\TrayLuma\$Version"
$choco = Join-Path $OutputDirectory 'chocolatey\trayluma'
New-Item -ItemType Directory -Force $winget,(Join-Path $choco 'tools') | Out-Null
@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.1.9.0.schema.json
PackageIdentifier: LowDagger.TrayLuma
PackageVersion: $Version
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.9.0
"@ | Set-Content -Encoding utf8 (Join-Path $winget 'LowDagger.TrayLuma.yaml')
@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.1.9.0.schema.json
PackageIdentifier: LowDagger.TrayLuma
PackageVersion: $Version
InstallerType: inno
Scope: user
MinimumOSVersion: 10.0.18362.0
UpgradeBehavior: install
Installers:
  - Architecture: x64
    InstallerUrl: $url
    InstallerSha256: $sha
    InstallerSwitches:
      Custom: /TASKS=""
ManifestType: installer
ManifestVersion: 1.9.0
"@ | Set-Content -Encoding utf8 (Join-Path $winget 'LowDagger.TrayLuma.installer.yaml')
@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.1.9.0.schema.json
PackageIdentifier: LowDagger.TrayLuma
PackageVersion: $Version
PackageLocale: en-US
Publisher: LowDagger
PublisherUrl: https://github.com/$Repository
PackageName: TrayLuma
PackageUrl: https://github.com/$Repository
License: MIT
LicenseUrl: https://github.com/$Repository/blob/main/LICENSE
ShortDescription: Lightweight native Windows tray brightness control for multiple monitors.
Description: A Rust and Win32 community fork of Universal Monitor Brightness Control, with DDC/CI, WMI and software dimming.
Tags:
  - brightness
  - monitor
  - tray
ManifestType: defaultLocale
ManifestVersion: 1.9.0
"@ | Set-Content -Encoding utf8 (Join-Path $winget 'LowDagger.TrayLuma.locale.en-US.yaml')
@"
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd">
  <metadata>
    <id>trayluma</id><version>$Version</version><title>TrayLuma</title>
    <authors>LowDagger; Priyanshu Yadav (upstream)</authors><owners>LowDagger</owners>
    <projectUrl>https://github.com/$Repository</projectUrl>
    <licenseUrl>https://github.com/$Repository/blob/main/LICENSE</licenseUrl>
    <requireLicenseAcceptance>false</requireLicenseAcceptance>
    <summary>Lightweight native Windows monitor brightness control.</summary>
    <description>Rust/Win32 tray brightness control with DDC/CI, WMI and software dimming. Installs for the current user. Community fork; original author credited in NOTICE.md.</description>
    <tags>brightness monitor tray windows rust</tags>
  </metadata>
  <files><file src="tools\**" target="tools" /></files>
</package>
"@ | Set-Content -Encoding utf8 (Join-Path $choco 'trayluma.nuspec')
@"
`$ErrorActionPreference = 'Stop'
`$packageArgs = @{
  packageName = 'trayluma'
  fileType = 'exe'
  url64bit = '$url'
  checksum64 = '$sha'
  checksumType64 = 'sha256'
  silentArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /TASKS=""'
  validExitCodes = @(0,3010)
}
Install-ChocolateyPackage @packageArgs
"@ | Set-Content -Encoding utf8 (Join-Path $choco 'tools\chocolateyInstall.ps1')
@'
$ErrorActionPreference = 'Stop'
$uninstaller = "$env:LOCALAPPDATA\Programs\TrayLuma\unins000.exe"
if (Test-Path $uninstaller) {
  Uninstall-ChocolateyPackage -PackageName 'trayluma' -FileType 'exe' -File $uninstaller -SilentArgs '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -ValidExitCodes @(0,3010)
}
'@ | Set-Content -Encoding utf8 (Join-Path $choco 'tools\chocolateyUninstall.ps1')
@"
VERIFICATION
Download URL: $url
SHA-256: $sha
Source: https://github.com/$Repository/tree/v$Version
The package downloads the public installer; it does not embed a private binary.
This is a per-user installation. Run under the intended Windows account.
"@ | Set-Content -Encoding utf8 (Join-Path $choco 'tools\VERIFICATION.txt')
Copy-Item (Join-Path $PSScriptRoot '..\LICENSE') (Join-Path $choco 'tools\LICENSE.txt')
Compress-Archive -Path "$OutputDirectory\winget","$OutputDirectory\chocolatey" -DestinationPath (Join-Path (Split-Path $OutputDirectory) 'package-manifests.zip') -Force
'Generated manifests only. Community publication requires separate submissions and review.'
