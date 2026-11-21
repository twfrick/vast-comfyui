#!/usr/bin/env python3
"""
statuspage.py - tiny "is my instance ready?" web page (127.0.0.1:18999)

Started first thing by provision.sh and reached through the Cloudflare Tunnel
(e.g. https://status.yourdomain.com). Updates every 5 seconds (without reloading) and shows
setup progress, the live setup log, and links to ComfyUI / JupyterLab when ready.
"""
import json
import re
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


UNITS = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3, "TiB": 1024**4,
         "KB": 1024, "MB": 1024**2, "GB": 1024**3, "TB": 1024**4}
RCLONE_STATS = re.compile(r"NOTICE:\s+([\d.]+)\s*(\w+) / ([\d.]+)\s*(\w+), (\d+)%, ([\d.]+\s*\w+/s), ETA (\S+)")
STAGE_T = re.compile(r"^===== (.+?) =====.*\[t=(\d+)\]")


def fmt_bytes(n):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{n:.1f} {u}" if u != "B" else f"{int(n)} B"
        n /= 1024


def fmt_secs(sec):
    sec = int(sec)
    return f"{sec // 60}m {sec % 60:02d}s" if sec >= 60 else f"{sec}s"


def restore_progress(run):
    """Latest R2 transfer numbers: which folder, done/total, % , speed, ETA, bytes left."""
    lines = run.splitlines()
    if "===== Restoring vault" not in run or "===== Jupyter menu" in run:
        return ""
    folder = ""
    for ln in lines:
        m = re.search(r"Restoring (\S+)", ln)
        if m and "=====" not in ln:
            folder = m.group(1)
    for ln in reversed(lines):
        m = RCLONE_STATS.search(ln)
        if m:
            d, du, t, tu, pct, speed, eta = m.groups()
            done = float(d) * UNITS.get(du, 1)
            total = float(t) * UNITS.get(tu, 1)
            return (f"<div class='prog'><b>Restoring {folder}</b>: {fmt_bytes(done)} of {fmt_bytes(total)} "
                    f"&nbsp;({pct}%) &nbsp;&middot;&nbsp; <b>{fmt_bytes(max(total - done, 0))} left</b> "
                    f"&nbsp;&middot;&nbsp; {speed.replace('i', '')} &nbsp;&middot;&nbsp; ETA {eta}"
                    f"<div class='bar'><div style='width:{pct}%'></div></div></div>")
    return f"<div class='prog'><b>Restoring {folder}</b>&hellip;</div>" if folder else ""


def stage_times(run):
    """Seconds spent in each stage (by marker label) + total so far / total."""
    marks = []
    for ln in run.splitlines():
        m = STAGE_T.match(ln.strip())
        if m:
            marks.append((m.group(1), int(m.group(2))))
    spent = {}
    for i, (label, t) in enumerate(marks):
        end = marks[i + 1][1] if i + 1 < len(marks) else time.time()
        spent[label] = end - t
    total = (marks[-1][1] if marks and marks[-1][0].startswith("PROVISION COMPLETE") else time.time()) - marks[0][1] \
        if marks else 0
    return spent, total


def speed_line(run):
    m = re.search(r"Host download speed: (\d+) MB/s", run)
    if not m:
        return "<div class='st'>&#9203; Measuring host internet speed&hellip;</div>"
    mb = int(m.group(1))
    if mb < 20:
        return (f"<div class='b bad'>SLOW HOST: {mb} MB/s download &mdash; destroy this instance "
                f"and rent another (sort by Inet Down)</div>")
    return f"<div class='st'>&#128246; Host download speed: <b>{mb} MB/s</b></div>"


WATCH = Path("/workspace/.watcher.json")


