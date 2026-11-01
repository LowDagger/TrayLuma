$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$bad = $false
foreach ($file in @(Get-ChildItem "$PSScriptRoot\*.ps1") + @(Get-ChildItem "$root\*.ps1")) {
    $tokens=$null; $errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors) { $errors | Write-Output; $bad=$true }
}
if ($bad) { throw 'PowerShell parser checks failed.' }
'PowerShell scripts parse successfully.'
