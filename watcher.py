#!/usr/bin/env python3
"""
watcher.py - idle watcher + automatic backups (runs as a supervisor service)

Every 30 seconds it checks whether the instance is being used:
  * ComfyUI has jobs running or queued
  * the GPU is busy
  * a download / backup / restore from the menu is running (/workspace/.busy, vault lock)
  * JupyterLab kernels or terminals were used recently
If none of that happens for IDLE_MINUTES, it runs `vault shutdown <IDLE_ACTION>`
(backup first; the instance is only stopped/destroyed if the backup succeeds).

Every AUTOBACKUP_MINUTES it runs `vault backup` (only new/changed files are sent).

Settings (Vast account env vars, all optional):
  IDLE_MINUTES        default 30
  IDLE_ACTION         stop | destroy | off      (default stop)
  AUTOBACKUP_MINUTES  default 15   (0 = off)

"Keep awake": the menu writes an end time into /workspace/.watcher_pause.
State for the status page / menu: /workspace/.watcher.json   Log: /workspace/logs/watcher.log
"""
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import time
import urllib.request
from pathlib import Path

WS = Path("/workspace")
STATE = WS / ".watcher.json"
PAUSE = WS / ".watcher_pause"
BUSY = WS / ".busy"
PROVISION_LOG = WS / "logs" / "provision.log"
LOG = WS / "logs" / "watcher.log"
CHECK_EVERY = 30
GPU_BUSY_PERCENT = 15


def env(key, default=""):
    val = os.environ.get(key, "")
    if not val and os.path.exists("/etc/environment"):
        for line in open("/etc/environment", errors="ignore"):
            if line.startswith(key + "="):
                val = line.split("=", 1)[1].strip().strip('"')
                break
    return val or default


def as_int(key, default):
    try:
        return int(float(env(key, str(default))))
    except ValueError:
        return default


IDLE_MIN = as_int("IDLE_MINUTES", 30)
ACTION = env("IDLE_ACTION", "stop").lower()
if ACTION not in ("stop", "destroy", "off"):
    ACTION = "stop"
BACKUP_MIN = as_int("AUTOBACKUP_MINUTES", 15)


def log(msg):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG, "a") as fh:
        fh.write(f"{dt.datetime.now():%Y-%m-%d %H:%M:%S} {msg}\n")


def get_json(url, timeout=3):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.load(r)


def iso_age(ts):
    """Seconds since an ISO timestamp like 2026-11-19T20:01:02.123Z."""
    try:
        t = dt.datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return (dt.datetime.now(dt.timezone.utc) - t).total_seconds()
    except Exception:  # noqa: BLE001
        return 1e9


# ----------------------------------------------------------------------------- activity checks
def comfy_busy():
    try:
        q = get_json("http://127.0.0.1:18188/queue")
        n = len(q.get("queue_running", [])) + len(q.get("queue_pending", []))
        return f"ComfyUI: {n} job(s) running/queued" if n else ""
    except Exception:  # noqa: BLE001
        return ""


COMFY_ACTIVITY = WS / ".comfy_activity"


def comfy_ui_recent(limit_sec):
    """Someone clicked/typed/moved windows in ComfyUI recently (ComfyUI-VaultActivity extension)."""
    try:
        if time.time() - COMFY_ACTIVITY.stat().st_mtime < limit_sec:
            return "ComfyUI in use (editing)"
    except OSError:
        pass
    return ""


def gpu_busy():
    try:
        out = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True, timeout=10).stdout
        util = max(int(x) for x in out.split() if x.strip().isdigit())
        return f"GPU {util}% busy" if util >= GPU_BUSY_PERCENT else ""
    except Exception:  # noqa: BLE001
        return ""


def menu_busy():
    if BUSY.exists():
        names = [p.read_text(errors="ignore").strip() or p.name for p in BUSY.iterdir() if p.is_file()]
        if names:
            return "Menu task running: " + ", ".join(sorted(set(names)))
    return ""


def vault_locked():
    """A vault backup/restore/shutdown is running (checked by process name - no lock race)."""
    p = subprocess.run(["pgrep", "-f", r"vault(\.sh)? (backup|restore|shutdown)"],
                       capture_output=True, text=True)
    return "Backup/restore running" if p.stdout.strip() else ""


def jupyter_recent(limit_sec):
    """Kernels busy, or kernel/terminal used within the last check window."""
    try:
        for k in get_json("http://127.0.0.1:18888/api/kernels"):
            if k.get("execution_state") == "busy":
                return "Jupyter kernel busy"
            if iso_age(k.get("last_activity", "")) < limit_sec:
                return "Jupyter used recently"
        for t in get_json("http://127.0.0.1:18888/api/terminals"):
            if iso_age(t.get("last_activity", "")) < limit_sec:
                return "Jupyter terminal used recently"
    except Exception:  # noqa: BLE001
        pass
    return ""


def provisioning_done():
    if not PROVISION_LOG.exists():
        return False
    text = PROVISION_LOG.read_text(errors="ignore")
    i = text.rfind("===== PROVISION started")
    run = text[i:] if i >= 0 else text
    return "===== PROVISION COMPLETE" in run or "PROVISION FAILED" in run


