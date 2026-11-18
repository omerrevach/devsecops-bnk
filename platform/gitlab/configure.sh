#!/bin/bash
# Configures GitLab: settings, users, groups, project, CI variables, runners. Safe to run again.
#
# Run from the laptop (repo root), after Harbor is configured; make up does this for you:
#   scripts/ssm-run.sh -e PROJECT=bank-lab gitlab platform/gitlab/configure.sh platform/gitlab/configure.rb
#
# Secrets in:  Harbor robot passwords, read from Parameter Store with this VM's IAM role.
# Secrets out: passwords and tokens, written to Parameter Store under /<project>/gitlab/
#              (runner tokens are readable by the matching runner VM only). Nothing is printed.
set -euo pipefail

PROJECT="${PROJECT:-bank-lab}"
FILES="/root/bootstrap"
PASSWORDS="/root/gitlab-passwords"

# shellcheck source=/dev/null
source /etc/profile.d/lab-proxy.sh

get_param() { aws ssm get-parameter --name "/${PROJECT}/$1" --with-decryption --query Parameter.Value --output text; }
put_param() { aws ssm put-parameter --name "/${PROJECT}/gitlab/$1" --type SecureString --key-id "alias/${PROJECT}-secrets" --overwrite --value "$2" > /dev/null; }

# Passwords: generated on the first run, then reused. Root's is applied only on that first run.
if [ ! -f "$PASSWORDS" ]; then
  install -m 600 /dev/null "$PASSWORDS"
  for user in root omeriko security-lead; do
    echo "$user $(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)" >> "$PASSWORDS"
  done
  first_run=1
fi
password() { awk -v u="$1" '$1 == u { print $2 }' "$PASSWORDS"; }

PASSWORD_OMERIKO=$(password omeriko)
PASSWORD_SECURITY_LEAD=$(password security-lead)
HARBOR_CI_TOKEN=$(get_param harbor/robot-ci-build)
HARBOR_RELEASE_TOKEN=$(get_param harbor/robot-ci-release)
export PROJECT PASSWORD_OMERIKO PASSWORD_SECURITY_LEAD HARBOR_CI_TOKEN HARBOR_RELEASE_TOKEN
if [ -n "${first_run:-}" ]; then
  PASSWORD_ROOT=$(password root)
  export PASSWORD_ROOT
fi

# gitlab-rails runs as the "git" user: give it a private folder for the script and the secrets it creates.
work=$(mktemp -d)
trap 'rm -rf "$work" "$FILES"' EXIT
chown git:git "$work" && chmod 700 "$work"
install -o git -g git -m 600 "${FILES}/configure.rb" "$work/configure.rb"
export SECRETS_FILE="$work/secrets"
gitlab-rails runner "$work/configure.rb"

while read -r name value; do
  [ -n "$name" ] && put_param "$name" "$value"
done < "$SECRETS_FILE"
for user in root omeriko security-lead; do
  put_param "password-${user}" "$(password "$user")"
done
echo "secrets: passwords, runner tokens and API tokens stored in Parameter Store /${PROJECT}/gitlab/"
