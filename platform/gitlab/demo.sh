#!/bin/bash
# The assignment's story, end to end, through the GitLab API (make demo / make up run it):
#   1. the first pipeline on main is blocked by the Critical CVE in joblib (sca job fails)
#   2. the developer (omeriko) opens a merge request with a 14-day, ticketed risk acceptance
#   3. its pipeline goes green; Security (security-lead) approves and merges
#   4. the main pipeline signs the image; Security approves the release (manual "promote" job)
#   5. the signed chart lands in Harbor's release project, where Flux in prod picks it up
# Safe to run again: finished steps are skipped.
#
# This is a DEMONSTRATION: the script holds both users' tokens, so it is not evidence of independent review.
# The controls themselves are enforced by GitLab (developers cannot merge to main or run release jobs) and by
# the exception-approvals job, which checks GitLab's approval record.
set -euo pipefail

PROJECT="${PROJECT:-bank-lab}"
GITLAB="https://gitlab.lab.internal/api/v4"
BRANCH="sec/accept-CVE-2022-21797"

# shellcheck source=/dev/null
source /etc/profile.d/lab-proxy.sh

token() { aws ssm get-parameter --name "/${PROJECT}/gitlab/token-$1" --with-decryption --query Parameter.Value --output text; }
DEV_TOKEN=$(token omeriko)
SEC_TOKEN=$(token security-lead)
api() { # api <token> <method> <path> [curl args...]
  local tok="$1" method="$2" path="$3"
  shift 3
  # GitLab on this VM, by its real name (TLS matches); the load balancer is for other machines.
  curl -fsS --cacert /etc/lab-ca/ca.crt --resolve gitlab.lab.internal:443:127.0.0.1 \
    -H "PRIVATE-TOKEN: ${tok}" -X "$method" "$@" "${GITLAB}${path}"
}
P="/projects/bank%2Fbank"

# A failed pipeline is retried once (e.g. after fixing a runner and running make demo again);
# a real failure fails twice and stops the demo.
wait_or_retry() {
  local id="$1" status
  status=$(wait_pipeline "$id")
  if [ "$status" = failed ] || [ "$status" = canceled ]; then
    echo "pipeline ${id} ${status}; retrying its failed jobs once" >&2
    api "$DEV_TOKEN" POST "$P/pipelines/${id}/retry" >/dev/null
    sleep 5
    status=$(wait_pipeline "$id")
  fi
  echo "$status"
}

# Wait for a pipeline to stop running; print its jobs; echo its status.
wait_pipeline() {
  local id="$1" status
  for _ in $(seq 1 180); do
    status=$(api "$DEV_TOKEN" GET "$P/pipelines/${id}" | jq -r .status)
    case "$status" in created | waiting_for_resource | preparing | pending | running) sleep 10 ;; *) break ;; esac
  done
  api "$DEV_TOKEN" GET "$P/pipelines/${id}/jobs?per_page=50" \
    | jq -r 'sort_by(.id)[] | "     \(.status | .[0:7])\t\(.name)"' >&2
  echo "$status"
}
latest_pipeline() { # latest_pipeline <query> -> id (waits for it to appear)
  local id
  for _ in $(seq 1 60); do
    id=$(api "$DEV_TOKEN" GET "$P/pipelines?$1&order_by=id&sort=desc&per_page=1" | jq -r '.[0].id // empty')
    [ -n "$id" ] && { echo "$id"; return; }
    sleep 5
  done
  echo "no pipeline found for $1" >&2
  return 1
}

echo "== 1. First pipeline on main: the gate must block the Critical CVE"
first=$(api "$DEV_TOKEN" GET "$P/pipelines?ref=main&order_by=id&sort=asc&per_page=1" | jq -r '.[0].id // empty')
if [ -z "$first" ]; then
  # Normally the import push starts it; start it here if it is missing (only Maintainers may run on main).
  first=$(api "$SEC_TOKEN" POST "$P/pipeline?ref=main" | jq -r .id)
fi
status=$(wait_pipeline "$first")
sca=$(api "$DEV_TOKEN" GET "$P/pipelines/${first}/jobs?per_page=50" | jq -r '.[] | select(.name == "sca") | .status')
if [ "$sca" != failed ]; then
  echo "expected the sca job to fail on CVE-2022-21797, got: ${sca}" >&2
  exit 1
fi
echo "pipeline ${first}: ${status}; sca blocked the build (CVE-2022-21797 in joblib 1.1.0)"

