#!/bin/sh
# Scan one target three ways, all offline with the DB the job just fetched and checked:
#   <report>.json        every finding of every severity, INCLUDING those an exception suppressed (audit)
#   <report>-junit.xml   the blocking Criticals, shown in merge requests and the Tests tab
#   the gate             exit 1 on any Critical without a valid exception
# Usage: trivy-scan.sh <fs|image> <target> <report-name>
set -eu
KIND="${1:?usage: trivy-scan.sh <fs|image> <target> <report-name>}"
TARGET="${2:?target}"
REPORT="${3:?report name}"

set -- --scanners vuln --offline-scan --skip-db-update --skip-java-db-update \
  --cache-dir "$TRIVY_CACHE_DIR" --ignorefile security/exceptions.yaml
[ "$KIND" = image ] && set -- "$@" --image-src remote

trivy "$KIND" "$@" --show-suppressed --format json --output "${REPORT}.json" "$TARGET"
trivy "$KIND" "$@" --severity CRITICAL --format template --template "@/contrib/junit.tpl" \
  --output "${REPORT}-junit.xml" "$TARGET"
trivy "$KIND" "$@" --severity CRITICAL --exit-code 1 "$TARGET"
