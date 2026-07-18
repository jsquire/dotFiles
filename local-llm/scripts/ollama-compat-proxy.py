#!/usr/bin/env python3
"""
ollama-compat-proxy.py - a tiny local reverse proxy that fixes an Ollama OpenAI-compat
strictness bug.

Ollama's /v1/chat/completions (and /api/chat) REJECTS any message with content:null
("400 invalid message content type: <nil>"), even though OpenAI's real API accepts it.
Reasoning models (Ornith / GLM / Nemotron) produce turns whose final text is empty (all
output went to the separate `reasoning` field); the client (copilot / crush) then replays
that turn with content:null and Ollama 400s. The bad turn is persisted, so every later
request AND every session restore fails permanently. Upstream: pydantic-ai#5206. The
documented fix is to coerce null content -> "".

This proxy sits between the client and Ollama and does exactly that: for POST
/v1/chat/completions and /api/chat it rewrites every message `content:null` -> "" and
forwards. Everything else passes through byte-for-byte, responses stream unbuffered, and
anything unexpected is forwarded unchanged (fail-open) so it can never break a request.

  listen : 127.0.0.1:${OLLAMA_PROXY_PORT:-11435}
  upstream: ${OLLAMA_UPSTREAM:-127.0.0.1:11434}

  python ollama-compat-proxy.py            # serve
  python ollama-compat-proxy.py --selftest # unit-test the sanitizer (no network)
"""
import http.client
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHAT_PATHS = ("/v1/chat/completions", "/api/chat")
_HOP_BY_HOP = ("connection", "keep-alive", "proxy-connection", "transfer-encoding",
               "content-length", "te", "trailer", "upgrade")


def sanitize_body(raw):
    """Coerce any message `content:null` -> "" in a chat request body.

    Fail-open: return the original bytes unchanged unless the body is valid JSON with a
    `messages` list that actually contains a null content (so untouched requests are
    forwarded byte-for-byte)."""
    try:
        obj = json.loads(raw)
    except Exception:
        return raw
    if not isinstance(obj, dict):
        return raw
    msgs = obj.get("messages")
    if not isinstance(msgs, list):
        return raw
    changed = False
    for m in msgs:
        if isinstance(m, dict) and m.get("content", "") is None:
            m["content"] = ""
            changed = True
    return json.dumps(obj).encode("utf-8") if changed else raw


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _upstream(self):
        up = os.environ.get("OLLAMA_UPSTREAM", "127.0.0.1:11434")
        host, _, port = up.partition(":")
        return (host or "127.0.0.1"), int(port or "11434")

    def _proxy(self, method):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        body = self.rfile.read(length) if length > 0 else b""

        # Only chat request bodies are mutated; everything else is transparent.
        if method == "POST" and self.path.split("?", 1)[0] in CHAT_PATHS:
            body = sanitize_body(body)

        host, port = self._upstream()
        headers = {}
        for k, v in self.headers.items():
            if k.lower() in _HOP_BY_HOP or k.lower() == "host":
                continue
            headers[k] = v
        headers["Host"] = "%s:%d" % (host, port)
        if body:
            headers["Content-Length"] = str(len(body))

        try:
            conn = http.client.HTTPConnection(host, port, timeout=900)
            conn.request(method, self.path, body=body, headers=headers)
            resp = conn.getresponse()
        except Exception as exc:
            self.send_error(502, "upstream error: %s" % exc)
            return

        # Relay status + headers, dropping framing; we delimit the body by closing the
        # connection, which also lets streaming (SSE) pass through with unknown length.
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in _HOP_BY_HOP:
                continue
            self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        # read1() returns bytes as soon as they arrive (does not block to fill the buffer),
        # so streamed tokens are relayed live rather than in large batches.
        try:
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionError):
            pass
        finally:
            try:
                conn.close()
            except Exception:
                pass
        self.close_connection = True

    def do_GET(self):
        self._proxy("GET")

    def do_POST(self):
        self._proxy("POST")

    def do_PUT(self):
        self._proxy("PUT")

    def do_DELETE(self):
        self._proxy("DELETE")

    def do_HEAD(self):
        self._proxy("HEAD")

    def log_message(self, *args):
        pass  # quiet; upstream Ollama already logs


def _selftest():
    p = f = 0

    def check(name, cond):
        nonlocal p, f
        if cond:
            p += 1
        else:
            f += 1
            print("  FAIL:", name)

    out = json.loads(sanitize_body(b'{"messages":[{"role":"assistant","content":null}]}'))
    check("null content -> empty string", out["messages"][0]["content"] == "")

    out = json.loads(sanitize_body(
        b'{"messages":[{"role":"assistant","content":null,"tool_calls":[{"id":"c1"}]}]}'))
    check("null + tool_calls -> empty (tool_calls kept)",
          out["messages"][0]["content"] == "" and out["messages"][0].get("tool_calls"))

    raw = b'{"messages":[{"role":"user","content":"hi"}],"temperature":0.6,"stream":true}'
    check("string content is byte-for-byte untouched", sanitize_body(raw) == raw)

    out = json.loads(sanitize_body(
        b'{"model":"m","stream":true,"messages":[{"role":"assistant","content":null}]}'))
    check("other fields preserved", out["model"] == "m" and out["stream"] is True)

    raw = b'{"messages":[{"role":"user"}]}'
    check("missing content key untouched", sanitize_body(raw) == raw)

    check("non-JSON body passes through", sanitize_body(b"not json at all") == b"not json at all")
    check("no messages list passes through", sanitize_body(b'{"prompt":"x"}') == b'{"prompt":"x"}')
    check("non-dict JSON passes through", sanitize_body(b'[1,2,3]') == b'[1,2,3]')

    print("ollama-proxy selftest: %d passed, %d failed" % (p, f))
    return 1 if f else 0


def main():
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    port = int(os.environ.get("OLLAMA_PROXY_PORT", "11435"))
    up = os.environ.get("OLLAMA_UPSTREAM", "127.0.0.1:11434")
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    sys.stderr.write('[ollama-compat-proxy] 127.0.0.1:%d -> %s (coerces content:null -> "")\n' % (port, up))
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
