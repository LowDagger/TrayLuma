# Releases and community distribution

## One-time setup

1. Enable Actions on this fork. Release jobs need the repository's normal
   `GITHUB_TOKEN` write permission (declared in the workflow).
2. Optional: add **Settings → Secrets and variables → Actions → `VT_API_KEY`**.
   Do not paste it into issues, source files, command-line arguments or chat.
   This opts public release artifacts into VirusTotal sharing; follow its API
   terms/quotas. The script rate-limits requests and never logs the key.
3. Code signing is not configured. An antivirus report does not replace a code
   signature or establish SmartScreen reputation.

## Recommended: versioned source releases

Update the version in `Cargo.toml`, `Cargo.lock`, and `assets/trayluma.rc`.
Keep the default version in `packaging/TrayLuma.iss` in sync as well. Test locally,
commit, then push a version tag:

```powershell
git tag v1.2.0
git push fork main
git push fork v1.2.0
```

`Build release` tests Rust and tooling, builds the portable executable and Inno
Setup installer, runs a demo benchmark, scans with Defender when available,
optionally submits both binaries to VirusTotal, generates hash-bound reports
and package submissions, and creates a release. Detected malicious/suspicious
results block automatic publication. Missing/pending/error AV results are
reported honestly; inspect them before recommending a release to users.

The source build workflow does not overwrite an existing release. Use a new
version for every public binary, especially after a package-manager submission.
GitHub-hosted Windows runners never validate actual DDC/CI hardware behavior.

## If you upload an executable yourself

Create a release named `vX.Y.Z` and upload an asset named **TrayLuma.exe**.
Its embedded ProductVersion must be `X.Y.Z`.

`Refresh uploaded release` rebuilds an installer around the changed executable,
hashes/scans both, updates report assets and package manifests, and links them
from the release description. It **does not execute the uploaded application**
or pretend that its source was reproduced or benchmarked.

GitHub has **no release-asset-upload Actions event**. Therefore:

- Publishing/editing a release triggers the refresh workflow.
- A scheduled run checks the latest published release every six hours; GitHub
  may delay scheduled workflows. It skips unchanged, already-recorded hashes.
- For an immediate refresh, use **Actions → Refresh uploaded release → Run
  workflow**, specify the tag, and optionally check **force** to rescan.
- GitHub can disable scheduled Actions on inactive repositories/forks. Ensure
  the workflow is enabled. Uploads to older releases require manual dispatch.
- Events created with `GITHUB_TOKEN` do not normally trigger other workflows;
  the source-release workflow therefore performs its own scans and packaging.

Never reuse the scan result from an older executable. `release-report.json`
binds every observation to filename, SHA-256 and time. VirusTotal links can exist
before any scan does; pending/not-configured/error is never labelled clean.
Reports are advisory, not a malware guarantee. See `SECURITY.md`.

## Local installer and benchmarks

For the full local pipeline, use `.\scripts\Verify-Release.ps1` (or `-Quick` for
a demo smoke run). Add `-UploadVirusTotal` only when intentionally sharing public
binaries and `VT_API_KEY` is present in your process environment. No key is ever
needed by the installed app. The individual commands are:

```powershell
.\scripts\Build-Installer.ps1
.\scripts\Scan-Defender.ps1 -Files dist\TrayLuma.exe,dist\TrayLuma-Setup.exe -OutputDirectory dist\security
python scripts/release_report.py dist/TrayLuma.exe dist/TrayLuma-Setup.exe --output dist --defender dist/security/defender.json
.\install.ps1 -StartWithWindows
.\scripts\Test-Installation.ps1
```

Python 3 is only for maintainer reporting scripts, not the installed app. Use
`-MigrateLegacy` when replacing the original per-user BrightnessTray installation.
It stops only the legacy installed executable, removes its matching startup
entry, and retains its executable and shortcut preferences for rollback.
TrayLuma intentionally retains the legacy settings key and production mutex for
compatibility; do not run another original BrightnessTray copy alongside it.

If you need the pinned, verified installer compiler, run
`.\scripts\Install-InnoCompiler.ps1`. It installs the build tool into
`target\tools\inno` for the current user; it is not shipped with TrayLuma.

## WinGet

Each release's `package-manifests.zip` contains multi-file manifests for
`LowDagger.TrayLuma`, including the exact installer SHA-256 and per-user scope.

1. Extract them and run `winget validate --manifest <version-directory>`.
2. Test locally with WinGet's local-manifest mode (requires the corresponding
   Windows/App Installer setting; do not change it silently for other users).
3. Submit the directory to [microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs)
   and complete its automated checks/review. Community maintainers control approval.

The manifests deliberately do not claim an approved package identifier, existing
store listing, or publisher verification. Regenerate and submit for each version.
Do not replace installer bytes at an already-approved version URL.

## Chocolatey

The same archive contains a `trayluma` nuspec, checksum-pinned install/uninstall
scripts, attribution, and verification information. From its directory:

```powershell
choco pack trayluma.nuspec
```

Test in a disposable Windows VM, then publish using **your own Chocolatey account
and API key** and complete community moderation. Package-name availability and
approval are not guaranteed. The installer is per-user: use the intended Windows
account. Do not add package API keys to GitHub until publication is deliberately
configured; no automatic community submissions are made by these workflows.

## Architecture and footprint

Installer/compiler, CI, Python reporting and package tooling run at build/release
time only. The installed app remains Rust + raw `windows-rs`, with no service or
added runtime framework. The installer's compressed size is not runtime memory.
The original sun tray glyph stays monochrome for light/dark theme legibility;
Explorer, Start menu and the installer use the new monitor-and-sun icon.
