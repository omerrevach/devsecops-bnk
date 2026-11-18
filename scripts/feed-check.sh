#!/bin/sh
# Fail CLOSED if the offline Trivy vulnerability DB is missing, unreadable, too old, or dated in the future.
# Usage: feed-check.sh <path/to/metadata.json> [max_age_hours]
#
# The limit is exact: a DB is accepted while its age is at most max_age_hours * 3600 seconds, and rejected
# one second later. A DB dated more than MAX_SKEW_SECONDS in the future means a wrong clock or tampered
# metadata, so it is rejected too. POSIX sh + busybox compatible (runs inside the Trivy image).
# NOW_EPOCH can be set by tests to fix the current time.
set -eu

META="${1:?usage: feed-check.sh <metadata.json> [max_age_hours]}"
MAX_HOURS="${2:-48}"
MAX_SKEW_SECONDS=300

fail() {
  echo "FAIL: $* (fail-closed, see DECISIONS.md #1)."
  exit 1
}

case "$MAX_HOURS" in '' | *[!0-9]*) fail "max age '$MAX_HOURS' is not a whole number of hours" ;; esac
if [ "$MAX_HOURS" -lt 1 ] || [ "$MAX_HOURS" -gt 168 ]; then fail "max age must be 1-168 hours, got $MAX_HOURS"; fi
[ -f "$META" ] || fail "$META not found: vulnerability DB unavailable from the internal mirror"

# Exactly one UpdatedAt field, in RFC 3339 UTC form (2026-11-17T06:12:34.123456Z).
count=$(grep -o '"UpdatedAt" *: *"[^"]*"' "$META" | wc -l)
[ "$count" -eq 1 ] || fail "expected one UpdatedAt field in $META, found $count"
UPDATED=$(sed -n 's/.*"UpdatedAt" *: *"\([^"]*\)".*/\1/p' "$META")
echo "$UPDATED" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$' ||
  fail "UpdatedAt '$UPDATED' is not an RFC 3339 UTC timestamp"

TS=$(echo "$UPDATED" | sed 's/\..*//; s/Z$//; s/T/ /')
UPDATED_EPOCH=$(date -u -d "$TS" +%s 2>/dev/null) || fail "cannot parse UpdatedAt '$UPDATED'"
NOW_EPOCH="${NOW_EPOCH:-$(date -u +%s)}"
AGE=$((NOW_EPOCH - UPDATED_EPOCH))
LIMIT=$((MAX_HOURS * 3600))

echo "Trivy DB built at: $UPDATED (age ${AGE}s, limit ${LIMIT}s = ${MAX_HOURS}h)"
[ "$AGE" -ge "-$MAX_SKEW_SECONDS" ] || fail "vulnerability DB is dated in the future"
[ "$AGE" -le "$LIMIT" ] || fail "vulnerability DB is stale"
echo "OK: vulnerability DB is fresh."
