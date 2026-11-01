<p align="center"><img src="assets/trayluma.png" width="80" alt="TrayLuma monitor and sun icon"></p>

# TrayLuma

**Small, native Windows brightness control for your monitors.**

[![CI](https://github.com/LowDagger/TrayLuma/actions/workflows/ci.yml/badge.svg)](https://github.com/LowDagger/TrayLuma/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/LowDagger/TrayLuma)](https://github.com/LowDagger/TrayLuma/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Rust + raw Win32. No GUI framework, bundled runtime, background service, or
periodic monitor polling while idle.

## Install

Download **[TrayLuma-Setup.exe](https://github.com/LowDagger/TrayLuma/releases/latest/download/TrayLuma-Setup.exe)**
from the [latest release](https://github.com/LowDagger/TrayLuma/releases/latest).
It installs for your Windows account without administrator rights. Find
**TrayLuma** in Windows Search; uninstall from **Settings → Apps → Installed apps**.
Startup at sign-in and a desktop shortcut are optional.

Prefer no installation? Download **[TrayLuma.exe](https://github.com/LowDagger/TrayLuma/releases/latest/download/TrayLuma.exe)**.
Windows 10 version 1903+ or Windows 11, x64. Unsigned releases may show SmartScreen
warnings; verify the release hash and scan report before deciding to run one.

**WinGet and Chocolatey:** submission files are generated with each release.
They are **not published community packages yet**. Do not assume `winget install`
or `choco install trayluma` works until the respective submission is approved.

## Use

- Click the sun in the tray for one brightness slider per display.
- Right-click for keyboard shortcuts, **Start with Windows**, or **Exit**.
- Laptop panels use WMI; external monitors use DDC/CI; unsupported displays use
  a labelled software-dimming overlay.
- Monitor names use Windows display configuration, validated EDID, and graceful
  GDI/DDC fallbacks. Discovery happens when you open the popup.

Enable DDC/CI in the monitor's own menu. Some docks, cables and picture modes
block it. Software dimming changes the image, not backlight power, and can have
fullscreen/cursor limitations. Contrast is not included in this release.

## Performance and antivirus reports

Each source release includes:

- **[SHA256SUMS.txt](https://github.com/LowDagger/TrayLuma/releases/latest/download/SHA256SUMS.txt)** for the portable app and installer.
- **[security-report.md](https://github.com/LowDagger/TrayLuma/releases/latest/download/security-report.md)** and machine-readable
  **[release-report.json](https://github.com/LowDagger/TrayLuma/releases/latest/download/release-report.json)**.
- A demo-mode benchmark and scan logs in `verification-details.zip`.

VirusTotal upload is opt-in via the maintainer's `VT_API_KEY` GitHub Secret.
Without it, workflows skip VirusTotal and say **not-requested**, not "clean".
With a key configured, API failures or incomplete analyses make the scan job fail
after saving its diagnostics. Results are bound to the
exact file hash and scan time; they are not a guarantee of safety.

CI demo benchmarks do **not** measure real monitor communication. Working set is
explicitly trimmed: always read **private bytes as well as working set**.

Run your own read-only benchmark:

```powershell
.\scripts\Benchmark.ps1 -ExePath .\dist\TrayLuma.exe
```

Results are saved under `%LOCALAPPDATA%\TrayLuma\Benchmarks` as JSON, CSV and
Markdown. See [benchmark methodology](docs/BENCHMARKS.md).

## Build

Install Rust and the Visual Studio C++ build tools with a Windows SDK, then:

```powershell
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
.\build.ps1                         # dist\TrayLuma.exe
.\scripts\Build-Installer.ps1        # requires Inno Setup 6
.\install.ps1 -StartWithWindows      # optional local installation
```

The Cargo output retains the upstream name `target\release\BrightnessTray.exe`;
the release script copies it to `dist\TrayLuma.exe`. GNU builds additionally need
MinGW `windres` on PATH (or the `WINDRES` environment variable).

## Community and credits

TrayLuma is LowDagger's community fork of
[Universal Monitor Brightness Control](https://github.com/PriyanshuGeTRekT/Universal-Monitor-Brightness-control)
by **Priyanshu Yadav**. The original brightness engine and interface are upstream
work; this fork adds monitor-name reliability, packaging, benchmarks and release
verification. See [NOTICE.md](NOTICE.md) and the [MIT license](LICENSE).

[Report a bug](https://github.com/LowDagger/TrayLuma/issues) ·
[Release and package-manager guide](docs/RELEASING.md) · [Security](SECURITY.md)
