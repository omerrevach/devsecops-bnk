#!/usr/bin/env python3
"""Validate security/exceptions.yaml: every CVE exception must be narrow, complete and short-lived.

Rules (any violation fails the pipeline):
  - only the key "vulnerabilities" at the top, a list of entries
  - each entry has exactly: id, purls, expired_at, statement
  - id: a CVE or GHSA identifier
  - purls: exactly ONE package URL with an exact version (pkg:<type>/<name>@<version>). Trivy treats a PURL
    without a version as "every version", so that is rejected.
  - expired_at: a real date, not more than MAX_DAYS ahead. An expired entry is an error too: it no longer
    protects anything, and keeping it hides that the pipeline is blocked again.
  - statement: "key=value; ..." with non-empty ticket, approved-by, reason and compensating
The approver named here is only a description; the proof of approval is GitLab's merge request record,
checked by scripts/check_exception_approval.py.
"""
import datetime
import re
import sys

import yaml

MAX_DAYS = 30
ID_RE = re.compile(r"^(CVE-\d{4}-\d{4,}|GHSA(-[23456789cfghjmpqrvwx]{4}){3})$")
# pkg:<type>/<namespace/>name@<exact version>, no wildcards or ranges, optional ?qualifiers
PURL_RE = re.compile(r"^pkg:[a-z][a-z0-9.+-]*/[^@\s]+@([^@?#\s*<>=,|~^]+)(\?[^#\s]*)?$")
TICKET_RE = re.compile(r"^[A-Z][A-Z0-9]+-\d+$")
ENTRY_KEYS = {"id", "purls", "expired_at", "statement"}
STATEMENT_KEYS = ("ticket", "approved-by", "reason", "compensating")


def parse_statement(text: str) -> dict:
    fields = {}
    for part in text.split(";"):
        if "=" in part:
            key, value = part.split("=", 1)
            fields[key.strip()] = value.strip()
    return fields


def check_entry(entry, today: datetime.date) -> list:
    if not isinstance(entry, dict):
        return ["entry must be a mapping"]
    errors = []
    unknown, missing = set(entry) - ENTRY_KEYS, ENTRY_KEYS - set(entry)
    if unknown:
        errors.append(f"unknown field(s): {', '.join(sorted(unknown))}")
    if missing:
        errors.append(f"missing field(s): {', '.join(sorted(missing))}")
    if not isinstance(entry.get("id"), str) or not ID_RE.match(entry.get("id", "")):
        errors.append("id must be a CVE (CVE-YYYY-NNNN) or GHSA identifier")
    purls = entry.get("purls")
    if not isinstance(purls, list) or len(purls) != 1:
        errors.append("purls must list exactly one package")
    elif not isinstance(purls[0], str) or not PURL_RE.match(purls[0]):
        errors.append(f"purl must be one package with an exact version, e.g. pkg:pypi/joblib@1.1.0 (got {purls[0]!r})")
    expiry = entry.get("expired_at")
    if not isinstance(expiry, datetime.date) or isinstance(expiry, datetime.datetime):
        errors.append("expired_at must be a date (YYYY-MM-DD)")
    elif expiry < today:
        errors.append(f"expired on {expiry}: remove it (upgrade the package) or renew it through a new approval")
    elif expiry > today + datetime.timedelta(days=MAX_DAYS):
        errors.append(f"expired_at may be at most {MAX_DAYS} days from today")
    statement = entry.get("statement")
    if not isinstance(statement, str):
        errors.append("statement must be text")
    else:
        fields = parse_statement(statement)
        for key in STATEMENT_KEYS:
            if not fields.get(key):
                errors.append(f"statement needs a non-empty {key}=...")
        if fields.get("ticket") and not TICKET_RE.match(fields["ticket"]):
            errors.append("ticket must look like ABC-123")
    return errors


def main(path: str, today: datetime.date) -> int:
    try:
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except (OSError, yaml.YAMLError) as e:
        print(f"ERROR: cannot read {path}: {e}")
        return 1
    if not isinstance(data, dict) or set(data) != {"vulnerabilities"} or not isinstance(data["vulnerabilities"], list):
        print("ERROR: the file must contain exactly one key, 'vulnerabilities', holding a list")
        return 1
    errors = []
    seen = set()
    for i, entry in enumerate(data["vulnerabilities"], 1):
        label = f"entry {i} ({entry.get('id', '?') if isinstance(entry, dict) else '?'})"
        errors += [f"{label}: {e}" for e in check_entry(entry, today)]
        if isinstance(entry, dict):
            key = (entry.get("id"), str(entry.get("purls")))
            if key in seen:
                errors.append(f"{label}: duplicate entry")
            seen.add(key)
    for err in errors:
        print(f"ERROR: {err}")
    print(f"{len(data['vulnerabilities'])} exception(s) checked, {len(errors)} error(s).")
    return 1 if errors else 0


if __name__ == "__main__":
    # Optional second argument: "today" as YYYY-MM-DD, so tests are independent of the real date.
    today = datetime.date.fromisoformat(sys.argv[2]) if len(sys.argv) > 2 else datetime.date.today()
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "security/exceptions.yaml", today))
