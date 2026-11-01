"""Hash-bound release/AV reports; Python standard library only. Never executes input binaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

API = "https://www.virustotal.com/api/v3"
LAST_REQUEST = 0.0


def request(path, key, body=None, content_type=None):
    global LAST_REQUEST
    # Public API default: at most four requests per minute, including uploads.
    time.sleep(max(0, 16 - (time.monotonic() - LAST_REQUEST)))
    headers = {"x-apikey": key, "User-Agent": "TrayLuma-release-report/1"}
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(API + path, data=body, headers=headers)
    LAST_REQUEST = time.monotonic()
    with urllib.request.urlopen(req, timeout=90) as response:
        return json.load(response)


def scan(path, key):
    if path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError("Files over 32 MiB require VirusTotal's large-file API.")
    boundary = "TrayLumaBoundary" + os.urandom(16).hex()
    prefix = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; '
              f'filename="{path.name}"\r\nContent-Type: application/octet-stream\r\n\r\n').encode()
    payload = prefix + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    analysis = request("/files", key, payload, "multipart/form-data; boundary=" + boundary)
    analysis_id = analysis["data"]["id"]
    for _ in range(20):
        result = request("/analyses/" + analysis_id, key)
        attributes = result["data"]["attributes"]
        if attributes["status"] == "completed":
            remote_sha = result.get("meta", {}).get("file_info", {}).get("sha256")
            local_sha = hashlib.sha256(path.read_bytes()).hexdigest()
            if remote_sha and remote_sha != local_sha:
                raise ValueError("VirusTotal response hash did not match the submitted file.")
            return {"status": "completed", "analysis_id": analysis_id,
                    "stats": attributes.get("stats", {}),
                    "engines": attributes.get("results", {}), "analysis_date": attributes.get("date")}
    return {"status": "pending", "analysis_id": analysis_id}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--defender", type=Path)
    parser.add_argument("--upload-virustotal", action="store_true",
                        help="Consent to sharing these public release binaries with VirusTotal.")
    parser.add_argument("--repository", default="LowDagger/TrayLuma")
    parser.add_argument("--tag", default="local")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    defender = []
    if args.defender and args.defender.exists():
        defender = json.loads(args.defender.read_text(encoding="utf-8-sig"))
    key = os.environ.get("VT_API_KEY", "")
    records = []
    detection = False
    for path in args.files:
        sha = hashlib.sha256(path.read_bytes()).hexdigest()
        entry = {"filename": path.name, "sha256": sha, "bytes": path.stat().st_size,
                 "virustotal_url": "https://www.virustotal.com/gui/file/" + sha,
                 "defender": next((d for d in defender if d["sha256"] == sha), None),
                 "virustotal": {"status": "not-requested"}}
        if args.upload_virustotal:
            if not key:
                entry["virustotal"] = {"status": "not-configured", "reason": "VT_API_KEY secret is absent"}
            else:
                try:
                    entry["virustotal"] = scan(path, key)
                except urllib.error.HTTPError as error:
                    entry["virustotal"] = {"status": "api-error", "http_status": error.code}
                except Exception as error:
                    # Do not record request headers, credentials, or response bodies.
                    entry["virustotal"] = {"status": "error", "error_type": type(error).__name__}
        stats = entry["virustotal"].get("stats", {})
        detection |= bool(stats.get("malicious", 0) or stats.get("suspicious", 0))
        detection |= bool(entry["defender"] and entry["defender"]["status"] == "detections-or-scan-error")
        records.append(entry)
    report = {"schema_version": 1, "timestamp_utc": datetime.now(timezone.utc).isoformat(),
              "repository": args.repository, "tag": args.tag, "detections_reported": detection,
              "notice": "A scan is a point-in-time observation, not a security guarantee. Not-configured/pending is not clean.",
              "files": records}
    (args.output / "release-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    lines = ["# TrayLuma release verification", "", report["notice"], "",
             "Generated: " + report["timestamp_utc"], "",
             "| Artifact | Bytes | Defender | VirusTotal |", "|---|---:|---|---|"]
    for item in records:
        vt = item["virustotal"]
        text = vt["status"]
        if vt["status"] == "completed":
            stats = vt["stats"]
            text += f': {stats.get("malicious", 0)} malicious, {stats.get("suspicious", 0)} suspicious'
        local = item["defender"]["status"] if item["defender"] else "not-run"
        lines.append(f'| {item["filename"]} | {item["bytes"]} | {local} | [{text}]({item["virustotal_url"]}) |')
    lines += ["", "## SHA-256", "", "```text"]
    lines += [f'{item["sha256"]}  {item["filename"]}' for item in records]
    lines += ["```", "", "Unsigned executables may trigger SmartScreen. A hash link alone does not prove a scan exists."]
    (args.output / "security-report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (args.output / "SHA256SUMS.txt").write_text(
        "".join(f'{item["sha256"]}  {item["filename"]}\n' for item in records), encoding="ascii")
    print("Reports written to", args.output)
    return 2 if detection else 0


if __name__ == "__main__":
    raise SystemExit(main())
