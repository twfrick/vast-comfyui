"""
vault_menu.py  -  Jupyter control panel for ComfyUI on Vast.ai

Open /workspace/ComfyUI-Menu.ipynb in JupyterLab and run its single cell.
Tabs: Models (Hugging Face / Civitai) | Nodes (GitHub) | Outputs (browser download)
      | Vault (R2 backup/restore) | ComfyUI (restart / log)
"""
import html
import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import ipywidgets as W
from IPython.display import HTML, Javascript, display

WORKSPACE = Path(os.environ.get("WORKSPACE", "/workspace"))
COMFY = WORKSPACE / "ComfyUI"
MODELS = COMFY / "models"
NODES = COMFY / "custom_nodes"
OUTPUT = COMFY / "output"
PY = "/venv/main/bin/python"
CONSTRAINTS = WORKSPACE / ".torch-constraints.txt"
DOWNLOADED_LIST = WORKSPACE / ".outputs_downloaded.txt"
BUSY_DIR = WORKSPACE / ".busy"          # idle watcher won't stop the instance while files exist here
COMFY_URL = os.environ.get("COMFY_URL", "https://comfyui.centarione.org")
# Civitai/Cloudflare block Python's default user agent (HTTP 403) - send a normal one
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

CIVITAI_TYPE_FOLDER = {
    "Checkpoint": "checkpoints", "LORA": "loras", "LoCon": "loras", "DoRA": "loras",
    "TextualInversion": "embeddings", "VAE": "vae", "Controlnet": "controlnet",
    "Upscaler": "upscale_models", "Hypernetwork": "hypernetworks",
    "MotionModule": "animatediff_models", "Detection": "ultralytics",
}


# ----------------------------------------------------------------------------- helpers
def env(key):
    """Read a variable from the environment or /etc/environment (Vast account vars)."""
    val = os.environ.get(key, "")
    if not val and os.path.exists("/etc/environment"):
        for line in open("/etc/environment", errors="ignore"):
            if line.startswith(key + "="):
                val = line.split("=", 1)[1].strip().strip('"')
                break
    return val


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024
    return f"{n:.1f} PB"


def model_folders():
    if not MODELS.exists():
        return ["checkpoints"]
    return sorted(p.name for p in MODELS.iterdir() if p.is_dir() and not p.name.startswith("."))


class LogBox:
    """Log panel; a small script (installed by show()) keeps it scrolled to the newest line
    unless you scroll up to read. Safe to update from background threads."""
    _count = 0

    def __init__(self, height="480px"):
        LogBox._count += 1
        self.id = f"log{LogBox._count}"
        self.lines = []
        self.height = height
        self.widget = W.HTML(layout=W.Layout(width="100%"))
        self._render()

    def _render(self):
        text = html.escape("\n".join(self.lines)) or "&nbsp;"
        self.widget.value = (
            f"<div class='vm-log' data-log='{self.id}' style='height:{self.height};overflow-y:auto;"
            f"border:1px solid var(--jp-border-color1);border-radius:4px;background:var(--jp-layout-color1);"
            f"padding:6px;scrollbar-width:auto'>"
            f"<pre style='margin:0;white-space:pre-wrap;font-size:12px;"
            f"color:var(--jp-content-font-color1)'>{text}</pre></div>")

    def __call__(self, msg=""):
        for line in str(msg).rstrip("\n").split("\n"):
            self.lines.append(line)
        self.lines = self.lines[-500:]
        self._render()

    def clear(self):
        self.lines = []
        self._render()


# Each log update replaces the box, which would jump it back to the top. This script
# remembers whether you were at the bottom and puts every new box back where it belongs.
AUTOSCROLL_JS = """
(() => {
  if (window.__vmLogScroll) return;
  window.__vmLogScroll = true;
  const state = {};
  const fix = el => {
    if (el.__vmDone) return; el.__vmDone = true;
    const id = el.dataset.log, s = state[id] || {stick: true, top: 0};
    el.scrollTop = s.stick ? el.scrollHeight : s.top;
    el.addEventListener('scroll', () => {
      state[id] = {stick: el.scrollTop + el.clientHeight >= el.scrollHeight - 25, top: el.scrollTop};
    });
  };
  new MutationObserver(() => document.querySelectorAll('.vm-log').forEach(fix))
    .observe(document.body, {childList: true, subtree: true});
  document.querySelectorAll('.vm-log').forEach(fix);
})();
"""


def run_cmd(cmd, log, cwd=None, hide=None, on_line=None):
    """Run a command, stream its output to the log, return exit code.
    on_line(line) may return True to swallow a line (e.g. progress updates)."""
    shown = " ".join(cmd) if isinstance(cmd, list) else cmd
    if hide:
        shown = shown.replace(hide, "***")
    log(f"$ {shown}")
    # start_new_session: the job keeps running even if the notebook kernel or JupyterLab restarts
    proc = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1, shell=isinstance(cmd, str), start_new_session=True)
    for line in proc.stdout:
        line = line.rstrip()
        if hide:
            line = line.replace(hide, "***")
        if on_line and on_line(line):
            continue
        if line:
            log(line)
    return proc.wait()


