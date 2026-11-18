#!/usr/bin/env bash
# Database controls, tested locally with Docker: the real database image and config from the chart, and
# the real app code (app/app.py) as the client. No AWS needed.
#   1. valid TLS certificate + hostname: the app connects and SELECT 1 works
#   2. the app's role is not a superuser and cannot create roles or databases
#   3. untrusted CA, wrong hostname, and a plaintext-only server: the app refuses to connect
set -euo pipefail
cd "$(dirname "$0")/.."

PG_IMAGE="${PG_IMAGE:-cgr.dev/chainguard/postgres:latest}"
PY_IMAGE="${PY_IMAGE:-python:3.13-slim}"
HOST=bank-app-postgres.bank-app.svc.cluster.local
NET="dbtest-$$"
work=$(mktemp -d)
cleanup() {
  docker rm -f "pg-tls-$$" "pg-plain-$$" >/dev/null 2>&1 || true
  docker volume rm "pg-secrets-$$" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
fail() {
  echo "FAIL: $*"
  docker logs "pg-tls-$$" 2>&1 | grep -E "initdb.d|ROLE|ERROR|psql|GRANT|REVOKE" | head -n 15 | sed "s/^/  server: /"
  exit 1
}

# Config and init script exactly as the chart renders them.
sh scripts/render-chart.sh "$work/rendered" >/dev/null
python3 - "$work" <<'PY'
import sys, yaml
work = sys.argv[1]
for doc in yaml.safe_load_all(open(f"{work}/rendered/bank-app.yaml")):
    if doc and doc["kind"] == "ConfigMap" and doc["metadata"]["name"].endswith("-postgres-config"):
        for name, body in doc["data"].items():
            # The test mounts the app password at /s/app instead of the pod path.
            open(f"{work}/{name}", "w").write(body.replace("/var/run/secrets/db-app/", "/s/app/"))
PY

# A database CA and server certificate (like bootstrap.sh makes in prod), plus an unrelated CA.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=db-ca -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
  -keyout "$work/ca.key" -out "$work/ca.crt" 2>/dev/null
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=other-ca -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign \
  -keyout "$work/other.key" -out "$work/other-ca.crt" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$HOST" \
  -keyout "$work/tls.key" -out "$work/tls.csr" 2>/dev/null
openssl x509 -req -in "$work/tls.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" -CAcreateserial -days 1 \
  -extfile <(printf "subjectAltName=DNS:%s\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth" "$HOST") -out "$work/tls.crt" 2>/dev/null
mkdir -p "$work/init" && cp "$work/10-app-role.sh" "$work/init/" && chmod 755 "$work" "$work/init" "$work/init/10-app-role.sh"
echo -n "admin-$$-pw" > "$work/admin"
echo -n "app-$$-pw" > "$work/app"

# Postgres insists the key is owned by its user or root: copy the secrets into a volume owned by uid 70.
docker volume create "pg-secrets-$$" >/dev/null
docker run --rm --user 0 --entrypoint sh -v "$work:/src:ro" -v "pg-secrets-$$:/s" "$PG_IMAGE" -c '
  mkdir -p /s/admin /s/app /s/tls /s/config /s/init
  cp /src/admin /s/admin/password; cp /src/app /s/app/password
  cp /src/tls.crt /src/tls.key /s/tls/; cp /src/pg_hba.conf /s/config/; cp /src/10-app-role.sh /s/init/
  chown -R 70:70 /s; chown 0:70 /s/tls/*; chmod 0440 /s/admin/password /s/app/password /s/tls/*  # like a Kubernetes secret' \
  >/dev/null
docker network create "$NET" >/dev/null

# Same arguments as the chart's StatefulSet.
docker run -d --name "pg-tls-$$" --network "$NET" --network-alias "$HOST" --user 70 \
  -v "pg-secrets-$$:/s:ro" -v "$work/init/10-app-role.sh:/var/lib/postgres/initdb/10-app-role.sh:ro" -e POSTGRES_USER=postgres -e POSTGRES_DB=bank \
  -e POSTGRES_PASSWORD_FILE=/s/admin/password -e PGDATA=/tmp/pgdata \
  "$PG_IMAGE" \
  -c ssl=on -c ssl_cert_file=/s/tls/tls.crt -c ssl_key_file=/s/tls/tls.key \
  -c ssl_min_protocol_version=TLSv1.2 -c hba_file=/s/config/pg_hba.conf -c password_encryption=scram-sha-256 \
  >/dev/null
for _ in $(seq 1 60); do
  docker logs "pg-tls-$$" 2>&1 | grep -q 'database system is ready to accept connections' && break
  sleep 1
done

# A server with TLS switched off and a plaintext login allowed: the app must refuse it.
docker run -d --name "pg-plain-$$" --network "$NET" --network-alias plain.db --user 70 \
  -e POSTGRES_USER=bank_app -e POSTGRES_DB=bank -e POSTGRES_PASSWORD="app-$$-pw" -e PGDATA=/tmp/pgdata \
  "$PG_IMAGE" -c ssl=off >/dev/null

client() { # client <DB_HOST> <CA file> <python code>
  docker run --rm --network "$NET" -v "$PWD/app:/app:ro" -v "$work:/w:ro" \
    -e DB_HOST="$1" -e DB_NAME=bank -e DB_USER=bank_app -e DB_PASSWORD_FILE=/w/app -e DB_CA_FILE="$2" \
    -e PYTHONPATH=/app -e PIP_DISABLE_PIP_VERSION_CHECK=1 "$PY_IMAGE" sh -c \
    "pip install -q --require-hashes -r /app/requirements.txt 2>/dev/null && python3 -c '$3'"
}
sleep 3
ip=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "pg-tls-$$")

echo "== 1. valid certificate and hostname"
if client "$HOST" /w/ca.crt 'import app; c = app.connect(); print(c.run("SELECT 1")); c.close()' | grep -q '\[\[1\]\]'; then
  echo "ok: connected over verified TLS"
else
  fail "app could not connect with a valid certificate"
fi

echo "== 2. the app role has no admin rights"
out=$(client "$HOST" /w/ca.crt '
import app
c = app.connect()
print("rolsuper", c.run("SELECT rolsuper, rolcreaterole, rolcreatedb FROM pg_roles WHERE rolname = current_user"))
print("ssl", c.run("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"))
for stmt in ("CREATE ROLE intruder", "CREATE DATABASE other", "ALTER ROLE bank_app SUPERUSER", "CREATE TABLE public.t (x int)"):
    try:
        c.run(stmt); print("ALLOWED", stmt)
    except Exception:
        print("denied", stmt)
')
echo "$out"
echo "$out" | grep -q 'rolsuper \[\[False, False, False\]\]' || fail "app role has admin attributes"
echo "$out" | grep -q 'ssl \[\[True\]\]' || fail "connection is not encrypted"
echo "$out" | grep -q ALLOWED && fail "app role could run an admin statement"

echo "== 3. refused: untrusted CA, wrong hostname, plaintext-only server"
for case in "$HOST|/w/other-ca.crt|untrusted CA" "$ip|/w/ca.crt|wrong hostname (IP address)" "plain.db|/w/ca.crt|plaintext-only server"; do
  IFS='|' read -r host ca label <<<"$case"
  if client "$host" "$ca" 'import app; app.connect()' >/dev/null 2>&1; then
    fail "connected despite: $label"
  fi
  echo "ok: refused ($label)"
done
echo "PASS: database controls"
