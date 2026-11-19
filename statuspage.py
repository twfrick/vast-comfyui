#!/usr/bin/env python3
"""
statuspage.py - tiny "is my instance ready?" web page (127.0.0.1:18999)

Started first thing by provision.sh and reached through the Cloudflare Tunnel
(e.g. https://status.yourdomain.com). Refreshes itself every 5 seconds and shows
setup progress, the live setup log, and links to ComfyUI / JupyterLab when ready.
"""
import html
import os
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = 18999
LOG = Path("/workspace/logs/provision.log")
COMFY_URL = os.environ.get("COMFY_URL", "https://comfyui.centarione.org")
LAB_URL = os.environ.get("LAB_URL", "https://jupyter.centarione.org")

STAGES = [  # (marker in provision.log, label)
    ("===== PROVISION started", "Instance started, scripts downloaded"),
    ("===== Cloudflare Tunnel", "Tunnel + this status page"),
    ("===== Installing ComfyUI", "Installing ComfyUI + PyTorch"),
    ("===== Restoring vault", "Restoring models, nodes, workflows from R2"),
    ("===== Jupyter menu", "Menu notebook"),
    ("===== PROVISION COMPLETE", "Ready"),
]


def up(url):
    try:
        urllib.request.urlopen(url, timeout=2)
        return True
    except Exception:  # noqa: BLE001
        return False


def current_run():
    """Text of the latest provisioning run only."""
    if not LOG.exists():
        return ""
    text = LOG.read_text(errors="ignore")
    i = text.rfind("===== PROVISION started")
    return text[i:] if i >= 0 else text


def page():
    run = current_run()
    failed = "PROVISION FAILED" in run
    reached = [m in run for m, _ in STAGES]
    last = max([i for i, r in enumerate(reached) if r], default=-1)
    comfy_ok = up("http://127.0.0.1:18188/system_stats")
    lab_ok = up("http://127.0.0.1:18888/lab")
    done = reached[-1]

    rows = []
    for i, (_, label) in enumerate(STAGES):
        if reached[i] and (i < last or done):
            icon = "&#9989;"                       # done
        elif i == last and failed:
            icon = "&#10060;"                      # failed here
        elif i == last:
            icon = "&#9203;"                       # in progress
        else:
            icon = "&#11036;"                      # not yet
        rows.append(f"<div class='st'>{icon} {label}</div>")

    if failed:
        banner = "<div class='b bad'>Setup FAILED - see the log below</div>"
    elif done and comfy_ok:
        banner = "<div class='b ok'>READY</div>"
    else:
        banner = "<div class='b wait'>Setting up&hellip; this page refreshes every 5 seconds</div>"

    links = (f"<a class='btn {'on' if comfy_ok else 'off'}' href='{COMFY_URL}' target='_blank'>"
             f"ComfyUI {'&#9679; up' if comfy_ok else '&#9675; not yet'}</a>"
             f"<a class='btn {'on' if lab_ok else 'off'}' href='{LAB_URL}' target='_blank'>"
             f"JupyterLab {'&#9679; up' if lab_ok else '&#9675; not yet'}</a>")

    tail = "\n".join(run.splitlines()[-45:]) or "(no log yet)"
    started = ""
    if LOG.exists():
        mins = int((time.time() - LOG.stat().st_mtime) // 60)
        started = f"Log last updated {mins} min ago" if mins else "Log updated just now"

    return f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="5"><title>{'READY' if done else 'Setting up'} - Vast ComfyUI</title>
<style>
body{{background:#14161a;color:#e6e6e6;font:15px system-ui,Segoe UI,sans-serif;margin:24px}}
.b{{font-size:22px;font-weight:600;padding:12px 16px;border-radius:8px;margin-bottom:16px}}
.ok{{background:#1e4620}}.wait{{background:#2a3550}}.bad{{background:#5a1e1e}}
.st{{margin:4px 0}}.btn{{display:inline-block;margin:14px 12px 14px 0;padding:10px 18px;border-radius:8px;
text-decoration:none;font-weight:600}}.on{{background:#2e7d32;color:#fff}}.off{{background:#333;color:#999}}
pre{{background:#0b0c0e;padding:12px;border-radius:8px;white-space:pre-wrap;font-size:12px;max-height:60vh;overflow:auto}}
small{{color:#888}}</style></head><body>
{banner}{''.join(rows)}<div>{links}</div><small>{started}</small>
<pre>{html.escape(tail)}</pre></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        body = page().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # keep quiet
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
