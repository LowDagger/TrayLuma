[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$uninstaller = "$env:LOCALAPPDATA\Programs\TrayLuma\unins000.exe"
if (!(Test-Path $uninstaller)) { throw 'TrayLuma uninstaller not found.' }
$p = Start-Process $uninstaller -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru
if ($p.ExitCode) { throw "Uninstall failed ($($p.ExitCode))." }
'TrayLuma removed. Shared legacy shortcut preferences were preserved.'
