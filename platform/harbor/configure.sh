#!/bin/bash
# Configures Harbor through its API: projects, mirroring, robot accounts. Safe to run again.
#
# Run from the laptop (repo root); make up does this for you:
#   scripts/ssm-run.sh -e PROJECT=bank-lab harbor platform/harbor/configure.sh platform/harbor/mirror.txt
#
# Robot passwords go straight to Parameter Store (/<project>/harbor/robot-*); only the VMs that
# need one can read it (see terraform/main.tf, parameter_access). The last lines printed are the
# digests of the base images, which make up pins into the Dockerfile and chart.
set -euo pipefail

PROJECT="${PROJECT:-bank-lab}"
MIRROR_LIST="/root/bootstrap/mirror.txt"
CRON="0 0 2 * * *" # daily 02:00 UTC

# shellcheck source=/dev/null
source /etc/profile.d/lab-proxy.sh

# Talk to Harbor on this VM by its real name, so its TLS certificate matches.
# The admin password is read from its root-only file at run time.
ADMIN_LOGIN="admin:$(cat /root/harbor-admin-password)"
api() {
  local method="$1" path="$2" body="${3:-}"
  curl -fsS --user "$ADMIN_LOGIN" --cacert /etc/lab-ca/ca.crt \
    --resolve harbor.lab.internal:443:127.0.0.1 -X "$method" -H 'Content-Type: application/json' \
    ${body:+--data "$body"} "https://harbor.lab.internal/api/v2.0${path}"
}

echo "== Projects"
# mirror: public open-source copies (anonymous pull inside the VPC). staging: every CI build.
# release: signed releases only; Harbor refuses to serve anything in it that has no cosign signature.
for project in mirror staging release; do
  if ! api GET "/projects?name=${project}" | jq -e --arg p "$project" '.[] | select(.name == $p)' >/dev/null; then
    public=$([ "$project" = mirror ] && echo true || echo false)
    api POST /projects "{\"project_name\":\"${project}\",\"metadata\":{\"public\":\"${public}\"}}"
  fi
done
api PUT /projects/release '{"metadata":{"enable_content_trust_cosign":"true","public":"false"}}'

# Release tags of the image and the chart can never be overwritten; cosign's signature tags
# (sha256-<digest>.sig) stay writable.
if [ "$(api GET /projects/release/immutabletagrules | jq length)" = "0" ]; then
  api POST /projects/release/immutabletagrules '{
    "action": "immutable", "template": "immutable_template",
    "tag_selectors": [{"kind": "doublestar", "decoration": "excludes", "pattern": "sha256-*"}],
    "scope_selectors": {"repository": [{"kind": "doublestar", "decoration": "repoMatches",
                                        "pattern": "{bank-app,charts/bank-app}"}]}}'
fi
echo "mirror (public), staging, release (cosign-only, immutable release tags)"

echo "== Source registries (anonymous, reached through the egress proxy)"
registry_id() { api GET "/registries?name=$1" | jq -r --arg n "$1" '.[] | select(.name == $n) | .id'; }
add_registry() {
  [ -n "$(registry_id "$1")" ] || api POST /registries "{\"name\":\"$1\",\"type\":\"$2\",\"url\":\"$3\",\"insecure\":false}"
}
add_registry ghcr github-ghcr https://ghcr.io
# Docker Hub as a plain registry: its "docker-hub" adapter pages through the Hub website API, which
# refuses anonymous clients. The registry API (registry-1.docker.io) allows anonymous pulls.
add_registry dockerhub docker-registry https://registry-1.docker.io
add_registry quay quay https://quay.io
add_registry gcr docker-registry https://gcr.io
add_registry cgr docker-registry https://cgr.dev

