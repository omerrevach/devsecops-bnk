#!/bin/bash
# Opens or closes the proxy's temporary bootstrap allowlist (installers during setup), and refreshes Harbor's
# permanent feed allowlist from Terraform when that file is passed.
#
# Fail-closed: opening also schedules an automatic close after 60 minutes on the proxy itself, so the window
# closes even if the laptop running make up crashes or loses its connection.
#
# make up runs it twice:
#   scripts/ssm-run.sh -e MODE=open  proxy platform/proxy/allowlist.sh .lab/bootstrap-domains.txt .lab/harbor-feed-domains.txt
#   scripts/ssm-run.sh -e MODE=close proxy platform/proxy/allowlist.sh .lab/harbor-feed-domains.txt
set -euo pipefail

LIST="/etc/squid/allow/bootstrap.txt"

CLOSED="bootstrap.disabled.invalid" # Squid needs at least one entry; this name can never resolve

if [ -f /root/bootstrap/harbor-feed-domains.txt ]; then
  install -m 644 /root/bootstrap/harbor-feed-domains.txt /etc/squid/allow/harbor-feeds.txt
fi
systemctl stop bootstrap-autoclose.timer bootstrap-autoclose.service 2>/dev/null || true
systemctl reset-failed bootstrap-autoclose.timer bootstrap-autoclose.service 2>/dev/null || true
case "${MODE:?MODE=open or MODE=close}" in
  open)
    install -m 644 /root/bootstrap/bootstrap-domains.txt "$LIST"
    systemd-run --quiet --unit bootstrap-autoclose --on-active=3600 \
      /bin/sh -c "echo $CLOSED > $LIST && squid -k reconfigure"
    ;;
  close) echo "$CLOSED" > "$LIST" ;;
esac
rm -rf /root/bootstrap

# Refuse a list Squid would reject, instead of leaving the proxy half-configured.
if squid -k parse 2>&1 | grep -E 'ERROR|FATAL'; then
  exit 1
fi
squid -k reconfigure
echo "bootstrap allowlist ${MODE}: $(tr '\n' ' ' < "$LIST")"
