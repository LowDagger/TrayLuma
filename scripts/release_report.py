"""Hash-bound release/AV reports; Python standard library only. Never executes input binaries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

API = "https://www.virustotal.com/api/v3"
# Initial cooldown also separates the last call of a previous serialized job.
LAST_REQUEST = time.monotonic()
SAFE_ERROR_CODES = {
    "NotFoundError", "AuthenticationRequiredError", "WrongCredentialsError", "ForbiddenError",
    "QuotaExceededError", "TooManyRequestsError", "TransientError", "BadRequestError",
    "InvalidArgumentError", "UnsupportedMediaTypeError", "NotAvailableYet", "DeadlineExceededError",
    "InternalError", "NetworkError", "InvalidJsonResponse",
}


class ApiError(Exception):
    """Only allowlisted metadata may leave the HTTP layer; never log the key/body."""
    def __init__(self, stage, status=None, code=None):
        self.stage = stage
        self.status = status
        self.code = code if isinstance(code, str) and code in SAFE_ERROR_CODES else None
        super().__init__(f"VirusTotal {stage} failed (HTTP {status or 'network error'}).")

    def report(self):
        result = {"status": "api-error", "stage": self.stage}
        if self.status is not None:
            result["http_status"] = self.status
        if self.code:
            result["api_error_code"] = self.code
        return result


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward x-apikey to a redirect destination, including another host.
        return None


def request(path, key, body=None, content_type=None, *, stage):
    global LAST_REQUEST
    # Public API default: at most four requests per minute, including uploads.
    time.sleep(max(0, 16 - (time.monotonic() - LAST_REQUEST)))
    headers = {"x-apikey": key, "Accept": "application/json", "User-Agent": "TrayLuma-release-report/2"}
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(API + path, data=body, headers=headers, method="POST" if body is not None else "GET")
    LAST_REQUEST = time.monotonic()
    try:
        with urllib.request.build_opener(NoRedirect()).open(req, timeout=90) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        code = None
        try:
            code = json.loads(error.read(16384)).get("error", {}).get("code")
        except (ValueError, AttributeError, TypeError):
            pass
        # Error messages/headers/bodies can echo credentials. Never retain them.
        raise ApiError(stage, error.code, code) from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise ApiError(stage, code="NetworkError") from None
    except ValueError:
        raise ApiError(stage, 200, "InvalidJsonResponse") from None


def usable_stats(stats):
    return (isinstance(stats, dict)
            and all(isinstance(v, int) and not isinstance(v, bool) and v >= 0 for v in stats.values())
            and sum(stats.get(k, 0) for k in ("malicious", "suspicious", "harmless", "undetected")) > 0)


def fresh_file_report(sha, key, submitted_at, analysis_id):
    """An old cached scan must never masquerade as the newly requested scan."""
    result = request("/files/" + sha, key, stage="file-report")
    data = result["data"]
    attrs = data["attributes"]
    if data["id"] != sha:
        raise ValueError("File report hash mismatch")
    date = attrs.get("last_analysis_date", 0)
    if not isinstance(date, int) or date < submitted_at or not usable_stats(attrs.get("last_analysis_stats")):
        return None
    return {"status": "completed", "analysis_id": analysis_id, "result_source": "fresh-file-report",
            "stats": attrs["last_analysis_stats"], "engines": attrs.get("last_analysis_results", {}),
            "analysis_date": date}


def scan(path, key):
    if path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError("Files over 32 MiB require VirusTotal's large-file API.")
    boundary = "TrayLumaBoundary" + os.urandom(16).hex()
    prefix = (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; '
              f'filename="{path.name}"\r\nContent-Type: application/octet-stream\r\n\r\n').encode()
    payload = prefix + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
    sha = hashlib.sha256(path.read_bytes()).hexdigest()
    submitted_at = int(time.time())
    print(f"VirusTotal {path.name}: submitting public binary (POST /files).", flush=True)
    analysis = request("/files", key, payload, "multipart/form-data; boundary=" + boundary, stage="upload")
    if analysis["data"]["type"] != "analysis":
        raise ValueError("Unexpected upload response type")
    analysis_id = analysis["data"]["id"]
    endpoint = "/analyses/" + urllib.parse.quote(analysis_id, safe="")
    last_error = None
    missing = 0
    for attempt in range(20):
        try:
            result = request(endpoint, key, stage="analysis")
        except ApiError as error:
            last_error = error
            print(f"VirusTotal {path.name}: analysis lookup HTTP {error.status or 'network error'} (attempt {attempt + 1}/20).", flush=True)
            # Auth/quota errors must not be treated as propagation delays.
            if error.status not in (None, 404, 500, 502, 503, 504):
                raise
            if error.status == 404:
                missing += 1
            if error.status == 404 and attempt >= 2:
                try:
                    fallback = fresh_file_report(sha, key, submitted_at, analysis_id)
                    if fallback:
                        return fallback
                except ApiError as lookup_error:
                    if lookup_error.status not in (None, 404, 500, 502, 503, 504):
                        raise
            if missing >= 5:
                raise error
            continue
        missing = 0
        attributes = result["data"]["attributes"]
        if attributes["status"] == "completed":
            remote_sha = result.get("meta", {}).get("file_info", {}).get("sha256")
            if remote_sha and remote_sha != sha:
                raise ValueError("VirusTotal response hash did not match the submitted file.")
            if not usable_stats(attributes.get("stats")):
                raise ValueError("Completed analysis had no usable engine verdicts")
            return {"status": "completed", "analysis_id": analysis_id, "result_source": "analysis",
                    "stats": attributes["stats"],
                    "engines": attributes.get("results", {}), "analysis_date": attributes.get("date")}
    result = {"status": "pending", "stage": "analysis", "analysis_id": analysis_id, "reason": "poll-limit-reached"}
    if last_error:
        result["last_error"] = last_error.report()
    return result


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
    key = os.environ.get("VT_API_KEY", "").strip()
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
                except ApiError as error:
                    entry["virustotal"] = error.report()
                except Exception as error:
                    # Do not record request headers, credentials, or response bodies.
                    entry["virustotal"] = {"status": "error", "error_type": type(error).__name__}
                if entry["virustotal"]["status"] == "completed" and not usable_stats(entry["virustotal"].get("stats")):
                    entry["virustotal"] = {"status": "error", "stage": "result-validation", "error_type": "MissingEngineVerdicts"}
        stats = entry["virustotal"].get("stats", {})
        detection |= bool(stats.get("malicious", 0) or stats.get("suspicious", 0))
        detection |= bool(entry["defender"] and entry["defender"]["status"] == "detections-or-scan-error")
        records.append(entry)
        vt = entry["virustotal"]
        print(f'{path.name}: VirusTotal {vt["status"]}; stage={vt.get("stage", "n/a")}; HTTP={vt.get("http_status", "n/a")}', flush=True)
    incomplete = args.upload_virustotal and any(r["virustotal"]["status"] != "completed" for r in records)
    report = {"schema_version": 2, "timestamp_utc": datetime.now(timezone.utc).isoformat(),
               "repository": args.repository, "tag": args.tag, "detections_reported": detection,
              "virustotal_requested": args.upload_virustotal,
              "virustotal_status": "incomplete" if incomplete else "completed" if args.upload_virustotal else "not-requested",
              "notice": "A scan is a point-in-time observation, not a security guarantee. Not-configured/pending is not clean.",
              "files": records}
    (args.output / "release-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    lines = ["# TrayLuma release verification", "", report["notice"], "",
              "Generated: " + report["timestamp_utc"], "",
             "VirusTotal: **" + report["virustotal_status"] + "**", "",
             "| Artifact | Bytes | Defender | VirusTotal |", "|---|---:|---|---|"]
    for item in records:
        vt = item["virustotal"]
        text = vt["status"]
        if vt.get("stage"):
            text += f' ({vt["stage"]}' + (f', HTTP {vt["http_status"]}' if vt.get("http_status") else '') + ')'
        if vt.get("api_error_code"):
            text += ': ' + vt["api_error_code"]
        if vt["status"] == "completed":
            stats = vt["stats"]
            text += f': {stats.get("malicious", 0)} malicious, {stats.get("suspicious", 0)} suspicious'
        local = item["defender"]["status"] if item["defender"] else "not-run"
        lines.append(f'| {item["filename"]} | {item["bytes"]} | {local} | [{text}]({item["virustotal_url"]}) |')
    lines += ["", "## SHA-256", "", "```text"]
    lines += [f'{item["sha256"]}  {item["filename"]}' for item in records]
    lines += ["```", "", "Unsigned executables may trigger SmartScreen. A hash link alone does not prove a scan exists."]
    (args.output / "security-report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as summary:
            summary.write("\n".join(lines) + "\n")
    (args.output / "SHA256SUMS.txt").write_text(
        "".join(f'{item["sha256"]}  {item["filename"]}\n' for item in records), encoding="ascii")
    print("Reports written to", args.output)
    return 2 if detection else 3 if incomplete else 0


if __name__ == "__main__":
    raise SystemExit(main())
