"""
vault_menu.py  -  Jupyter control panel for ComfyUI on Vast.ai

Open /workspace/ComfyUI-Menu.ipynb in JupyterLab and run its single cell.
Tabs: Models (Hugging Face / Civitai) | Nodes (GitHub) | Outputs (browser download)
      | Vault (R2 backup/restore) | ComfyUI (restart / log)
"""
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
    """Scrolling text log that can be updated from background threads."""
    def __init__(self, height="260px"):
        self.lines = []
        self.widget = W.Textarea(layout=W.Layout(width="100%", height=height), disabled=True)

    def __call__(self, msg=""):
        for line in str(msg).rstrip("\n").split("\n"):
            self.lines.append(line)
        self.lines = self.lines[-300:]
        self.widget.value = "\n".join(self.lines)

    def clear(self):
        self.lines = []
        self.widget.value = ""


def run_cmd(cmd, log, cwd=None, hide=None, on_line=None):
    """Run a command, stream its output to the log, return exit code.
    on_line(line) may return True to swallow a line (e.g. progress updates)."""
    shown = " ".join(cmd) if isinstance(cmd, list) else cmd
    if hide:
        shown = shown.replace(hide, "***")
    log(f"$ {shown}")
    proc = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, bufsize=1, shell=isinstance(cmd, str))
    for line in proc.stdout:
        line = line.rstrip()
        if hide:
            line = line.replace(hide, "***")
        if on_line and on_line(line):
            continue
        if line:
            log(line)
    return proc.wait()


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


# ----------------------------------------------------------------------------- Outputs
def output_files():
    if not OUTPUT.exists():
        return []
    return sorted(p for p in OUTPUT.rglob("*")
                  if p.is_file() and not any(part.startswith(".") for part in p.relative_to(OUTPUT).parts))


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
        return (f"<div style='font-size:14px;line-height:1.6'>"
                f"<a href='{COMFY_URL}' target='_blank' style='font-size:16px'><b>&#9654; Open ComfyUI</b></a>"
                f" &nbsp;|&nbsp; ComfyUI: {comfy} &nbsp;|&nbsp; GPU: {gpu}<br>"
                f"Disk: {human(du.used)} used, <b>{human(du.free)} free</b> of {human(du.total)}"
                f" &nbsp;|&nbsp; Last backup: {last}</div>")
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

    # ---------- Nodes tab
    nlog = LogBox()
    nurl = W.Text(placeholder="https://github.com/user/ComfyUI-SomeNode", description="GitHub link:",
                  style=style, layout=wide)
    nrestart = W.Checkbox(value=True, description="Restart ComfyUI when done")
    nbtn = W.Button(description="Install node", button_style="primary", icon="plus")
    nupd = W.Button(description="Update all nodes", icon="sync")
    nlist = W.HTML()

    def list_nodes():
        names = sorted(p.name for p in NODES.iterdir() if p.is_dir() and not p.name.startswith((".", "__"))) \
            if NODES.exists() else []
        nlist.value = "<b>Installed:</b> " + (", ".join(names) if names else "none")
    list_nodes()

    def on_node(_):
        link = nurl.value
        if not link.strip():
            nlog("Paste a link first.")
            return
        nurl.value = ""
        def job():
            github_install(link, nrestart.value, nlog)
            list_nodes()
        in_background("node", nlog, job)
    nbtn.on_click(on_node)
    nupd.on_click(lambda _: in_background("update", nlog, update_all_nodes, nlog))
    nodes_tab = W.VBox([nurl, W.HBox([nbtn, nrestart, nupd]), nlist, nlog.widget])

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
    vb.on_click(lambda _: in_background("backup", vlog, run_cmd, ["vault", "backup"], vlog))
    vs.on_click(lambda _: in_background("status", vlog, run_cmd, ["vault", "status"], vlog))
    vr.on_click(lambda _: in_background("restore", vlog, run_cmd, ["vault", "restore"], vlog))
    # power controls: back up first, then ask Vast to stop/destroy this instance
    pstop = W.Button(description="Backup & STOP", button_style="warning", icon="pause")
    pdestroy = W.Button(description="Backup & DESTROY", button_style="danger", icon="trash")
    pquick = W.Button(description="Stop now (no backup)", icon="power-off")
    pconfirm = W.Checkbox(value=False, description="Yes, really destroy this instance", indent=False)

    def power(mode, extra=None):
        cmd = ["vault", "shutdown", mode] + ([extra] if extra else [])
        vlog(f">>> {' '.join(cmd)} - keep this tab open until it says Vast accepted")
        in_background("shutdown", vlog, run_cmd, cmd, vlog)

    def on_destroy(_):
        if not pconfirm.value:
            vlog("Tick 'Yes, really destroy this instance' first.")
            return
        pconfirm.value = False
        power("destroy")
    pstop.on_click(lambda _: power("stop"))
    pdestroy.on_click(on_destroy)
    pquick.on_click(lambda _: power("stop", "--no-backup"))

    vault_tab = W.VBox([W.HBox([vb, vs, vr]),
                        W.HTML("<small>Backup saves models, nodes, workflows, input, output and Jupyter "
                               "settings to Cloudflare R2. Restore runs automatically on new instances.</small>"),
                        W.HTML("<hr><b>Shut down this instance</b> &nbsp;<small>STOP keeps the disk (small storage "
                               "charge, restart later on the same machine). DESTROY ends all charges; your files "
                               "are safe in R2. Destroy only runs if the backup succeeds.</small>"),
                        W.HBox([pstop, pdestroy, pconfirm]), pquick,
                        vlog.widget])

    # ---------- ComfyUI tab
    clog = LogBox()
    crestart = W.Button(description="Restart ComfyUI", button_style="warning", icon="refresh")
    ctail = W.Button(description="Show ComfyUI log", icon="file-text")
    crestart.on_click(lambda _: in_background("restart", clog, restart_comfyui, clog))

    def on_tail(_):
        clog.clear()
        p = WORKSPACE / "logs" / "comfyui.log"
        if p.exists():
            clog("\n".join(p.read_text(errors="ignore").splitlines()[-80:]))
        else:
            clog("No log yet")
    ctail.on_click(on_tail)
    comfy_tab = W.VBox([W.HBox([crestart, ctail]), clog.widget])

    tabs = W.Tab(children=[models_tab, nodes_tab, outputs_tab, vault_tab, comfy_tab])
    for i, t in enumerate(["Models", "Nodes", "Outputs", "Vault", "ComfyUI"]):
        tabs.set_title(i, t)
    display(W.VBox([W.HBox([header, refresh]), tabs]))
