#!/usr/bin/env bash
# Tests scripts/ollama-compat-proxy.py:
#   1) the sanitizer unit tests (python --selftest, no network)
#   2) an integration test: a content:null request forwarded THROUGH the proxy reaches the upstream as
#      content:"", and a non-chat path passes through unchanged. Uses a stub upstream (no real Ollama).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PROXY="$REPO_DIR/scripts/ollama-compat-proxy.py"

# 1) unit tests
if python3 "$PROXY" --selftest >/dev/null 2>&1; then
    LL_PASS=$((LL_PASS + 1))
else
    LL_FAIL=$((LL_FAIL + 1)); echo "  FAIL: ollama-compat-proxy --selftest"
fi

# 2) integration with a stub upstream that records the last received body.
STUB_PORT=45471
PROXY_PORT=45472
work="$(mktemp -d)"
reqfile="$work/last_req.json"
cat > "$work/stub.py" <<'PY'
import http.server, json, os, sys
REQ = os.environ["REQFILE"]
class H(http.server.BaseHTTPRequestHandler):
    def _do(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        with open(REQ, "wb") as fh:
            fh.write(body if body else json.dumps({"path": self.path}).encode())
        out = json.dumps({"ok": True, "path": self.path}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)
    def do_POST(self): self._do()
    def do_GET(self): self._do()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

REQFILE="$reqfile" python3 "$work/stub.py" "$STUB_PORT" >/dev/null 2>&1 &
stub_pid=$!
OLLAMA_PROXY_PORT="$PROXY_PORT" OLLAMA_UPSTREAM="127.0.0.1:$STUB_PORT" python3 "$PROXY" >/dev/null 2>&1 &
proxy_pid=$!
cleanup() { kill "$stub_pid" "$proxy_pid" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

# wait for the proxy to accept connections
up=0
for _ in $(seq 1 25); do
    if curl -fsS -m 1 -o /dev/null "http://127.0.0.1:$PROXY_PORT/api/version" 2>/dev/null; then up=1; break; fi
    sleep 0.2
done
assert_eq "proxy accepts connections" "1" "$up"

# a) content:null through the proxy -> upstream must receive content:""
curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"assistant","content":null},{"role":"user","content":"hi"}]}' \
    "http://127.0.0.1:$PROXY_PORT/v1/chat/completions" >/dev/null 2>&1
got="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d["messages"][0]["content"]; print("EMPTYSTR" if c=="" else repr(c))' "$reqfile" 2>/dev/null)"
assert_eq "null content sanitized to empty string at upstream" "EMPTYSTR" "$got"

# b) string content is left untouched
curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"keep me"}]}' \
    "http://127.0.0.1:$PROXY_PORT/v1/chat/completions" >/dev/null 2>&1
got2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["messages"][0]["content"])' "$reqfile" 2>/dev/null)"
assert_eq "string content untouched through proxy" "keep me" "$got2"

# c) non-chat path passes through unchanged
curl -fsS -m 5 "http://127.0.0.1:$PROXY_PORT/api/tags" >/dev/null 2>&1
gotp="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("path",""))' "$reqfile" 2>/dev/null)"
assert_eq "non-chat path passes through" "/api/tags" "$gotp"

ll_summary "ollama-proxy"