echo "== 2. Developer opens a merge request with a time-boxed risk acceptance"
mr=$(api "$DEV_TOKEN" GET "$P/merge_requests?source_branch=$(printf %s "$BRANCH" | jq -sRr @uri)" | jq -r '.[0].iid // empty')
if [ -z "$mr" ]; then
  expiry=$(date -u -d '+14 days' +%F)
  content=$(cat <<EOF
# Approved risk-acceptance exceptions, in Trivy's native ignore-file format.
# Rules: scripts/check_exceptions.py (exceptions-lint job). Changes need Security approval (CODEOWNERS).
vulnerabilities:
  - id: CVE-2022-21797
    purls:
      - "pkg:pypi/joblib@1.1.0"
    expired_at: ${expiry}
    statement: "ticket=SEC-101; approved-by=security-lead; reason=Parallel(pre_dispatch) is never called with user input; compensating=no joblib code path is reachable from HTTP"
EOF
)
  api "$DEV_TOKEN" POST "$P/repository/commits" -H 'Content-Type: application/json' --data "$(jq -n \
    --arg b "$BRANCH" --arg c "$content" --arg e "$expiry" '{
      branch: $b, start_branch: "main",
      commit_message: "Risk acceptance: CVE-2022-21797 (joblib) until \($e) [SEC-101]",
      actions: [{action: "update", file_path: "security/exceptions.yaml", content: $c}]}')" >/dev/null
  mr=$(api "$DEV_TOKEN" POST "$P/merge_requests" -H 'Content-Type: application/json' --data "$(jq -n \
    --arg b "$BRANCH" '{source_branch: $b, target_branch: "main", remove_source_branch: true,
      title: "Risk acceptance: CVE-2022-21797 (joblib) [SEC-101]",
      description: "Emergency acceptance for 14 days. Exploit path not reachable: see statement in security/exceptions.yaml."}')" | jq -r .iid)
fi
echo "merge request !${mr}"

state=$(api "$DEV_TOKEN" GET "$P/merge_requests/${mr}" | jq -r .state)
if [ "$state" != merged ]; then
  echo "== 3. Merge request pipeline (build zone, no signing, no release credentials)"
  sleep 5
  mr_pipeline=$(api "$DEV_TOKEN" GET "$P/merge_requests/${mr}/pipelines" | jq -r '.[0].id')
  status=$(wait_or_retry "$mr_pipeline")
  [ "$status" = success ] || { echo "merge request pipeline ${mr_pipeline}: ${status}" >&2; exit 1; }
  echo "pipeline ${mr_pipeline}: success"

  echo "== Security reviews, approves and merges (developers cannot merge to main)"
  api "$SEC_TOKEN" POST "$P/merge_requests/${mr}/approve" >/dev/null
  api "$SEC_TOKEN" PUT "$P/merge_requests/${mr}/merge" >/dev/null
  echo "merged by security-lead"
fi

echo "== 4. Main pipeline: sign the image, then Security approves the release"
merge_sha=$(api "$DEV_TOKEN" GET "$P/merge_requests/${mr}" | jq -r '.merge_commit_sha // .sha')
main_pipeline=$(latest_pipeline "ref=main&sha=${merge_sha}")
for _ in $(seq 1 180); do
  promote=$(api "$DEV_TOKEN" GET "$P/pipelines/${main_pipeline}/jobs?per_page=50" | jq -r '.[] | select(.name == "promote")')
  promote_status=$(echo "$promote" | jq -r .status)
  case "$promote_status" in
    manual)
      api "$SEC_TOKEN" POST "$P/jobs/$(echo "$promote" | jq -r .id)/play" >/dev/null
      echo "release approved by security-lead (promote job started)"
      break ;;
    success | running | pending) break ;;
    failed | canceled | skipped)
      wait_pipeline "$main_pipeline" >/dev/null
      if [ -n "${retried:-}" ]; then
        echo "main pipeline ${main_pipeline} stopped before the release step" >&2
        exit 1
      fi
      echo "main pipeline ${main_pipeline} stopped before the release step; retrying once" >&2
      api "$SEC_TOKEN" POST "$P/pipelines/${main_pipeline}/retry" >/dev/null # only Maintainers run on main
      retried=1 ;;
  esac
  sleep 10
done

status=$(wait_pipeline "$main_pipeline")
[ "$status" = success ] || { echo "main pipeline ${main_pipeline}: ${status}" >&2; exit 1; }
version=$(api "$DEV_TOKEN" GET "$P/pipelines/${main_pipeline}" | jq -r '"1.0.\(.id)"')
echo "== 5. Release ${version} is signed and in Harbor (release/charts/bank-app); Flux installs it next"
build_job=$(api "$DEV_TOKEN" GET "$P/pipelines/${main_pipeline}/jobs?per_page=50" | jq -r '.[] | select(.name == "build") | .id')
echo "RELEASE ${version}"
echo "DIGEST $(api "$DEV_TOKEN" GET "$P/jobs/${build_job}/artifacts/image.digest")"