def run_detached(cmd, log, name):
    """Run a long job (backup/restore/shutdown) fully detached: it writes to its own log file and
    keeps running even if this notebook or JupyterLab restarts. We just follow the file."""
    out = WORKSPACE / "logs" / f"menu-{name}.log"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("")
    log(f"$ {' '.join(cmd)}   (log: {out})")
    proc = subprocess.Popen(["bash", "-c", 'exec "$@" >> "$0" 2>&1', str(out)] + cmd,
                            start_new_session=True, stdin=subprocess.DEVNULL)
    with open(out, errors="ignore") as fh:
        while True:
            line = fh.readline()
            if line:
                if line.strip():
                    log(line.rstrip())
                continue
            if proc.poll() is not None:
                rest = fh.read()
                if rest.strip():
                    log(rest.rstrip())
                return proc.returncode
            time.sleep(0.5)


def in_background(name, log, fn, *args):
    """Run fn(*args) in a thread; mark the instance busy while it runs."""
    def worker():
        BUSY_DIR.mkdir(parents=True, exist_ok=True)
        flag = BUSY_DIR / f"{name}-{int(time.time()*1000)}"
        flag.write_text(name)
        try:
            fn(*args)
        except Exception as e:  # noqa: BLE001
            log(f"ERROR: {e}")
        finally:
            flag.unlink(missing_ok=True)
    threading.Thread(target=worker, daemon=True).start()


class ProgressRow:
    """One progress bar per download: name | bar | 42%  1.2 GB / 6.5 GB  250 MB/s  ETA 21s"""
    def __init__(self, title="starting..."):
        self.name = W.HTML(f"<b>{title}</b>", layout=W.Layout(width="34%"))
        self.bar = W.FloatProgress(value=0, min=0, max=100, layout=W.Layout(width="36%"))
        self.status = W.HTML("waiting...", layout=W.Layout(width="30%"))
        self.widget = W.HBox([self.name, self.bar, self.status])

    def set_name(self, name):
        self.name.value = f"<b>{name}</b>"

    def update(self, pct, text):
        self.bar.value = pct
        self.status.value = text

    def finish(self, ok, text):
        self.bar.value = 100 if ok else self.bar.value
        self.bar.bar_style = "success" if ok else "danger"
        self.status.value = text


def to_bytes(v):
    """'1.9GiB' / '400MiB' / '512KiB' / '12B' -> bytes"""
    m = re.match(r"([\d.]+)\s*([KMGT]?)i?B", v)
    if not m:
        return 0
    return float(m.group(1)) * 1024 ** "_KMGT".index(m.group(2) or "_")


ARIA_PROGRESS = re.compile(r"\[#\w+\s+([\d.]+\w+)/([\d.]+\w+)\((\d+)%\)[^\]]*?DL:([\d.]+\w+)(?:\s+ETA:(\w+))?")
ARIA_NOISE = ("***", "====", "----", "FILE:")


def aria_filter(bar):
    """Turn aria2c summary lines into progress-bar updates."""
    def on_line(line):
        m = ARIA_PROGRESS.search(line)
        if m:
            done, total, pct, speed, eta = m.groups()
            if bar:
                left = human(max(to_bytes(total) - to_bytes(done), 0))
                bar.update(int(pct), f"{pct}% &nbsp; {human(to_bytes(done))} / {human(to_bytes(total))} "
                                     f"&nbsp; <b>{left} left</b> &nbsp; {human(to_bytes(speed))}/s"
                                     + (f" &nbsp; ETA {eta}" if eta else ""))
            return True
        return line.strip().startswith(ARIA_NOISE)
    return on_line


def download_file(url, dest_dir, filename, log, headers=None, hide=None, bar=None):
    """aria2c (fast, 16 connections) with curl fallback. Returns True on success."""
    dest_dir = Path(dest_dir)
    dest_dir.mkdir(parents=True, exist_ok=True)
    target = dest_dir / filename
    if bar:
        bar.set_name(filename)
    if target.exists() and not (dest_dir / (filename + ".aria2")).exists():
        log(f"Already exists, skipped: {target}")
        if bar:
            bar.finish(True, "already exists")
        return True
    log(f"Downloading {filename}\n  -> {dest_dir}")
    cmd = ["aria2c", "-x", "16", "-s", "16", "-k", "1M", "--continue=true", "--file-allocation=none",
           f"--user-agent={UA}",
           "--auto-file-renaming=false", "--allow-overwrite=true", "--summary-interval=1",
           "--show-console-readout=false", "--console-log-level=warn", "--download-result=hide",
           "-d", str(dest_dir), "-o", filename]
    for h in headers or []:
        cmd += ["--header", h]
    if shutil.which("aria2c") and run_cmd(cmd + [url], log, hide=hide, on_line=aria_filter(bar)) == 0:
        ok = True
    else:
        log("aria2c failed - retrying with curl")
        if bar:
            bar.update(0, "retrying (no progress shown)...")
        cmd = ["curl", "-fL", "--retry", "3", "-A", UA, "-o", str(target)]
        for h in headers or []:
            cmd += ["-H", h]
        ok = run_cmd(cmd + [url], log, hide=hide) == 0
    if ok and target.exists():
        size = human(target.stat().st_size)
        log(f"DONE: {target.name} ({size})")
        if bar:
            bar.finish(True, f"done &nbsp; {size}")
        return True
    log("DOWNLOAD FAILED")
    if bar:
        bar.finish(False, "FAILED - see log below")
    return False


