#!/usr/bin/env python3
"""Negative tests for scripts/check_exceptions.py: every invalid exception is rejected, a valid one passes."""
import os
import subprocess
import sys
import tempfile

TODAY = "2026-11-18"
GOOD = {"id": "CVE-2022-21797", "purls": '["pkg:pypi/joblib@1.1.0"]', "expired_at": "2026-12-02",
        "statement": '"ticket=SEC-101; approved-by=security-lead; reason=not reachable; compensating=no HTTP path"'}


def entry(**changes):
    fields = {**GOOD, **changes}
    lines = [f"  - id: {fields['id']}"] if fields.get("id") is not None else ["  -"]
    for key in ("purls", "expired_at", "statement", "extra"):
        if fields.get(key) is not None:
            lines.append(f"    {key}: {fields[key]}")
    return "vulnerabilities:\n" + "\n".join(lines) + "\n"


CASES = [
    ("valid entry", entry(), 0),
    ("empty list", "vulnerabilities: []\n", 0),
    ("PURL without a version (matches every version)", entry(purls='["pkg:pypi/joblib"]'), 1),
    ("PURL with a version range", entry(purls='["pkg:pypi/joblib@>=1.0"]'), 1),
    ("two packages in one entry", entry(purls='["pkg:pypi/joblib@1.1.0", "pkg:pypi/pg8000@1.31.2"]'), 1),
    ("empty ticket/approver/reason", entry(statement='"ticket=; approved-by=; reason="'), 1),
    ("no compensating control", entry(statement='"ticket=SEC-101; approved-by=security-lead; reason=x"'), 1),
    ("malformed ticket", entry(statement='"ticket=TODO; approved-by=a; reason=b; compensating=c"'), 1),
    ("unknown field", entry(extra="yes"), 1),
    ("expiry more than 30 days ahead", entry(expired_at="2027-02-01"), 1),
    ("already expired", entry(expired_at="2026-11-01"), 1),
    ("expiry not a date", entry(expired_at='"soon"'), 1),
    ("purls is text, not a list", entry(purls='"pkg:pypi/joblib@1.1.0"'), 1),
    ("not a CVE/GHSA id", entry(id="JOBLIB-1"), 1),
    ("extra top-level key", "vulnerabilities: []\nmisconfigurations: []\n", 1),
    ("not YAML", "vulnerabilities: [\n", 1),
]

failed = 0
with tempfile.TemporaryDirectory() as tmp:
    for name, content, expected in CASES:
        path = os.path.join(tmp, "exceptions.yaml")
        open(path, "w").write(content)
        code = subprocess.run([sys.executable, "scripts/check_exceptions.py", path, TODAY],
                              capture_output=True).returncode
        ok = (code == 0) == (expected == 0)
        failed += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {'accepted' if code == 0 else 'rejected'}: {name}")
print("PASS: exception validator" if not failed else f"FAIL: {failed} case(s)")
sys.exit(1 if failed else 0)
