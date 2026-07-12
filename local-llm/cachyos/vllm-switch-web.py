#!/usr/bin/env python3
"""vLLM model-switch web service.

A small, dependency-free control endpoint for switching the single-GPU vLLM
server between its model modes over the LAN. Runs as the unprivileged
`vllm-model-control` account; the actual switch is performed by
`cachyos-switch-model`, which holds the narrow passwordless-sudo grant.

Security posture (LAN-only, unauthenticated by design behind ufw):
  * custom handler only — never serves the filesystem
  * mode is matched against a strict whitelist and passed as argv (shell=False)
  * /switch requires POST + application/json (blocks trivial cross-site CSRF)
  * request body is size-capped; sockets time out (slowloris resistance)
  * switches are single-flight (threading lock + flock)
  * every request (accepted, rejected, attack) is logged with the source IP
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
import fcntl
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("VLLM_SWITCH_WEB_PORT", "4090"))
BIND = os.environ.get("VLLM_SWITCH_WEB_BIND", "0.0.0.0")  # IPv4 only — no IPv6 listener
SWITCH_CMD = os.environ.get("VLLM_SWITCH_CMD", "cachyos-switch-model")
VLLM_URL = os.environ.get("VLLM_API_URL", "http://127.0.0.1:8000/v1/models")
IMAGEGEN_URL = os.environ.get("IMAGEGEN_HEALTH_URL", "http://127.0.0.1:8001/health")
LOCKFILE = os.environ.get("VLLM_SWITCH_LOCK", "/run/vllm-switch-web/switch.lock")
MAX_BODY = 4096          # bytes
SOCK_TIMEOUT = 15        # seconds per connection
SWITCH_TIMEOUT = 180     # seconds for a switch to complete

# mode -> systemd unit that is active in that mode (authoritative for status)
MODE_UNIT = {
    "mistral":   "vllm.service",
    "glm":       "vllm@glm.service",
    "coder":     "vllm@coder.service",
    "coder-alt": "vllm@coder-alt.service",
    "image":     "vllm@image.service",
}
VALID_MODE = re.compile(r"^(mistral|glm|coder|coder-alt|image)$")

_switch_lock = threading.Lock()
_last_switch = {"mode": None, "at": None, "by": None, "result": None}


def _log(source_ip, msg):
    ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    sys.stderr.write("[%s] src=%s %s\n" % (ts, source_ip, msg))
    sys.stderr.flush()


def _unit_active(unit):
    try:
        r = subprocess.run(["systemctl", "is-active", unit],
                           capture_output=True, text=True, timeout=5)
        return r.stdout.strip() == "active"
    except Exception:
        return False


def _current_mode():
    for mode, unit in MODE_UNIT.items():
        if _unit_active(unit):
            return mode
    return None


def _served_model():
    try:
        with urllib.request.urlopen(VLLM_URL, timeout=2) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        ids = [m.get("id") for m in data.get("data", [])]
        return ids[0] if ids else None
    except Exception:
        return None


def _imagegen_up():
    try:
        with urllib.request.urlopen(IMAGEGEN_URL, timeout=2) as resp:
            return resp.status == 200
    except Exception:
        return False


def _status():
    mode = _current_mode()
    served = _served_model()
    st = {
        "mode": mode,
        "served_model": served,
        "api_up": served is not None,
        "last_switch": _last_switch,
    }
    if mode == "image":
        st["imagegen_up"] = _imagegen_up()
    return st


def _do_switch(mode, source_ip):
    """Perform a single-flight switch. Returns (http_status, payload)."""
    if not _switch_lock.acquire(blocking=False):
        _log(source_ip, "switch BUSY mode=%s" % mode)
        return 409, {"ok": False, "error": "a switch is already in progress"}
    lock_fh = None
    try:
        try:
            os.makedirs(os.path.dirname(LOCKFILE), exist_ok=True)
        except Exception:
            pass
        try:
            lock_fh = open(LOCKFILE, "w")
            fcntl.flock(lock_fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except Exception:
            _log(source_ip, "switch BUSY (flock) mode=%s" % mode)
            return 409, {"ok": False, "error": "a switch is already in progress"}
        try:
            proc = subprocess.run([SWITCH_CMD, mode], capture_output=True,
                                  text=True, timeout=SWITCH_TIMEOUT)
        except subprocess.TimeoutExpired:
            _last_switch.update(mode=mode, at=time.time(), by=source_ip, result="timeout")
            _log(source_ip, "switch TIMEOUT mode=%s" % mode)
            return 504, {"ok": False, "error": "switch timed out"}
        ok = proc.returncode == 0
        _last_switch.update(mode=mode, at=time.time(), by=source_ip,
                            result="ok" if ok else "failed")
        _log(source_ip, "switch %s mode=%s rc=%d"
             % ("OK" if ok else "FAIL", mode, proc.returncode))
        if ok:
            return 200, {"ok": True, "mode": mode,
                         "message": "switch to '%s' initiated; poll /status for readiness" % mode}
        return 500, {"ok": False, "error": "switch failed",
                     "detail": (proc.stderr or "").strip()[:500]}
    finally:
        if lock_fh is not None:
            try:
                fcntl.flock(lock_fh, fcntl.LOCK_UN)
                lock_fh.close()
            except Exception:
                pass
        _switch_lock.release()


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Squire Server \u2014 Model Switch</title>
<style>
 body{font-family:system-ui,Segoe UI,Roboto,Arial,sans-serif;max-width:640px;margin:2rem auto;padding:0 1rem;color:#1a1a1a}
 h1{font-size:1.3rem} .cur{padding:.6rem .9rem;border-radius:8px;background:#eef;margin:1rem 0}
 button{font-size:1rem;padding:.7rem 1rem;margin:.3rem;border:1px solid #99a;border-radius:8px;background:#fff;cursor:pointer;min-width:9rem}
 button:hover{background:#f0f0ff} button:disabled{opacity:.5;cursor:wait}
 .busy{color:#a60} .ok{color:#070} .err{color:#b00} small{color:#666}
</style></head><body>
<h1>Squire Server \u2014 Model Switch</h1>
<div class="cur" id="cur">Loading current model\u2026</div>
<div id="btns">
 <button data-m="mistral">Mistral-Small-3.2<br><small>authoring (default)</small></button>
 <button data-m="glm">GLM-4.7-Flash<br><small>agentic / reasoning</small></button>
 <button data-m="coder">Qwen3-Coder 30B<br><small>coding</small></button>
 <button data-m="coder-alt">Devstral-2 24B<br><small>coding (alt)</small></button>
 <button data-m="image">Image (HiDream)<br><small>image generation</small></button>
</div>
<p id="msg"><small>One model loads at a time; a switch takes ~20\u201360s and affects everyone on the server.</small></p>
<script>
const NAMES={mistral:"Mistral-Small-3.2",glm:"GLM-4.7-Flash",coder:"Qwen3-Coder 30B","coder-alt":"Devstral-2 24B",image:"Image (HiDream)"};
const cur=document.getElementById('cur'),msg=document.getElementById('msg'),btns=document.getElementById('btns');
async function refresh(){
 try{const r=await fetch('/status');const s=await r.json();
  const nm=s.mode?(NAMES[s.mode]||s.mode):'(none active)';
  cur.textContent='Current: '+nm+(s.api_up?' \u2014 ready':' \u2014 loading\u2026');
  return s;
 }catch(e){cur.textContent='Status unavailable';return null;}
}
async function poll(target){
 for(let i=0;i<40;i++){const s=await refresh();
  if(s&&s.mode===target&&s.api_up){msg.innerHTML='<span class="ok">'+NAMES[target]+' is ready.</span>';setEnabled(true);return;}
  await new Promise(r=>setTimeout(r,3000));}
 msg.innerHTML='<span class="busy">Still loading '+NAMES[target]+'\u2026 check status shortly.</span>';setEnabled(true);
}
function setEnabled(on){for(const b of btns.querySelectorAll('button'))b.disabled=!on;}
btns.addEventListener('click',async e=>{const b=e.target.closest('button');if(!b)return;
 const m=b.dataset.m;setEnabled(false);msg.innerHTML='<span class="busy">Switching to '+NAMES[m]+'\u2026</span>';
 try{const r=await fetch('/switch',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode:m})});
  const j=await r.json();
  if(!r.ok){msg.innerHTML='<span class="err">'+(j.error||'switch failed')+'</span>';setEnabled(true);return;}
  poll(m);
 }catch(err){msg.innerHTML='<span class="err">request failed</span>';setEnabled(true);}
});
refresh();setInterval(()=>{if(!btns.querySelector('button:disabled'))refresh();},10000);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "vllm-switch-web/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # route through our logger
        _log(self.client_address[0], (fmt % args))

    def _send(self, code, body, ctype):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj), "application/json")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif path == "/status":
            self._json(200, _status())
        else:
            self._json(404, {"error": "not found"})

    def _read_body(self):
        """Read/drain the request body (bounded). Returns (raw_bytes, err_response).

        On an oversized or malformed Content-Length the connection is closed so
        undrained bytes can't desync the next keep-alive request.
        """
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            self.close_connection = True
            return None, (400, {"error": "bad Content-Length"})
        if length < 0:
            length = 0
        if length > MAX_BODY:
            self.close_connection = True
            return None, (413, {"error": "oversized body"})
        raw = self.rfile.read(length) if length else b""
        return raw, None

    def do_POST(self):
        raw, err = self._read_body()   # always drain first (keeps keep-alive sane)
        if err is not None:
            self._json(err[0], err[1])
            return
        path = self.path.split("?", 1)[0]
        if path != "/switch":
            self._json(404, {"error": "not found"})
            return
        ctype = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
        if ctype != "application/json":
            self._json(415, {"error": "Content-Type must be application/json"})
            return
        if not raw:
            self._json(400, {"error": "missing body"})
            return
        try:
            data = json.loads(raw.decode("utf-8"))
            mode = data.get("mode", "")
        except Exception:
            self._json(400, {"error": "invalid JSON"})
            return
        if not isinstance(mode, str) or not VALID_MODE.fullmatch(mode):
            _log(self.client_address[0], "REJECT invalid mode=%r" % (mode,))
            self._json(400, {"error": "invalid mode", "allowed": list(MODE_UNIT.keys())})
            return
        code, payload = _do_switch(mode, self.client_address[0])
        self._json(code, payload)

    def _reject(self):
        self._read_body()   # drain any body before responding
        self._json(405, {"error": "method not allowed"})
    do_PUT = do_DELETE = do_PATCH = _reject


def main():
    Handler.timeout = SOCK_TIMEOUT
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    httpd.daemon_threads = True
    _log("-", "vllm-switch-web listening on %s:%d" % (BIND, PORT))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
