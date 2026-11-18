#!/usr/bin/env bash
# Run a local script as root on a lab VM through SSM (no SSH), and print its output.
#
# Usage (from the repo root):  scripts/ssm-run.sh [-e NAME=value ...] <vm> <script> [file ...]
#   <vm>      gitlab, harbor, build-runner, release-runner, prod or proxy
#   -e        plain settings exported for the script (never secrets)
#   [file]    copied to /root/bootstrap/<file name> on the VM before the script runs
#
# Never pass secrets as files, settings or arguments: SSM keeps the command text in its history.
# Secrets live in Parameter Store and each VM reads its own with its IAM role.
set -euo pipefail

PROJECT="${PROJECT:-bank-lab}"
CHUNK=24000 # SSM limits the size of one command, so big files are sent in pieces

envs=()
while [ "${1:-}" = "-e" ]; do
  envs+=("$2")
  shift 2
done
if [ $# -lt 2 ]; then
  echo "usage: $0 [-e NAME=value ...] <vm> <script> [file ...]" >&2
  exit 2
fi
vm="$1"
script="$2"
shift 2

# Find the VM by its Name tag, so this works while Terraform is still creating other resources.
instance_id=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${PROJECT}-${vm}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ -z "$instance_id" ] || [ "$instance_id" = "None" ]; then
  echo "no running VM named ${PROJECT}-${vm}" >&2
  exit 1
fi

# Send one shell command list and wait for it. Prints the output; returns non-zero unless it succeeded.
run_command() {
  local commands_file="$1" comment="$2" command_id status
  command_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --comment "$comment" \
    --parameters "$(jq -n --rawfile cmd "$commands_file" '{commands: [$cmd], executionTimeout: ["3600"]}')" \
    --query Command.CommandId --output text)
  while true; do
    status=$(aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
      --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in
      Pending | InProgress | Delayed) sleep 5 ;;
      *) break ;;
    esac
  done
  # SSM returns at most the last 24,000 characters of each stream.
  aws ssm get-command-invocation --command-id "$command_id" --instance-id "$instance_id" \
    --query '[StandardOutputContent, StandardErrorContent]' --output text | sed '/^\s*$/d'
  [ "$status" = "Success" ] || { echo "Status: $status ($vm)" >&2; return 1; }
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 1. Upload: every file as base64, packed into as few SSM commands as the size limit allows.
flush() {
  [ -s "$work/cmd" ] || return 0
  run_command "$work/cmd" "upload for $(basename "$script")" > /dev/null
  : > "$work/cmd"
}
printf 'set -eu\nrm -rf /root/bootstrap\ninstall -d -m 700 /root/bootstrap\n' > "$work/cmd"
for file in "$script" "$@"; do
  name=$(basename "$file")
  [ "$file" = "$script" ] && name="run.sh"
  { base64 < "$file" | tr -d "\n" | fold -w "$CHUNK"; echo; } > "$work/pieces"
  while IFS= read -r piece && [ -n "$piece" ]; do
    [ $(($(wc -c < "$work/cmd") + ${#piece})) -gt $((CHUNK + 2000)) ] && flush
    printf "echo '%s' >> /root/bootstrap/%s.b64\n" "$piece" "$name" >> "$work/cmd"
  done < "$work/pieces"
done
flush

# 2. Run: decode the files, export the settings, run the script under bash.
{
  echo 'set -eu'
  echo 'cd /root/bootstrap'
  # shellcheck disable=SC2016 # expanded on the VM, not here
  echo 'for f in *.b64; do base64 -d "$f" > "${f%.b64}" && rm "$f"; done'
  for setting in "${envs[@]}"; do
    printf 'export %q\n' "$setting"
  done
  echo 'bash /root/bootstrap/run.sh'
} > "$work/cmd"
echo "== ${vm}: $(basename "$script")"
run_command "$work/cmd" "$(basename "$script")"
