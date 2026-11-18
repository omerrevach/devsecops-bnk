#!/usr/bin/env python3
"""Print the release evidence record (JSON): why this exact release was allowed.

Built in the release-policy job from the artifacts of the release-time checks, then signed with the KMS key
and attached to the released image (cosign attest). Shows the original Critical findings even when an
exception suppressed them, the exception and its approval, the scanner/DB used, and who approved the release.
"""
import json
import os
import subprocess


def load(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f) if path.endswith(".json") else f.read().strip()
    except OSError:
        return default


def findings(report_path):
    """Every Critical finding, including the ones an exception suppressed (trivy --show-suppressed)."""
    report = load(report_path, {}) or {}
    result = {"blocking": [], "accepted_by_exception": []}
    for target in report.get("Results", []):
        for v in target.get("Vulnerabilities") or []:
            if v.get("Severity") == "CRITICAL":
                result["blocking"].append(f"{v['PkgName']}@{v['InstalledVersion']} {v['VulnerabilityID']}")
        for m in target.get("ExperimentalModifiedFindings") or []:
            f = m.get("Finding", {})
            result["accepted_by_exception"].append({
                "finding": f"{f.get('PkgName')}@{f.get('InstalledVersion')} {f.get('VulnerabilityID')}",
                "severity": f.get("Severity"), "status": m.get("Status"), "statement": m.get("Statement"),
                "source": m.get("Source")})
    return result


db_meta = load("trivy-db-metadata.json", {}) or {}
evidence = {
    "release": os.environ["RELEASE_VERSION"],
    "source": {"project": os.environ["CI_PROJECT_PATH"], "commit": os.environ["CI_COMMIT_SHA"],
               "pipeline": os.environ["CI_PIPELINE_URL"]},
    "artifacts": {
        "app_image": f"{os.environ['APP_IMAGE']}@{os.environ['IMAGE_DIGEST']}",
        "database_image": subprocess.run(["sh", "scripts/chart-image.sh", "postgres"], capture_output=True,
                                         text=True, check=True).stdout.strip()},
    "scanner": {"trivy": load("trivy-version.txt", "unknown").splitlines()[0],
                "vulnerability_db_built": db_meta.get("UpdatedAt"),
                "vulnerability_db_downloaded": db_meta.get("DownloadedAt")},
    "release_time_scan": {"app_image": findings("release-scan-app.json"),
                          "database_image": findings("release-scan-db.json")},
    "exceptions_file": load("security/exceptions.yaml"),
    "exception_approval": load("exception-approval.json"),
    "release_approval": load("release-approval.json"),
}
print(json.dumps(evidence, indent=2))
