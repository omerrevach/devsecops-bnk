#!/bin/bash
# Cluster controls, checked on the prod VM (make test-lab runs it over SSM):
#   1. Flux least privilege: the deployer identity can manage the app in bank-app and nothing else;
#      helm-controller itself has no cluster-admin and can impersonate only that identity
#   2. Postgres: the app's role is not a superuser; plaintext network logins are refused
#   3. Pod Security "restricted" rejects a privileged pod in bank-app
set -uo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
failed=0
expect() { # expect <yes|no> <label> <command...>
  local want="$1" label="$2" got
  shift 2
  got=$("$@" 2>/dev/null | tail -n 1)
  [ -z "$got" ] && got=no
  if [ "$got" = "$want" ]; then echo "ok   $want: $label"; else echo "FAIL expected $want, got $got: $label"; failed=1; fi
}
deployer=system:serviceaccount:flux-system:bank-app-deployer
controller=system:serviceaccount:flux-system:helm-controller

echo "== 1. Flux least privilege"
expect yes "deployer: update deployments in bank-app" kubectl auth can-i update deployments -n bank-app --as "$deployer"
expect no "deployer: create ClusterRoleBinding" kubectl auth can-i create clusterrolebindings --as "$deployer"
expect no "deployer: create RoleBinding in bank-app" kubectl auth can-i create rolebindings -n bank-app --as "$deployer"
expect no "deployer: create Role in bank-app" kubectl auth can-i create roles -n bank-app --as "$deployer"
expect no "deployer: create deployments in kube-system" kubectl auth can-i create deployments -n kube-system --as "$deployer"
expect no "deployer: read secrets in flux-system" kubectl auth can-i get secrets -n flux-system --as "$deployer"
expect no "deployer: create namespaces" kubectl auth can-i create namespaces --as "$deployer"
expect no "deployer: create pods/exec in bank-app" kubectl auth can-i create pods/exec -n bank-app --as "$deployer"
expect no "helm-controller: cluster-admin (* on *)" kubectl auth can-i '*' '*' --all-namespaces --as "$controller"
expect no "helm-controller: create deployments itself" kubectl auth can-i create deployments -n bank-app --as "$controller"
expect yes "helm-controller: impersonate the deployer" kubectl auth can-i impersonate serviceaccounts/bank-app-deployer -n flux-system --as "$controller"
expect no "helm-controller: impersonate any other account" kubectl auth can-i impersonate serviceaccounts/default -n kube-system --as "$controller"
expect no "default-ServiceAccount fallback has no rights" kubectl auth can-i create deployments -n bank-app --as system:serviceaccount:flux-system:flux-no-access
if kubectl get clusterrolebinding cluster-reconciler-flux-system >/dev/null 2>&1; then
  echo "FAIL Flux's cluster-admin binding still exists"; failed=1
else
  echo "ok   Flux's default cluster-admin binding is gone"
fi

echo "== 2. Postgres"
pod=bank-app-postgres-0
flags=$(kubectl -n bank-app exec "$pod" -- psql -h /tmp -U postgres -d bank -tAc \
  "SELECT rolsuper::text || ',' || rolcreaterole::text || ',' || rolcreatedb::text FROM pg_roles WHERE rolname = 'bank_app'" 2>/dev/null)
if [ "$flags" = "false,false,false" ]; then echo "ok   bank_app: not superuser, cannot create roles or databases"
else echo "FAIL bank_app role attributes: '$flags'"; failed=1; fi
ssl=$(kubectl -n bank-app exec "$pod" -- psql -h /tmp -U postgres -d bank -tAc \
  "SELECT count(*) FILTER (WHERE ssl) || '/' || count(*) FROM pg_stat_ssl JOIN pg_stat_activity USING (pid) WHERE usename = 'bank_app'" 2>/dev/null)
echo "     app connections over TLS: ${ssl:-none yet}"
# The login is expected to fail; capture its message first (with pipefail, its exit code would hide the match).
plain=$(kubectl -n bank-app exec "$pod" -- sh -c 'PGPASSWORD=x PGSSLMODE=disable psql -h 127.0.0.1 -U bank_app -d bank -c "select 1"' 2>&1)
if echo "$plain" | grep -q 'no pg_hba.conf entry'; then
  echo "ok   plaintext network login refused (pg_hba: hostssl only)"
else
  echo "FAIL plaintext network login was not refused by pg_hba"; failed=1
fi

echo "== 3. Pod Security restricted"
if kubectl -n bank-app run psa-probe --image=harbor.lab.internal/mirror/library/python:3.13-slim --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"p","image":"harbor.lab.internal/mirror/library/python:3.13-slim","securityContext":{"privileged":true}}]}}' \
  --dry-run=server >/dev/null 2>&1; then
  echo "FAIL a privileged pod was admitted"; failed=1
else
  echo "ok   privileged pod rejected by Pod Security"
fi

rm -rf /root/bootstrap
[ "$failed" = 0 ] || { echo "FAIL: cluster controls"; exit 1; }
echo "PASS: cluster controls"
