[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$exe = "$env:LOCALAPPDATA\Programs\TrayLuma\TrayLuma.exe"
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'TrayLuma.lnk'
$apps = @(Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
    Get-ItemProperty | Where-Object DisplayName -eq 'TrayLuma')
$running = @(Get-Process TrayLuma -ErrorAction SilentlyContinue | Where-Object Path -eq $exe)
$run = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name TrayLuma -ErrorAction SilentlyContinue
$target = if (Test-Path $shortcut) { (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut).TargetPath } else { $null }
$result = [pscustomobject]@{
    executable = $exe; exists = Test-Path $exe; start_menu_shortcut = Test-Path $shortcut
    shortcut_target_correct = $target -eq $exe
    installed_apps_entry = $apps.Count -eq 1; running = $running.Count -gt 0; startup = [bool]$run
    version = if (Test-Path $exe) { (Get-Item $exe).VersionInfo.ProductVersion } else { $null }
    sha256 = if (Test-Path $exe) { (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
}
$result
$reportDir = Join-Path $env:LOCALAPPDATA 'TrayLuma'
New-Item -ItemType Directory -Force $reportDir | Out-Null
$result | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $reportDir 'installation.json')
if (!$result.exists -or !$result.shortcut_target_correct -or !$result.installed_apps_entry) { throw 'Installation verification failed.' }