# ----------------------------------------------------------------------------- Hugging Face
def hf_parse(url):
    """https://huggingface.co/<repo>/(resolve|blob)/<rev>/<path>  ->  (direct_url, filename)"""
    url = url.strip().split("?")[0]
    m = re.match(r"https?://(?:www\.)?huggingface\.co/(.+?)/(?:resolve|blob)/([^/]+)/(.+)$", url)
    if not m:
        raise ValueError("Paste a Hugging Face FILE link, e.g. "
                         "https://huggingface.co/user/repo/blob/main/model.safetensors")
    repo, rev, path = m.groups()
    return f"https://huggingface.co/{repo}/resolve/{rev}/{path}", path.split("/")[-1]


def hf_download(url, folder, log, bar=None):
    direct, name = hf_parse(url)
    token = env("HF_TOKEN")
    headers = [f"Authorization: Bearer {token}"] if token else []
    download_file(direct, MODELS / folder, name, log, headers=headers, hide=token or None, bar=bar)


# ----------------------------------------------------------------------------- Civitai
def civitai_api(path, token):
    headers = {"User-Agent": UA, "Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"https://civitai.com/api/v1/{path}", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        body = e.read()[:300].decode("utf-8", "ignore")
        hint = {401: "Civitai key missing or invalid (CIVITAI_TOKEN)",
                403: "Civitai refused the request (key, or model needs login/early access)",
                404: "Model or version not found - check the link"}.get(e.code, "")
        raise RuntimeError(f"Civitai API HTTP {e.code}. {hint}\n{body}") from None


def civitai_version_id(text, token):
    text = text.strip()
    m = re.search(r"modelVersionId=(\d+)", text) or re.search(r"/api/download/models/(\d+)", text)
    if m:
        return m.group(1)
    m = re.search(r"/models/(\d+)", text)
    if m:
        data = civitai_api(f"models/{m.group(1)}", token)
        return str(data["modelVersions"][0]["id"])     # newest version
    if text.isdigit():
        return text
    raise ValueError("Paste a Civitai model link (or a model version ID)")


def civitai_download(text, folder, log, bar=None):
    token = env("CIVITAI_TOKEN")
    vid = civitai_version_id(text, token)
    info = civitai_api(f"model-versions/{vid}", token)
    files = info.get("files", [])
    if not files:
        raise ValueError("No downloadable file found for this model version")
    f = next((x for x in files if x.get("primary")), files[0])
    mtype = (info.get("model") or {}).get("type", "")
    if folder == "Auto":
        folder = CIVITAI_TYPE_FOLDER.get(mtype, "checkpoints")
    log(f"Civitai: {(info.get('model') or {}).get('name', '')} / {info.get('name', '')}  "
        f"type={mtype}  -> models/{folder}")
    url = f["downloadUrl"]
    if token:
        url += ("&" if "?" in url else "?") + "token=" + token
    download_file(url, MODELS / folder, f["name"], log, hide=token or None, bar=bar)


# ----------------------------------------------------------------------------- GitHub nodes
def install_requirements(node_dir, log):
    uv = shutil.which("uv")
    pip = [uv, "pip", "install", "--python", PY] if uv else [PY, "-m", "pip", "install"]
    if CONSTRAINTS.exists():
        pip += ["-c", str(CONSTRAINTS)]
    if (node_dir / "requirements.txt").exists():
        log("Installing requirements...")
        if run_cmd(pip + ["-r", str(node_dir / "requirements.txt")], log) != 0:
            log("WARNING: some requirements failed")
    if (node_dir / "install.py").exists():
        log("Running install.py...")
        run_cmd([PY, "install.py"], log, cwd=str(node_dir))


def github_install(url, restart, log):
    url = url.strip().rstrip("/")
    url = re.sub(r"/(tree|blob)/.*$", "", url)
    url = re.sub(r"\.git$", "", url)
    if not re.match(r"https://github\.com/[^/]+/[^/]+$", url):
        raise ValueError("Paste a GitHub repo link, e.g. https://github.com/user/ComfyUI-SomeNode")
    name = url.split("/")[-1]
    dest = NODES / name
    if dest.exists():
        log(f"{name} already installed - updating")
        run_cmd(["git", "-C", str(dest), "pull", "--ff-only"], log)
    else:
        if run_cmd(["git", "clone", "--recursive", url + ".git", str(dest)], log) != 0:
            token = env("GITHUB_TOKEN")
            if not token:
                raise RuntimeError("git clone failed")
            log("Public clone failed - trying with GITHUB_TOKEN (private repo)")
            authed = url.replace("https://", f"https://x-access-token:{token}@") + ".git"
            if run_cmd(["git", "clone", "--recursive", authed, str(dest)], log, hide=token) != 0:
                raise RuntimeError("git clone failed")
            run_cmd(["git", "-C", str(dest), "remote", "set-url", "origin", url + ".git"], log)
    install_requirements(dest, log)
    log(f"DONE: {name}")
    if restart:
        restart_comfyui(log)


def update_all_nodes(log):
    for d in sorted(NODES.iterdir()):
        if (d / ".git").exists():
            log(f"--- {d.name}")
            run_cmd(["git", "-C", str(d), "pull", "--ff-only"], log)
            install_requirements(d, log)
    restart_comfyui(log)


# ----------------------------------------------------------------------------- ComfyUI
def restart_comfyui(log):
    log("Restarting ComfyUI...")
    run_cmd(["supervisorctl", "restart", "comfyui"], log)
    for _ in range(60):
        try:
            urllib.request.urlopen("http://127.0.0.1:18188/system_stats", timeout=2)
            log("ComfyUI is running.")
            return
        except Exception:  # noqa: BLE001
            time.sleep(2)
    log("ComfyUI did not answer within 2 minutes - check the log")


# ----------------------------------------------------------------------------- Model cleanup
MODEL_SKIP = re.compile(r"(\.partial|\.aria2|\.tmp)$")


def model_files():
    """All model files under ComfyUI/models -> [(path, size)], sorted by folder/name."""
    if not MODELS.exists():
        return []
    out = []
    for p in MODELS.rglob("*"):
        rel = p.relative_to(MODELS).parts
        if any(part.startswith(".") for part in rel) or "__pycache__" in rel:
            continue
        if not p.is_file() or PLACEHOLDER.match(p.name) or MODEL_SKIP.search(p.name):
            continue
        try:
            out.append((p, p.stat().st_size))
        except OSError:
            pass
    return sorted(out, key=lambda x: str(x[0].relative_to(MODELS)).lower())


def wait_for_vault_lock(log):
    """Wait until no other backup/restore holds /tmp/vault.lock (e.g. the 15-min auto-backup)."""
    import fcntl
    told = False
    while True:
        with open("/tmp/vault.lock", "a") as fh:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fh, fcntl.LOCK_UN)
                return
            except OSError:
                if not told:
                    log("Another backup is running - waiting for it to finish...")
                    told = True
        time.sleep(10)