echo "== Replication rules: one per line of mirror.txt, pull into mirror/ without renaming"
policy_ids=()
while read -r registry repository tag _digest; do
  case "$registry" in '' | '#'*) continue ;; esac
  name=$(echo "$repository" | tr '/' '-')
  body=$(jq -n --arg name "$name" --argjson reg "$(registry_id "$registry")" --arg repo "$repository" \
    --arg tag "$tag" --arg cron "$CRON" '{
      name: $name, enabled: true, override: true, speed: -1,
      src_registry: {id: $reg}, dest_namespace: "mirror", dest_namespace_replace_count: 0,
      filters: [{type: "name", value: $repo}, {type: "tag", value: $tag}],
      trigger: {type: "scheduled", trigger_settings: {cron: $cron}}}')
  id=$(api GET "/replication/policies?name=${name}" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id')
  if [ -z "$id" ]; then
    api POST /replication/policies "$body"
    id=$(api GET "/replication/policies?name=${name}" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id')
  else
    api PUT "/replication/policies/${id}" "$body"
  fi
  # Run it now as well, unless the image is already there.
  encoded="${repository//\//%252F}" # Harbor wants "/" double-encoded in repository names
  if ! api GET "/projects/mirror/repositories/${encoded}/artifacts?with_tag=true&q=tags%3D${tag}" 2>/dev/null \
    | jq -e 'length > 0' >/dev/null; then
    api POST /replication/executions "{\"policy_id\":${id}}"
    policy_ids+=("$id")
  fi
done < "$MIRROR_LIST"

echo "== Waiting for ${#policy_ids[@]} replication(s)"
for id in "${policy_ids[@]}"; do
  for _ in $(seq 1 120); do
    status=$(api GET "/replication/executions?policy_id=${id}&sort=-start_time&page_size=1" | jq -r '.[0].status')
    case "$status" in
      Succeed | Succeeded) break ;; # Harbor 2.x says "Succeed"
      Failed | Stopped)
        echo "replication policy ${id} ${status}" >&2
        exit 1
        ;;
    esac
    sleep 5
  done
  case "$status" in Succeed | Succeeded) ;; *) echo "replication policy ${id} timed out" >&2; exit 1 ;; esac
done
echo "mirror holds $(api GET '/projects/mirror/repositories?page_size=100' | jq length) repositories"

# Reviewed digests: a pinned tool image must be exactly the reviewed one. If upstream re-published the tag
# (or anything else changed it), setup stops instead of letting CI run unreviewed tooling.
while read -r _ repository tag expected; do
  case "$repository" in '' | '#'*) continue ;; esac
  [ "$expected" = "-" ] && continue
  encoded="${repository//\//%252F}"
  actual=$(api GET "/projects/mirror/repositories/${encoded}/artifacts?with_tag=true&q=tags%3D${tag}" | jq -r '.[0].digest')
  if [ "$actual" != "$expected" ]; then
    echo "DIGEST MISMATCH ${repository}:${tag}: mirror has ${actual}, reviewed ${expected}" >&2
    exit 1
  fi
done < <(grep -v '^#' "$MIRROR_LIST")
echo "every pinned tool image matches its reviewed digest"

echo "== Robot accounts (recreated on every run, secrets go to Parameter Store)"
# Name  Parameter         Permissions
#   ci-build    build jobs:    push + pull staging
#   ci-release  release jobs:  push + pull staging (signatures) and release (image copy, chart)
#   prod-pull   k3s + Flux:    pull release
robot() {
  local name="$1" permissions="$2" existing secret
  existing=$(api GET "/robots?q=name%3D${name}" | jq -r '.[].id')
  for id in $existing; do api DELETE "/robots/${id}"; done
  secret=$(api POST /robots "$(jq -n --arg n "$name" --argjson p "$permissions" \
    '{name: $n, level: "system", duration: -1, disable: false, permissions: $p}')" | jq -r .secret)
  aws ssm put-parameter --name "/${PROJECT}/harbor/robot-${name}" --type SecureString --key-id "alias/${PROJECT}-secrets" --overwrite \
    --value "$secret" > /dev/null
  echo "robot\$${name}"
}
access() { # access <project> <action...>
  local project="$1"
  shift
  jq -n --arg p "$project" --args '{kind: "project", namespace: $p,
    access: [$ARGS.positional[] | {resource: "repository", action: .}]}' "$@"
}
robot ci-build "[$(access staging push pull)]"
robot ci-release "[$(access staging push pull), $(access release push pull)]"
robot prod-pull "[$(access release pull)]"

echo "== Base image digests (pinned into the Dockerfile and chart by make up)"
for image in library/python:3.13-slim distroless/python3-debian13:nonroot chainguard/postgres:latest; do
  repository="${image%%:*}"
  tag="${image##*:}"
  encoded="${repository//\//%252F}" # Harbor wants "/" double-encoded in repository names
  digest=$(api GET "/projects/mirror/repositories/${encoded}/artifacts?with_tag=true&q=tags%3D${tag}" | jq -r '.[0].digest')
  echo "DIGEST ${image} ${digest}"
done
rm -rf /root/bootstrap
