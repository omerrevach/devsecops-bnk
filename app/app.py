"""Internal banking service stub: GET /healthz checks the Postgres connection (over verified TLS)."""
import json
import os
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pg8000.native


def connect() -> pg8000.native.Connection:
    with open(os.environ["DB_PASSWORD_FILE"], encoding="utf-8") as f:
        password = f.read().strip()
    # TLS required: the server's certificate must be signed by the database CA and match DB_HOST.
    tls = ssl.create_default_context(cafile=os.environ["DB_CA_FILE"])
    return pg8000.native.Connection(
        host=os.environ["DB_HOST"], port=int(os.environ.get("DB_PORT", "5432")),
        database=os.environ["DB_NAME"], user=os.environ["DB_USER"],
        password=password, ssl_context=tls, timeout=3)


def database_ok() -> bool:
    try:
        conn = connect()
        try:
            conn.run("SELECT 1")
        finally:
            conn.close()
        return True
    except Exception:  # any failure means "not healthy"
        return False


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/healthz":
            self.send_error(404)
            return
        ok = database_ok()
        body = json.dumps({"status": "ok" if ok else "database unreachable"}).encode()
        self.send_response(200 if ok else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", "8080"))), Handler).serve_forever()