def delete_models(paths, log):
    gone, freed = 0, 0
    for p in paths:
        try:
            size = p.stat().st_size
            p.unlink()
            gone += 1
            freed += size
            log(f"Deleted {p.relative_to(MODELS)}  ({human(size)})")
        except OSError as e:
            log(f"ERROR: could not delete {p.relative_to(MODELS)}: {e}")
    log(f"Deleted {gone} file(s), freed {human(freed)} on this instance.")
    if not gone:
        return
    log("")
    log("Removing them from R2 too (they go to the R2 trash first; Vault tab -> 'Show R2 trash' to put back)...")
    wait_for_vault_lock(log)
    rc = run_detached(["vault", "backup", "--allow-delete"], log, "model-delete")
    log("DONE - removed from R2 (in R2 trash)." if rc == 0
        else "WARNING: backup did not finish - the models are still in R2. Run Backup on the Vault tab.")


# ----------------------------------------------------------------------------- Outputs
PLACEHOLDER = re.compile(r"^(_.*_will_be_put_here|put_.*_here)$")   # ComfyUI's empty marker files


def output_files():
    if not OUTPUT.exists():
        return []
    return sorted(p for p in OUTPUT.rglob("*")
                  if p.is_file() and not PLACEHOLDER.match(p.name)
                  and not any(part.startswith(".") for part in p.relative_to(OUTPUT).parts))


def downloaded_set():
    if DOWNLOADED_LIST.exists():
        return set(DOWNLOADED_LIST.read_text().splitlines())
    return set()


def browser_download(paths, js_out):
    """Make the browser download each file (flat, original names) one after another."""
    rels = ["/".join(urllib.parse.quote(part) for part in str(p).lstrip("/").split("/")) for p in paths]
    js = """
    (async () => {
      let base = '/';
      try { base = JSON.parse(document.getElementById('jupyter-config-data').textContent).baseUrl || '/'; } catch (e) {}
      const files = %s;
      for (const f of files) {
        const a = document.createElement('a');
        a.href = base + 'files/' + f + '?download=1';
        a.download = '';
        document.body.appendChild(a); a.click(); a.remove();
        await new Promise(r => setTimeout(r, 500));
      }
    })();
    """ % json.dumps(rels)
    with js_out:
        js_out.clear_output()
        display(Javascript(js))


# ----------------------------------------------------------------------------- watcher
WATCH_STATE = WORKSPACE / ".watcher.json"
WATCH_PAUSE = WORKSPACE / ".watcher_pause"


def fmt_min(sec):
    sec = int(max(sec, 0))
    return f"{sec // 3600}h {sec % 3600 // 60}m" if sec >= 3600 else f"{sec // 60}m"


def watcher_summary():
    try:
        w = json.loads(WATCH_STATE.read_text())
    except Exception:  # noqa: BLE001
        return "Idle watcher: not running yet"
    now = time.time()
    if now - w.get("updated", 0) > 120:
        return "<b style='color:#c62828'>Idle watcher: not running</b>"
    act = w.get("action", "stop").upper()
    if act == "OFF":
        txt = "Auto-shutdown off"
    elif w.get("reason"):
        txt = f"Active ({html.escape(w['reason'])})"
    else:
        txt = f"<b>Idle {fmt_min(w.get('idle', 0))}</b> &rarr; {act} in {fmt_min(w.get('idle_limit', 0) - w.get('idle', 0))}"
    if w.get("backup_every"):
        txt += f" &nbsp;|&nbsp; next auto-backup in {fmt_min(w.get('next_backup', 0) - now)}"
    return "Watcher: " + txt


