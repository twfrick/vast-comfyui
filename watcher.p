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
    return "===== PROVISION COMPLETE" in (text[i:] if i >= 0 else text)


def paused_until():
    try:
        return float(PAUSE.read_text().strip())
    except Exception:  # noqa: BLE001
        return 0.0


# ----------------------------------------------------------------------------- main loop
def run_vault(*args):
    """Run vault in the background-friendly way; returns (ok, last lines)."""
    cmd = ["nice", "-n", "10"] + (["ionice", "-c3"] if shutil.which("ionice") else []) + ["vault", *args]
    p = subprocess.run(cmd, capture_output=True, text=True)
    tail = "\n".join((p.stdout + p.stderr).strip().splitlines()[-3:])
    return p.returncode == 0, tail


def write_state(**kw):
    kw["updated"] = time.time()
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(kw))
    tmp.replace(STATE)


def main():
    log(f"watcher started: idle {IDLE_MIN} min -> {ACTION}, auto-backup every {BACKUP_MIN} min")
    last_active = time.time()
    last_backup = time.time()          # first auto-backup one interval after start
    last_backup_ok = None
    last_backup_note = ""
    shutdown_retry_at = 0.0
    while True:
        now = time.time()
        reason = ""
        if not provisioning_done():
            reason = "Setup still running"
        reason = reason or comfy_busy() or menu_busy() or vault_locked() or gpu_busy() \
            or jupyter_recent(CHECK_EVERY * 2 + 5)
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
            write_state(state="backing up", reason=reason, idle=idle, idle_limit=IDLE_MIN * 60,
                        action=ACTION, backup_every=BACKUP_MIN * 60, last_backup=last_backup,
                        last_backup_ok=last_backup_ok, next_backup=now)
            ok, tail = run_vault("backup")
            last_backup, last_backup_ok, last_backup_note = time.time(), ok, tail
            log(f"auto-backup {'OK' if ok else 'FAILED'}: {tail}")

        # ---- idle shutdown
        if ACTION != "off" and idle >= IDLE_MIN * 60 and now >= shutdown_retry_at:
            log(f"idle {int(idle // 60)} min -> backup + {ACTION}")
            write_state(state=f"shutting down ({ACTION})", reason="", idle=idle, idle_limit=IDLE_MIN * 60,
                        action=ACTION, backup_every=BACKUP_MIN * 60, last_backup=last_backup,
                        last_backup_ok=last_backup_ok, next_backup=0)
            ok, tail = run_vault("shutdown", ACTION)
            log(f"shutdown {'requested' if ok else 'FAILED'}: {tail}")
            if ok:
                time.sleep(600)            # Vast stops us within seconds
            shutdown_retry_at = time.time() + 600   # if it failed (e.g. backup error), try again in 10 min

        write_state(state="active" if reason else "idle", reason=reason, idle=idle, idle_limit=IDLE_MIN * 60,
                    action=ACTION, backup_every=BACKUP_MIN * 60, last_backup=last_backup,
                    last_backup_ok=last_backup_ok, last_backup_note=last_backup_note,
                    next_backup=(last_backup + BACKUP_MIN * 60) if BACKUP_MIN > 0 else 0,
                    paused_until=pause_end if pause_end > now else 0)
        time.sleep(CHECK_EVERY)


if __name__ == "__main__":
    main()