def fmt_min(sec):
    """Whole minutes only (the watcher updates every 30 s): '<1 min', '7 min', '1 h 05 min'."""
    m = int(max(sec, 0) // 60)
    if m < 1:
        return "&lt;1 min"
    return f"{m // 60} h {m % 60:02d} min" if m >= 60 else f"{m} min"


def watcher_block():
    """(banner_override or None, html) for the idle watcher + auto-backup."""
    try:
        w = json.loads(WATCH.read_text())
    except Exception:  # noqa: BLE001
        return None, ""
    now = time.time()
    if now - w.get("updated", 0) > 120:
        return None, "<div class='st'>&#9888;&#65039; Idle watcher is not responding</div>"
    act = w.get("action", "stop").upper()
    state = w.get("state", "")
    task, prog, pct = w.get("task", ""), w.get("progress", ""), w.get("pct")
    bar = (f"<div class='bar'><div style='width:{pct}%'></div></div>" if pct is not None else "")
    work = ""
    if task or prog:
        work = (f"<div class='prog'><b>{task or 'Working'}</b>"
                f"{' &nbsp;&middot;&nbsp; ' + str(pct) + '% &nbsp;&middot;&nbsp; ' + prog if prog else ''}{bar}</div>")
    banner = None
    if state == "shutting down":
        banner = f"<div class='b wait'>Idle {fmt_min(w.get('idle', 0))} &mdash; backing up, then {act}&hellip;</div>"
    elif state == "stopping":
        banner = f"<div class='b ok'>Backup done &mdash; Vast is {'stopping' if act == 'STOP' else 'destroying'} this instance</div>"

    parts = []
    if state == "backing up":
        parts.append("<b>Auto-backup running</b>")
    elif state in ("shutting down", "stopping"):
        pass
    elif act == "OFF":
        parts.append("Auto-shutdown off")
    elif w.get("reason"):
        parts.append(f"Active &mdash; {w['reason']}")
    else:
        parts.append(f"<b>Idle {fmt_min(w.get('idle', 0))}</b> &mdash; {act} in "
                     f"{fmt_min(w.get('idle_limit', 0) - w.get('idle', 0))}")
    if w.get("backup_every") and state not in ("backing up", "shutting down", "stopping"):
        parts.append(f"next auto-backup in {fmt_min(max(w.get('next_backup', 0) - now, 0))}")
    if w.get("last_backup_ok") is not None:
        when = time.strftime("%H:%M", time.localtime(w.get("last_backup", 0)))
        parts.append(f"last backup {when} {'&#9989;' if w['last_backup_ok'] else '&#10060;'}")
    line = "<div class='st'>&#128337; " + " &nbsp;&middot;&nbsp; ".join(parts) + "</div>" if parts else ""
    note = f"<div class='b bad' style='font-size:15px'>{w['note']}</div>" if w.get("note") else ""
    return banner, note + line + work


VAULT_LOG = Path("/workspace/logs/vault.log")


def log_text(run):
    """Setup log normally; the backup log while the watcher is backing up / shutting down."""
    try:
        w = json.loads(WATCH.read_text())
        if w.get("state") in ("backing up", "shutting down", "stopping") and VAULT_LOG.exists():
            lines = VAULT_LOG.read_text(errors="ignore").splitlines()
            return "--- backup log (vault.log) ---\n" + "\n".join(lines[-200:])
    except Exception:  # noqa: BLE001
        pass
    return "\n".join(run.splitlines()[-200:]) or "(no log yet)"


def status():
    """Current state as a dict (sent to the page as JSON every few seconds)."""
    run = current_run()
    failed = "PROVISION FAILED" in run
    reached = [m in run for m, _ in STAGES]
    last = max([i for i, r in enumerate(reached) if r], default=-1)
    comfy_ok = up("http://127.0.0.1:18188/system_stats")
    lab_ok = up("http://127.0.0.1:18888/lab")
    done = reached[-1]

    spent, total = stage_times(run)
    rows = []
    for i, (marker, label) in enumerate(STAGES):
        key = next((k for k in spent if ("===== " + k).startswith(marker)), None)
        took = f" <small>({fmt_secs(spent[key])})</small>" if key and not marker.endswith("COMPLETE") else ""
        if reached[i] and (i < last or done):
            icon = "&#9989;"
        elif i == last and failed:
            icon = "&#10060;"
        elif i == last:
            icon = "&#9203;"
        else:
            icon = "&#11036;"
        rows.append(f"<div class='st'>{icon} {label}{took}</div>")

    w_banner, w_html = watcher_block() if done else (None, "")
    if "RESTORE FAILED" in run:
        banner, cls = ("RESTORE FAILED &mdash; your R2 vault was NOT changed. Destroy this instance and "
                       "rent another host (or run <code>vault restore</code> in the terminal)."), "bad"
    elif failed:
        banner, cls = "Setup FAILED - see the log below", "bad"
    elif done and comfy_ok:
        banner, cls = f"READY &nbsp;<small>setup took {fmt_secs(total)}</small>", "ok"
    else:
        banner, cls = f"Setting up&hellip; &nbsp;<small>{fmt_secs(total)} so far</small>", "wait"

    links = (f"<a class='btn {'on' if comfy_ok else 'off'}' href='{COMFY_URL}' target='_blank'>"
             f"ComfyUI {'&#9679; up' if comfy_ok else '&#9675; not yet'}</a>"
             f"<a class='btn {'on' if lab_ok else 'off'}' href='{LAB_URL}' target='_blank'>"
             f"JupyterLab {'&#9679; up' if lab_ok else '&#9675; not yet'}</a>")
    updated = ""
    if LOG.exists():
        mins = int((time.time() - LOG.stat().st_mtime) // 60)
        updated = f"Log last updated {mins} min ago" if mins else "Log updated just now"
    return {
        "title": "READY" if (done and comfy_ok) else ("FAILED" if failed else "Setting up"),
        "banner": (f"<div class='b {cls}'>{banner}</div>" if "RESTORE FAILED" in run
                   else w_banner or f"<div class='b {cls}'>{banner}</div>"),
        "steps": speed_line(run) + "".join(rows) + restore_progress(run) + w_html,
        "links": links, "updated": updated,
        "log": log_text(run),
    }


SHELL = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>Vast ComfyUI - setup</title>
<style>
body{background:#14161a;color:#e6e6e6;font:15px system-ui,Segoe UI,sans-serif;margin:24px}
.b{font-size:22px;font-weight:600;padding:12px 16px;border-radius:8px;margin-bottom:16px}
.ok{background:#1e4620}.wait{background:#2a3550}.bad{background:#5a1e1e}
.st{margin:4px 0}.btn{display:inline-block;margin:14px 12px 14px 0;padding:10px 18px;border-radius:8px;
text-decoration:none;font-weight:600}.on{background:#2e7d32;color:#fff}.off{background:#333;color:#999}
#log{background:#0b0c0e;padding:12px;border-radius:8px;white-space:pre-wrap;font:12px monospace;
height:55vh;overflow-y:scroll;margin:0;scrollbar-width:auto;scrollbar-color:#888 #222}
html{scrollbar-width:auto;scrollbar-color:#888 #222}
.prog{margin:10px 0;padding:10px;background:#1d2128;border-radius:8px}
.bar{height:10px;background:#333;border-radius:5px;margin-top:6px;overflow:hidden}
.bar div{height:100%;background:#4caf50}
button{background:#333;color:#ddd;border:0;border-radius:6px;padding:4px 10px;margin-left:8px;cursor:pointer}
small{color:#888}label{color:#aaa;font-size:13px;margin-left:12px}</style></head><body>
<div id="banner"></div><div id="steps"></div><div id="links"></div>
<small id="updated"></small>
<label><input type="checkbox" id="follow" checked> follow log</label>
<label><input type="checkbox" id="pause"> pause updates</label>
<button onclick="log.scrollTop=0">&#9650; top</button><button onclick="log.scrollTop=log.scrollHeight">&#9660; bottom</button>
<pre id="log">loading...</pre>
<script>
const $ = id => document.getElementById(id);
let lastOk = Date.now(), lastBanner = '';
async function tick() {
  if ($('pause').checked) return;
  try {
    const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 8000);
    const resp = await fetch('data', {cache: 'no-store', signal: ctl.signal});
    clearTimeout(t);
    const d = await resp.json();          // a stopped instance returns Cloudflare's error page -> throws
    lastOk = Date.now();
    for (const k of ['steps', 'links']) $(k).innerHTML = d[k];
    $('banner').innerHTML = lastBanner = d.banner;
    $('updated').textContent = d.updated + ' · page updated ' + new Date().toLocaleTimeString();
    document.title = d.title + ' - Vast ComfyUI';
    const log = $('log'), atBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 30;
    if (log.textContent !== d.log) {
      const keep = log.scrollTop;
      log.textContent = d.log;
      log.scrollTop = ($('follow').checked && atBottom) || log.dataset.first !== '1' ? log.scrollHeight : keep;
      log.dataset.first = '1';
    }
  } catch (e) {
    const secs = Math.round((Date.now() - lastOk) / 1000);
    if (secs >= 15) {
      $('banner').innerHTML = "<div class='b bad'>Can't reach the instance (no answer for " + secs +
        " s) &mdash; it has probably stopped or been destroyed. Check Vast's Instances page.</div>";
      document.title = 'UNREACHABLE - Vast ComfyUI';
    }
    $('updated').textContent = 'connection lost - retrying... (last good update ' + new Date(lastOk).toLocaleTimeString() + ')';
  }
}
tick(); setInterval(tick, 5000);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path.rstrip("/").endswith("data"):
            body, ctype = json.dumps(status()).encode(), "application/json"
        else:
            body, ctype = SHELL.encode(), "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # keep quiet
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