# ----------------------------------------------------------------------------- UI
def show():
    style = {"description_width": "110px"}
    wide = W.Layout(width="95%")

    # ---------- header
    def header_html():
        gpu = subprocess.run(["nvidia-smi", "--query-gpu=name,memory.total", "--format=csv,noheader"],
                             capture_output=True, text=True).stdout.strip() or "?"
        du = shutil.disk_usage(str(WORKSPACE))
        last = (WORKSPACE / ".vault_last_backup")
        last = last.read_text().strip() if last.exists() else "never (this instance)"
        try:
            urllib.request.urlopen("http://127.0.0.1:18188/system_stats", timeout=2)
            comfy = "<b style='color:#2e7d32'>running</b>"
        except Exception:  # noqa: BLE001
            comfy = "<b style='color:#c62828'>not running</b>"
        where = ("<span style='background:#2e7d32;color:#fff;padding:1px 8px;border-radius:4px'>"
                 "Tunnel JupyterLab (jupyter.centarione.org)</span>" if os.environ.get("VAULT_LAB")
                 else "<span style='background:#ef6c00;color:#fff;padding:1px 8px;border-radius:4px'>"
                      "Vast's Jupyter (backup way in)</span>")
        return (f"<div style='font-size:14px;line-height:1.6'>{where}<br>"
                f"<a href='{COMFY_URL}' target='_blank' style='font-size:16px'><b>&#9654; Open ComfyUI</b></a>"
                f" &nbsp;|&nbsp; ComfyUI: {comfy} &nbsp;|&nbsp; GPU: {gpu}<br>"
                f"Disk: {human(du.used)} used, <b>{human(du.free)} free</b> of {human(du.total)}"
                f" &nbsp;|&nbsp; Last backup: {last}<br>{watcher_summary()}</div>")
    header = W.HTML(header_html())
    refresh = W.Button(description="Refresh", icon="refresh", layout=W.Layout(width="110px"))
    refresh.on_click(lambda _: setattr(header, "value", header_html()))

    # ---------- Models tab
    mlog = LogBox()
    src = W.ToggleButtons(options=["Hugging Face", "Civitai"], value="Hugging Face")
    murl = W.Text(placeholder="Paste the model link here", description="Link:", style=style, layout=wide)
    mfolder = W.Dropdown(options=model_folders(), description="Save to models/", style=style)
    mbtn = W.Button(description="Download", button_style="primary", icon="download")
    mlist = W.Button(description="List folder", icon="folder-open")
    mclear = W.Button(description="Clear finished", icon="eraser")
    mprog = W.VBox([])          # one progress row per download
    mhelp = W.HTML()

    def on_src(_=None):
        folders = model_folders()
        if src.value == "Civitai":
            mfolder.options = ["Auto"] + folders
            mfolder.value = "Auto"
            mhelp.value = ("<i>Civitai model page link (e.g. https://civitai.com/models/12345?modelVersionId=67890). "
                           "'Auto' picks the folder from the model type.</i>")
        else:
            mfolder.options = folders
            mfolder.value = "checkpoints" if "checkpoints" in folders else folders[0]
            mhelp.value = ("<i>Hugging Face file link (the page of the .safetensors file, "
                           "e.g. https://huggingface.co/user/repo/blob/main/model.safetensors).</i>")
    src.observe(on_src, "value")
    on_src()

    def on_model(_):
        link, folder, which = murl.value, mfolder.value, src.value
        if not link.strip():
            mlog("Paste a link first.")
            return
        murl.value = ""
        mlog.clear()
        mprog.children = tuple(w for w in mprog.children
                               if w.children[1].bar_style not in ("success", "danger"))
        row = ProgressRow("looking up " + ("Hugging Face" if which == "Hugging Face" else "Civitai") + "...")
        mprog.children = tuple(mprog.children) + (row.widget,)
        fn = hf_download if which == "Hugging Face" else civitai_download

        def job():
            try:
                fn(link, folder, mlog, row)
            except Exception as e:  # noqa: BLE001
                row.finish(False, "FAILED - see log below")
                raise e
        in_background("download", mlog, job)
    mbtn.on_click(on_model)

    def on_list(_):
        folder = mfolder.value
        if folder in (None, "Auto"):
            mlog("Pick a folder (not Auto) to list it.")
            return
        d = MODELS / folder
        files = sorted(p for p in d.rglob("*") if p.is_file()) if d.exists() else []
        mlog(f"--- models/{folder}: {len(files)} file(s)")
        for p in files:
            mlog(f"  {human(p.stat().st_size):>10}  {p.relative_to(d)}")
    mlist.on_click(on_list)

    def on_clear(_):
        mprog.children = tuple(w for w in mprog.children
                               if w.children[1].bar_style not in ("success", "danger"))
    mclear.on_click(on_clear)
    models_tab = W.VBox([src, mhelp, murl, W.HBox([mfolder, mbtn, mlist, mclear]),
                         W.HTML("<small>You can start several downloads; they run in the background.</small>"),
                         mprog, mlog.widget])

    # ---------- Models tab (list + delete)
    xlog = LogBox()
    xfolder = W.Dropdown(options=["All folders"], value="All folders", description="Folder:", style=style)
    xrefresh = W.Button(description="Refresh list", icon="refresh")
    xall = W.Button(description="Select all", icon="check-square")
    xnone = W.Button(description="Clear selection", icon="square")
    xconfirm = W.Checkbox(value=False, description="Yes, delete the selected models", indent=False)
    xdel = W.Button(description="Delete selected", button_style="danger", icon="trash")
    xsum = W.HTML()
    xbox = W.VBox(layout=W.Layout(max_height="420px", overflow_y="auto", border="1px solid #ddd", padding="4px"))
    xrows = []   # (checkbox, path, size)

    def x_update_sum(_=None):
        sel = [(p, n) for cb, p, n in xrows if cb.value]
        total = sum(n for _, _, n in xrows)
        xsum.value = (f"<b>{len(xrows)}</b> model file(s), {human(total)} shown &nbsp;|&nbsp; "
                      f"<b style='color:#c62828'>{len(sel)} selected ({human(sum(n for _, n in sel))})</b>")

    def x_build(_=None):
        files = model_files()
        folders = sorted({p.relative_to(MODELS).parts[0] for p, _ in files if len(p.relative_to(MODELS).parts) > 1})
        keep = xfolder.value if xfolder.value in folders else "All folders"
        xfolder.unobserve(x_build, "value")
        xfolder.options = ["All folders"] + folders
        xfolder.value = keep
        xfolder.observe(x_build, "value")
        xrows.clear()
        kids, last = [], None
        for p, n in files:
            rel = p.relative_to(MODELS)
            top = rel.parts[0] if len(rel.parts) > 1 else "(models)"
            if keep != "All folders" and top != keep:
                continue
            if top != last:
                kids.append(W.HTML(f"<b style='font-size:1.05em'>{html.escape(top)}/</b>"))
                last = top
            cb = W.Checkbox(value=False, indent=False, layout=W.Layout(width="auto"),
                            description=f"{Path(*rel.parts[1:]) if len(rel.parts) > 1 else rel}   ({human(n)})")
            cb.observe(x_update_sum, "value")
            xrows.append((cb, p, n))
            kids.append(cb)
        xbox.children = kids or [W.HTML("No models found.")]
        xconfirm.value = False
        x_update_sum()
    xfolder.observe(x_build, "value")
    xrefresh.on_click(x_build)

    def x_set_all(v):
        for cb, _, _ in xrows:
            cb.value = v
    xall.on_click(lambda _: x_set_all(True))
    xnone.on_click(lambda _: x_set_all(False))

    def on_xdel(_):
        xlog.clear()
        sel = [p for cb, p, _ in xrows if cb.value]
        if not sel:
            xlog("Tick at least one model first.")
            return
        if not xconfirm.value:
            xlog(f"{len(sel)} model(s) selected. Tick 'Yes, delete the selected models', then click Delete again.")
            return
        xconfirm.value = False
        def job():
            delete_models(sel, xlog)
            x_build()
        in_background("model-delete", xlog, job)
    xdel.on_click(on_xdel)
    x_build()
    cleanup_tab = W.VBox([
        W.HTML("Tick the models you no longer want, then delete. They are removed here and from R2 "
               "(R2 keeps them in its trash until you empty it on the Vault tab)."),
        W.HBox([xfolder, xrefresh, xall, xnone]), xsum, xbox,
        W.HBox([xconfirm, xdel]), xlog.widget])

    # ---------- Nodes tab
    nlog = LogBox()
    nurl = W.Text(placeholder="https://github.com/user/ComfyUI-SomeNode", description="GitHub link:",
                  style=style, layout=wide)
    nrestart = W.Checkbox(value=True, description="Restart ComfyUI when done")
    nbtn = W.Button(description="Install node", button_style="primary", icon="plus")
    nupd = W.Button(description="Update all nodes", icon="sync")
    nrefresh = W.Button(description="Refresh list", icon="refresh")
    nlist = W.HTML()

    def node_status():
        """Read the last ComfyUI start in comfyui.log -> ({folder: 'ok'|'failed'}, start time)."""
        p = WORKSPACE / "logs" / "comfyui.log"
        try:
            text = re.sub(r"\x1b\[[0-9;]*m", "", p.read_text(errors="ignore"))
        except OSError:
            return {}, None
        i = text.rfind("Import times for custom nodes:")
        if i < 0:
            return {}, None
        status = {}
        for line in text[i:].splitlines()[1:]:
            m = re.search(r"seconds( \(IMPORT FAILED\))?: (.+)$", line)
            if not m:
                if status:
                    break
                continue
            status[Path(m.group(2).strip()).name] = "failed" if m.group(1) else "ok"
        return status, None

    def list_nodes():
        names = sorted(p.name for p in NODES.iterdir()
                       if (p.is_dir() or p.suffix == ".py") and not p.name.startswith((".", "__"))) \
            if NODES.exists() else []
        status, _ = node_status()
        rows, failed, pending = [], 0, 0
        for n in names:
            st = status.get(n)
            if st == "ok":
                rows.append(f"<span style='color:#2e7d32'>&#10004; {html.escape(n)}</span>")
            elif st == "failed":
                failed += 1
                rows.append(f"<span style='color:#c62828'><b>&#10008; {html.escape(n)} (failed to load)</b></span>")
            else:
                pending += 1
                rows.append(f"<span style='color:#ef6c00'><b>&#9888; {html.escape(n)} (restart ComfyUI to load)</b></span>")
        notes = []
        if pending:
            notes.append(f"<span style='color:#ef6c00'>{pending} not loaded yet: click <b>Restart ComfyUI</b> "
                         "(ComfyUI tab), then Ctrl+Shift+R in the ComfyUI page.</span>")
        if failed:
            notes.append(f"<span style='color:#c62828'>{failed} failed: ComfyUI tab &rarr; Show ComfyUI log, "
                         "look for IMPORT FAILED.</span>")
        nlist.value = (f"<b>Installed ({len(names)}):</b><br>" + ("<br>".join(rows) if rows else "none")
                       + ("<br>" + "<br>".join(notes) if notes else "")
                       + f"<br><small>Checked {time.strftime('%H:%M:%S')}</small>")
    list_nodes()
    nrefresh.on_click(lambda _: list_nodes())

    def on_node(_):
        link = nurl.value
        nlog.clear()
        if not link.strip():
            nlog("Paste a link first.")
            return
        nurl.value = ""
        def job():
            github_install(link, nrestart.value, nlog)
            list_nodes()
        in_background("node", nlog, job)
    nbtn.on_click(on_node)

    def on_update(_):
        nlog.clear()
        def job():
            update_all_nodes(nlog)
            list_nodes()
        in_background("update", nlog, job)
    nupd.on_click(on_update)
    nodes_tab = W.VBox([nurl, W.HBox([nbtn, nrestart, nupd, nrefresh]), nlist, nlog.widget])

    # ---------- Outputs tab
    olog = LogBox("160px")
    js_out = W.Output()
    oinfo = W.HTML()
    oall = W.Button(description="Download ALL", icon="download")
    onew = W.Button(description="Download NEW only", button_style="primary", icon="download")
    omark = W.Button(description="Mark all as downloaded", icon="check")

    def out_info():
        files = output_files()
        done = downloaded_set()
        new = [f for f in files if str(f) not in done]
        total = sum(f.stat().st_size for f in files)
        oinfo.value = (f"<b>{len(files)}</b> files in output (incl. subfolders), {human(total)} &nbsp;|&nbsp; "
                       f"<b>{len(new)}</b> not downloaded yet")
        return files, new
    out_info()

    def start_download(files):
        olog.clear()
        if not files:
            olog("Nothing to download.")
            return
        olog(f"Sending {len(files)} files to your browser (about 2 per second)...")
        olog("Firefox may ask once to allow multiple downloads - click Allow.")
        browser_download(files, js_out)
        with open(DOWNLOADED_LIST, "a") as fh:
            fh.write("\n".join(str(f) for f in files) + "\n")
        out_info()
    oall.on_click(lambda _: start_download(out_info()[0]))
    onew.on_click(lambda _: start_download(out_info()[1]))

    def on_mark(_):
        files, _new = out_info()
        DOWNLOADED_LIST.write_text("\n".join(str(f) for f in files) + "\n")
        out_info()
        olog("All current outputs marked as downloaded.")
    omark.on_click(on_mark)
    orefresh = W.Button(description="Refresh", icon="refresh")
    orefresh.on_click(lambda _: out_info())
    outputs_tab = W.VBox([oinfo, W.HBox([onew, oall, omark, orefresh]),
                          W.HTML("<small>Files land in your browser's normal download folder "
                                 "(subfolder names are not kept). Keep this tab open until all "
                                 "downloads have started.</small>"), olog.widget, js_out])

    # ---------- Vault tab
    vlog = LogBox()
    vb = W.Button(description="Backup now", button_style="primary", icon="cloud-upload")
    vs = W.Button(description="Status", icon="info")
    vr = W.Button(description="Restore from R2", icon="cloud-download")
    def vault_cmd(*args):
        vlog.clear()
        in_background(args[0], vlog, run_detached, ["vault", *args], vlog, args[0])
    vt = W.Button(description="Show R2 trash", icon="trash-restore")
    vtd = W.Text(placeholder="trash date, e.g. 2026-11-19_221503", layout=W.Layout(width="260px"))
    vtf = W.Dropdown(options=["all", "models", "custom_nodes", "user", "input", "jupyter"], value="all",
                     layout=W.Layout(width="130px"))
    vu = W.Button(description="Put back from trash", icon="undo")
    vt.on_click(lambda _: vault_cmd("trash"))

    def on_undelete(_):
        if not vtd.value.strip():
            vlog.clear()
            vlog("Click 'Show R2 trash', then copy a date into the box.")
            return
        args = ["undelete", vtd.value.strip()] + ([] if vtf.value == "all" else [vtf.value])
        vault_cmd(*args)
    vu.on_click(on_undelete)
    ve = W.Button(description="Delete from trash", button_style="danger", icon="trash")
    vec = W.Checkbox(value=False, description="Yes, permanently delete (date above, or ALL if empty)", indent=False)

    def on_empty(_):
        if not vec.value:
            vlog.clear()
            vlog("Tick the confirm box first. Leave the date empty to delete ALL trash.")
            return
        vec.value = False
        vault_cmd("empty-trash", vtd.value.strip() or "all", "--yes")
    ve.on_click(on_empty)
    vb.on_click(lambda _: vault_cmd("backup"))
    vs.on_click(lambda _: vault_cmd("status"))
    vr.on_click(lambda _: vault_cmd("restore"))
    # power controls: back up first, then ask Vast to stop/destroy this instance
    pstop = W.Button(description="Backup & STOP", button_style="warning", icon="pause")
    pdestroy = W.Button(description="Backup & DESTROY", button_style="danger", icon="trash")
    pquick = W.Button(description="Stop now (no backup)", icon="power-off")
    pconfirm = W.Checkbox(value=False, description="Yes, really destroy this instance", indent=False)

    def power(mode, extra=None):
        cmd = ["vault", "shutdown", mode] + ([extra] if extra else [])
        vlog.clear()
        vlog(f">>> {' '.join(cmd)} - keep this tab open until it says Vast accepted")
        in_background("shutdown", vlog, run_detached, cmd, vlog, "shutdown")

    def on_destroy(_):
        if not pconfirm.value:
            vlog("Tick 'Yes, really destroy this instance' first.")
            return
        pconfirm.value = False
        power("destroy")
    pstop.on_click(lambda _: power("stop"))
    pdestroy.on_click(on_destroy)
    pquick.on_click(lambda _: power("stop", "--no-backup"))

    # keep-awake: stops the idle watcher from shutting down while you work without queueing jobs
    kdur = W.Dropdown(options=[("1 hour", 1), ("2 hours", 2), ("4 hours", 4), ("8 hours", 8)], value=2,
                      layout=W.Layout(width="110px"))
    kbtn = W.Button(description="Keep awake", icon="coffee")
    kres = W.Button(description="Cancel keep-awake", icon="times")

    def on_keep(_):
        until = time.time() + kdur.value * 3600
        WATCH_PAUSE.write_text(str(until))
        vlog.clear()
        vlog(f"Keep-awake on: no idle shutdown until {time.strftime('%H:%M', time.localtime(until))} "
             f"(auto-backups still run).")
        header.value = header_html()

    def on_resume(_):
        WATCH_PAUSE.unlink(missing_ok=True)
        vlog.clear()
        vlog("Keep-awake cancelled: idle watcher is counting again.")
        header.value = header_html()
    kbtn.on_click(on_keep)
    kres.on_click(on_resume)

    vault_tab = W.VBox([W.HBox([vb, vs, vr]),
                        W.HTML("<small>Backup saves models, nodes, workflows, input, output and Jupyter "
                               "settings to Cloudflare R2. Restore runs automatically on new instances. "
                               "This panel shows the last 500 lines &mdash; full logs: "
                               "<a href='/files/workspace/logs/vault.log?download=1' target='_blank'>backup/restore log</a>, "
                               "<a href='/files/workspace/logs/provision.log?download=1' target='_blank'>setup log</a>"
                               "</small>"),
                        W.HTML("<hr><b>R2 trash</b> &nbsp;<small>Files a backup removed from the vault are "
                               "kept here. Put them back, then use Restore (or start a new instance).</small>"),
                        W.HBox([vt, vtd, vtf, vu]),
                        W.HBox([ve, vec]),
                        W.HTML("<hr><b>Shut down this instance</b> &nbsp;<small>STOP keeps the disk (small storage "
                               "charge, restart later on the same machine). DESTROY ends all charges; your files "
                               "are safe in R2. Destroy only runs if the backup succeeds.</small>"),
                        W.HBox([pstop, pdestroy, pconfirm]), pquick,
                        W.HTML("<hr><b>Idle watcher</b> &nbsp;<small>Shuts down after the idle time with no "
                               "ComfyUI jobs, downloads or Jupyter use. Use Keep awake while you build workflows "
                               "without running them.</small>"),
                        W.HBox([kdur, kbtn, kres]),
                        vlog.widget])

    # ---------- ComfyUI tab
    clog = LogBox()
    crestart = W.Button(description="Restart ComfyUI", button_style="warning", icon="refresh")
    ctail = W.Button(description="Show ComfyUI log", icon="file-text")
    def on_restart(_):
        clog.clear()
        def job():
            restart_comfyui(clog)
            list_nodes()   # Nodes tab shows what loaded after this restart
        in_background("restart", clog, job)
    crestart.on_click(on_restart)

    def on_tail(_):
        clog.clear()
        p = WORKSPACE / "logs" / "comfyui.log"
        if p.exists():
            clog("\n".join(p.read_text(errors="ignore").splitlines()[-80:]))
        else:
            clog("No log yet")
    ctail.on_click(on_tail)
    comfy_tab = W.VBox([W.HBox([crestart, ctail]), clog.widget])

    tabs = W.Tab(children=[models_tab, cleanup_tab, nodes_tab, outputs_tab, vault_tab, comfy_tab])
    for i, t in enumerate(["Download", "Models", "Nodes", "Outputs", "Vault", "ComfyUI"]):
        tabs.set_title(i, t)
    boot_out = W.Output()
    display(W.VBox([W.HBox([header, refresh]), tabs, boot_out]))
    with boot_out:
        display(Javascript(AUTOSCROLL_JS))