def paused_until():
    try:
        return float(PAUSE.read_text().strip())
    except Exception:  # noqa: BLE001
        return 0.0


# ----------------------------------------------------------------------------- main loop
ST = {}            # current state, written to /workspace/.watcher.json


def push(**kw):
    """Update the state file (status page + menu read it)."""
    ST.update(kw)
    ST["updated"] = time.time()
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(ST))
    tmp.replace(STATE)


RCLONE_STATS = re.compile(r"NOTICE:\s+(?:\[\d+/\d+\]\s*)?([\d.]+\s*\w+) / ([\d.]+\s*\w+), (\d+)%, ([\d.]+\s*\w+/s), ETA (\S+)")
STEP_LINE = re.compile(r"(Backing up .*|Asking Vast to .*|Vast accepted.*|BACKUP COMPLETE|Skipping backup.*|ERROR: .*|WARNING: .*)")


def run_vault(*args):
    """Run vault, streaming its progress into the state file every few seconds. Returns (ok, last lines)."""
    cmd = ["nice", "-n", "10"] + (["ionice", "-c3"] if shutil.which("ionice") else []) + ["vault", *args]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    lines, last_push = [], 0.0
    push(task="starting...", progress="", pct=None)
    for line in p.stdout:
        line = line.rstrip()
        lines.append(line)
        m = STEP_LINE.search(line)
        if m:
            step = m.group(1).replace("=", "").strip()
            push(task=step, progress="", pct=None)
            last_push = time.time()
            continue
        m = RCLONE_STATS.search(line)
        if m and time.time() - last_push > 3:
            done, total, pct, speed, eta = m.groups()
            push(progress=f"{done.replace('i', '')} of {total.replace('i', '')} &middot; "
                          f"{speed.replace('i', '')} &middot; ETA {eta}", pct=int(pct))
            last_push = time.time()
        elif time.time() - last_push > 20:
            push()                          # heartbeat so the page knows we're alive
            last_push = time.time()
    ok = p.wait() == 0
    return ok, "\n".join(lines[-3:])


def main():
    log(f"watcher started: idle {IDLE_MIN} min -> {ACTION}, auto-backup every {BACKUP_MIN} min")
    last_active = time.time()
    last_backup = time.time()          # first auto-backup one interval after start
    shutdown_retry_at = 0.0
    push(state="starting", reason="", idle=0, idle_limit=IDLE_MIN * 60, action=ACTION,
         backup_every=BACKUP_MIN * 60, last_backup=0, last_backup_ok=None, next_backup=0,
         paused_until=0, task="", progress="", pct=None, note="")
    while True:
        now = time.time()
        reason = ""
        if not provisioning_done():
            reason = "Setup still running"
        reason = reason or comfy_busy() or comfy_ui_recent(CHECK_EVERY * 2 + 15) or menu_busy() \
            or vault_locked() or gpu_busy() or jupyter_recent(CHECK_EVERY * 2 + 5)
        pause_end = paused_until()
        if pause_end > now:
            reason = reason or f"Keep-awake until {dt.datetime.fromtimestamp(pause_end):%H:%M}"
        if reason:
            last_active = now
        idle = now - last_active

        # ---- automatic backup (skipped while a backup/restore is already running)
        if BACKUP_MIN > 0 and provisioning_done() and now - last_backup >= BACKUP_MIN * 60 \
                and not vault_locked():
            log("auto-backup starting")
            push(state="backing up", reason=reason, idle=idle)
            ok, tail = run_vault("backup")
            last_backup = time.time()
            push(last_backup=last_backup, last_backup_ok=ok, task="", progress="", pct=None,
                 note="" if ok else "Last auto-backup FAILED - see /workspace/logs/vault.log")
            log(f"auto-backup {'OK' if ok else 'FAILED'}: {tail}")

        # ---- idle shutdown
        if ACTION != "off" and idle >= IDLE_MIN * 60 and now >= shutdown_retry_at:
            log(f"idle {int(idle // 60)} min -> backup + {ACTION}")
            push(state="shutting down", reason="", idle=idle)
            ok, tail = run_vault("shutdown", ACTION)
            log(f"shutdown {'requested' if ok else 'FAILED'}: {tail}")
            if ok:
                push(state="stopping", task=f"Vast accepted - instance will {ACTION} in a moment",
                     progress="", pct=None, last_backup=time.time(), last_backup_ok=True)
                for _ in range(60):        # keep the page alive until Vast stops us
                    time.sleep(10)
                    push()
            else:
                push(note="Last shutdown attempt FAILED (backup error) - instance kept running, "
                          "retrying in 10 min. See /workspace/logs/vault.log", progress="", pct=None)
            shutdown_retry_at = time.time() + 600

        push(state="active" if reason else "idle", reason=reason, idle=idle,
             next_backup=(last_backup + BACKUP_MIN * 60) if BACKUP_MIN > 0 else 0,
             paused_until=pause_end if pause_end > now else 0, task="", progress="", pct=None)
        time.sleep(CHECK_EVERY)


if __name__ == "__main__":
    main()
