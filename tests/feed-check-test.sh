#!/bin/sh
# Boundary tests for scripts/feed-check.sh with a fixed clock (NOW_EPOCH): limit 48 h = 172800 s.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
NOW=1800000000 # fixed "now"
failed=0
meta() { printf '{"Version":2,"NextUpdate":"x","UpdatedAt":"%s","DownloadedAt":"x"}\n' "$1" > "$work/m.json"; }
at() { date -u -d "@$((NOW - $1))" +%Y-%m-%dT%H:%M:%S.000000Z; } # timestamp <age seconds> before now
check() { # check <name> <expected: pass|fail> [hours]
  if NOW_EPOCH=$NOW sh scripts/feed-check.sh "$work/m.json" "${3:-48}" >/dev/null 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$2" ]; then echo "ok   $2: $1"; else echo "FAIL expected $2, got $got: $1"; failed=1; fi
}
meta "$(at 0)";           check "fresh (age 0)" pass
meta "$(at 172799)";      check "47:59:59 old" pass
meta "$(at 172800)";      check "exactly 48:00:00 old (limit is inclusive)" pass
meta "$(at 172801)";      check "48:00:01 old" fail
meta "$(at 176340)";      check "48:59 old (was accepted before the fix)" fail
meta "$(at -240)";        check "4 min in the future (clock skew)" pass
meta "$(at -86400)";      check "24 h in the future" fail
meta "not-a-date";        check "malformed timestamp" fail
meta "2026-11-17 06:12:34"; check "timestamp without T/Z" fail
printf '{"Version":2}\n' > "$work/m.json"; check "UpdatedAt missing" fail
printf '{"UpdatedAt":"%s","x":{"UpdatedAt":"%s"}}\n' "$(at 0)" "$(at 0)" > "$work/m.json"; check "two UpdatedAt fields" fail
rm -f "$work/m.json";     check "metadata file missing" fail
meta "$(at 0)";           check "limit not a number" fail "48h"
meta "$(at 0)";           check "limit zero" fail 0
if [ "$failed" != 0 ]; then echo "FAIL: feed-check"; exit 1; fi
echo "PASS: feed-check boundaries"
