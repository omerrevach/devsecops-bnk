#!/bin/bash
# Runner maintenance window helpers (scripts/lab.sh):
#   MODE=stop   stop and disable the runner, so no CI job can run while installers have internet access
#   MODE=check  prove this VM has no internet: directly AND through the proxy (run after the window closes)
# The runner is started again only by `install.sh STAGE=register`, after the check passed.
set -euo pipefail

case "${MODE:?MODE=stop or MODE=check}" in
  stop)
    if systemctl list-unit-files gitlab-runner.service >/dev/null 2>&1; then
      systemctl disable --now gitlab-runner >/dev/null 2>&1 || true
      echo "runner stopped: $(systemctl is-active gitlab-runner || true)"
    else
      echo "runner not installed yet"
    fi
    ;;
  check)
    # shellcheck source=/dev/null
    source /etc/profile.d/lab-proxy.sh
    leaks=""
    for url in https://pypi.org https://github.com https://www.google.com; do
      curl -s -m 10 -o /dev/null "$url" 2>/dev/null && leaks="$leaks proxy:$url"
      curl -s -m 5 --noproxy '*' -o /dev/null "$url" 2>/dev/null && leaks="$leaks direct:$url"
    done
    if [ -n "$leaks" ]; then
      echo "FAIL: internet reachable from $(hostname):$leaks"
      exit 1
    fi
    echo "ok: no internet from $(hostname), directly or through the proxy"
    ;;
esac
rm -rf /root/bootstrap
