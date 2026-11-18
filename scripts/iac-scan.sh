#!/bin/sh
# IaC gate: run Checkov for ONE framework on the given paths, and fail unless the scan really covered them.
#
# Usage: iac-scan.sh <terraform|kubernetes> <report-name> <path> [path ...]
#
# Fails when: any check fails, any file could not be parsed, or nothing was scanned at all
# (a mis-scoped scan that "passes" because it saw no resources is exactly what this guards against).
# Skips come only from .checkov.yaml and inline annotations next to the resource, each with a reason.
set -eu

FRAMEWORK="${1:?usage: iac-scan.sh <terraform|kubernetes> <report-name> <path> [path ...]}"
REPORT="${2:?report name}"
shift 2
[ $# -gt 0 ] || { echo "no paths given" >&2; exit 2; }

dirs=""
for path in "$@"; do
  [ -d "$path" ] || { echo "FAIL: $path does not exist" >&2; exit 1; }
  dirs="$dirs -d $path"
done

# One run, three outputs: readable log, JSON for the coverage check, JUnit for GitLab's Tests tab.
# shellcheck disable=SC2086 # one -d per path
checkov --config-file .checkov.yaml --framework "$FRAMEWORK" $dirs --compact \
  --output cli --output json --output junitxml \
  --output-file-path "console,${REPORT}.json,${REPORT}-junit.xml" --soft-fail

python3 - "${REPORT}.json" "$FRAMEWORK" <<'PY'
import json, sys
path, framework = sys.argv[1], sys.argv[2]
data = json.load(open(path))
reports = [r for r in (data if isinstance(data, list) else [data]) if r.get("check_type") == framework]
if not reports:
    sys.exit(f"FAIL: Checkov produced no {framework} results (nothing scanned)")
s = reports[0]["summary"]
print(f"{framework}: {s['resource_count']} resources, {s['passed']} passed, {s['failed']} failed, "
      f"{s['skipped']} skipped, {s['parsing_errors']} parsing errors")
if s["resource_count"] == 0:
    sys.exit(f"FAIL: zero {framework} resources scanned")
if s["parsing_errors"]:
    sys.exit("FAIL: some files could not be parsed")
if s["failed"]:
    sys.exit("FAIL: insecure configuration (see the checks above)")
PY
