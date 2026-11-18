#!/bin/bash
# Deletes the GitLab project bank/bank (make demo-reset). Run with:
#   scripts/ssm-run.sh gitlab platform/gitlab/reset.sh platform/gitlab/reset.rb
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work" /root/bootstrap' EXIT
chown git:git "$work" && chmod 700 "$work"
install -o git -g git -m 600 /root/bootstrap/reset.rb "$work/reset.rb"
gitlab-rails runner "$work/reset.rb"
