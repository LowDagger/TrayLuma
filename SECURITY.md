# Security and privacy

Report suspected vulnerabilities privately through GitHub security advisories
when available. Do not include tokens, private monitor serials or full system
dumps in public issues. General bugs can be reported as normal issues.

The application contains no telemetry or update-downloading background service.
Benchmarks are local by default; nothing automatically uploads your PC's reports.

Release tooling optionally sends **public release executables and installers**
to VirusTotal when the maintainer supplies `VT_API_KEY` and enables upload.
Submitted files may be shared with security vendors/community under VirusTotal's
terms. Do not submit private builds or credentials. Local Defender scans request
no remediation, and save their result or an explicit unavailable/error status.

Scan observations include the exact SHA-256 and time. No scan, missing credentials,
an API error, incomplete analysis or an unsupported engine is not a clean result.
Even zero reported detections is not proof that software is safe. A report for an
older file never establishes anything about a replacement file.

Releases are currently unsigned. Code signing/SmartScreen reputation and Microsoft
Store distribution are separate tasks; a Start menu shortcut is not a Store listing.

Fork attribution and original MIT notices are retained in LICENSE and NOTICE.md.
