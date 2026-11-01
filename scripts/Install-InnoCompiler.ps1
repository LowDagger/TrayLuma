# Build-time tool only. Fixed official release, pinned hash and verified publisher.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$tools = Join-Path (Split-Path $PSScriptRoot) 'target\tools'
$dir = Join-Path $tools 'inno'
New-Item -ItemType Directory -Force $tools | Out-Null
$setup = Join-Path $tools 'innosetup-6.7.4.exe'
$expected = 'a549929319f9120716677c685535ca4671e4b937b5fdc87e2585f32d8eb30e8c'
if (!(Test-Path $setup)) {
    Invoke-WebRequest 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_4/innosetup-6.7.4.exe' -OutFile $setup
}
if ((Get-FileHash $setup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Inno Setup download hash mismatch.' }
$signature = Get-AuthenticodeSignature $setup
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN=Pyrsys B\.V\.') { throw 'Inno Setup signature/publisher verification failed.' }
$p = Start-Process $setup -ArgumentList '/CURRENTUSER','/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/NOICONS',"/DIR=`"$dir`"" -Wait -PassThru
if ($p.ExitCode) { throw "Compiler setup failed ($($p.ExitCode))." }
Get-Item (Join-Path $dir 'ISCC.exe') | Select-Object FullName,Length
