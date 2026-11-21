#!/usr/bin/env bash
# =============================================================================
# install_comfyui.sh  -  Install or update ComfyUI on a Vast.ai instance
#
#  * Installs ComfyUI into /workspace/ComfyUI
#  * Makes sure PyTorch is a CUDA 12.8+ build (RTX 6000 Ada / 4090 / 5090 / A6000)
#  * Enables the built-in ComfyUI-Manager (new UI; MANAGER_UI=legacy for the old window)
#  * Runs ComfyUI as a background service that restarts itself if it crashes
#
#  Safe to run again at any time: it only does what is missing / updates.
#  Log: /workspace/logs/install_comfyui.log
# =============================================================================
set -Eeuo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY_DIR="$WORKSPACE/ComfyUI"
VENV="/venv/main"
PY="$VENV/bin/python"
LOG_DIR="$WORKSPACE/logs"
COMFY_PORT=18188            # internal port; Vast's portal serves it on 8188

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/install_comfyui.log") 2>&1

step() { echo; echo "==== $* ===="; }
fail() { echo; echo "ERROR: $*"; exit 1; }
trap 'echo; echo "ERROR on line $LINENO. Full log: $LOG_DIR/install_comfyui.log"' ERR

echo "install_comfyui.sh started $(date)"

# -----------------------------------------------------------------------------
step "1/6 Python environment"
[ -x "$PY" ] || fail "No Python found at $PY - the template image must be vastai/pytorch."
"$PY" --version
if command -v uv >/dev/null 2>&1; then
    PIP=(uv pip install --python "$PY")
    echo "Using uv (fast installer)"
else
    PIP=("$PY" -m pip install)
    echo "Using pip"
fi

# -----------------------------------------------------------------------------
step "2/6 System packages"
PKGS=""
command -v git    >/dev/null 2>&1 || PKGS+=" git"
command -v ffmpeg >/dev/null 2>&1 || PKGS+=" ffmpeg"
command -v aria2c >/dev/null 2>&1 || PKGS+=" aria2"
dpkg -s libgl1        >/dev/null 2>&1 || PKGS+=" libgl1"
dpkg -s libglib2.0-0  >/dev/null 2>&1 || PKGS+=" libglib2.0-0"
if [ -n "$PKGS" ]; then
    echo "Installing:$PKGS"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $PKGS </dev/null
else
    echo "All system packages already present"
fi

# -----------------------------------------------------------------------------
step "3/6 ComfyUI source"
if [ -d "$COMFY_DIR/.git" ]; then
    echo "ComfyUI already installed - updating"
    git -C "$COMFY_DIR" pull --ff-only || echo "WARNING: update failed, keeping current version"
elif [ -d "$COMFY_DIR" ] && [ -n "$(ls -A "$COMFY_DIR" 2>/dev/null)" ]; then
    # Folder already has files (e.g. a model downloaded from the menu before ComfyUI was installed):
    # clone next to it and merge in without overwriting anything that is already there.
    echo "ComfyUI folder already has files - merging a fresh copy in"
    rm -rf "$COMFY_DIR.clone"
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR.clone"
    cp -an "$COMFY_DIR.clone/." "$COMFY_DIR/"
    rm -rf "$COMFY_DIR.clone"
else
    git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
fi
git -C "$COMFY_DIR" log -1 --format="ComfyUI version: %h (%cd)" --date=short

# -----------------------------------------------------------------------------
step "4/6 PyTorch (needs CUDA 12.8 or newer)"
torch_ok() {
"$PY" - <<'EOF' 2>/dev/null
import torch, torchvision, torchaudio
maj, mi = (int(x) for x in (torch.version.cuda or "0.0").split(".")[:2])
print("yes" if (maj, mi) >= (12, 8) and torch.cuda.is_available() else "no")
EOF
}
if [ "$(torch_ok || true)" != "yes" ]; then
    echo "Installing PyTorch CUDA 12.8 build (a few minutes)..."
    "${PIP[@]}" torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128
fi
"$PY" -c "import torch; print('torch', torch.__version__, '| CUDA', torch.version.cuda, '| GPU:', torch.cuda.get_device_name(0))" \
    || fail "PyTorch cannot see the GPU. Rent a host with Max CUDA 12.8 or higher."

# Lock the working torch versions so nothing below can replace them
CONSTRAINTS="$WORKSPACE/.torch-constraints.txt"
"$PY" - > "$CONSTRAINTS" <<'EOF'
import importlib.metadata as m
for p in ("torch", "torchvision", "torchaudio"):
    print(f"{p}=={m.version(p)}")
EOF
echo "Locked: $(tr '\n' ' ' < "$CONSTRAINTS")"

# -----------------------------------------------------------------------------
step "5/6 ComfyUI + Manager requirements"
"${PIP[@]}" -c "$CONSTRAINTS" -r "$COMFY_DIR/requirements.txt"
MANAGER_FLAGS=""
LEGACY_ENV=""
if [ -f "$COMFY_DIR/manager_requirements.txt" ]; then
    "${PIP[@]}" -c "$CONSTRAINTS" -r "$COMFY_DIR/manager_requirements.txt"
    # New Manager (default): works with the "Install missing nodes" buttons in ComfyUI.
    # Set env MANAGER_UI=legacy for the old Manager window (those buttons then stop working).
    if [ "${MANAGER_UI:-new}" = "legacy" ]; then
        MANAGER_FLAGS="--enable-manager --enable-manager-legacy-ui"
        LEGACY_ENV="export ENABLE_LEGACY_COMFYUI_MANAGER_FRONT=true"
        echo "ComfyUI-Manager enabled (legacy UI)"
    else
        MANAGER_FLAGS="--enable-manager"
        echo "ComfyUI-Manager enabled (new UI)"
    fi
else
    echo "WARNING: manager_requirements.txt not found - Manager not enabled"
fi
mkdir -p "$COMFY_DIR/user/default/workflows" "$COMFY_DIR/output" "$COMFY_DIR/input"

# Always-installed nodes: server-side model downloads
#   ComfyUI-RunpodDirect -> "Download to Pod" button in the Missing Models dialog
#   Civicomfy            -> search + download Civitai models inside ComfyUI
DEFAULT_NODES="https://github.com/MadiatorLabs/ComfyUI-RunpodDirect https://github.com/MoonGoblinDev/Civicomfy"
for url in $DEFAULT_NODES; do
    dir="$COMFY_DIR/custom_nodes/$(basename "$url")"
    if [ ! -d "$dir" ]; then
        echo "Adding node: $(basename "$url")"
        git clone --depth 1 "$url.git" "$dir" || { echo "WARNING: could not clone $url"; continue; }
    fi
    if [ -f "$dir/requirements.txt" ]; then
        "${PIP[@]}" -c "$CONSTRAINTS" -r "$dir/requirements.txt" || echo "WARNING: requirements failed for $(basename "$url")"
    fi
done

# Activity reporter for the idle watcher: clicking/typing/moving windows in ComfyUI counts as "in use"
VA="$COMFY_DIR/custom_nodes/ComfyUI-VaultActivity"
mkdir -p "$VA/web"
cat > "$VA/__init__.py" <<'VAEOF'
"""
ComfyUI-VaultActivity - tells the idle watcher that someone is using ComfyUI.

The browser part (web/vault_activity.js) pings /vault/activity at most every 30 s while
you click, type, scroll or move the mouse in ComfyUI. Each ping updates the time stamp of
/workspace/.comfy_activity, which the idle watcher treats as "in use".
An open but untouched ComfyUI tab sends nothing, so idle shutdown still works.
"""
import os
import time

from aiohttp import web
from server import PromptServer

MARK = os.path.join(os.environ.get("WORKSPACE", "/workspace"), ".comfy_activity")


@PromptServer.instance.routes.post("/vault/activity")
async def vault_activity(request):
    try:
        with open(MARK, "a"):
            pass
        os.utime(MARK, None)
    except OSError:
        pass
    return web.json_response({"ok": True, "t": time.time()})


NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
WEB_DIRECTORY = "./web"
__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS", "WEB_DIRECTORY"]
VAEOF
cat > "$VA/web/vault_activity.js" <<'VAEOF'
// Tells the idle watcher you are using ComfyUI (editing, saving, switching tabs, moving windows).
import { app } from "../../scripts/app.js";

const EVERY_MS = 30000;
let last = 0;

function ping() {
  const now = Date.now();
  if (now - last < EVERY_MS) return;
  last = now;
  // relative URL: works at the site root (tunnel) and behind Vast's portal
  fetch(new URL("vault/activity", window.location.origin + window.location.pathname.replace(/[^/]*$/, "")),
        { method: "POST", keepalive: true }).catch(() => {});
}

app.registerExtension({
  name: "vault.activity",
  setup() {
    for (const ev of ["pointerdown", "pointermove", "keydown", "wheel", "touchstart"]) {
      window.addEventListener(ev, ping, { passive: true, capture: true });
    }
    ping();
  },
});
VAEOF
echo "Added ComfyUI-VaultActivity (tells the idle watcher when you use ComfyUI)"

# -----------------------------------------------------------------------------
step "6/6 ComfyUI service"
mkdir -p /opt/supervisor-scripts
cat > /opt/supervisor-scripts/comfyui.sh <<EOF
#!/bin/bash
# Started by supervisor. Extra ComfyUI options can be set in the COMFYUI_ARGS env var.
source $VENV/bin/activate
$LEGACY_ENV
# Tokens for download nodes (Vast account env vars; fall back to /etc/environment)
envval() { [ -n "\${!1:-}" ] && echo "\${!1}" || grep -m1 "^\$1=" /etc/environment 2>/dev/null | cut -d= -f2- | sed 's/^"//; s/"\$//'; }
export HF_TOKEN="\$(envval HF_TOKEN)"
export CIVITAI_TOKEN="\$(envval CIVITAI_TOKEN)"
export CIVITAI_API_KEY="\${CIVITAI_API_KEY:-\$CIVITAI_TOKEN}"
cd $COMFY_DIR
# --enable-cors-header: ComfyUI sits behind Vast's proxy, so the browser's address
# differs from 127.0.0.1 - without this, saving workflows fails with 403 Forbidden.
exec python main.py --listen 127.0.0.1 --port $COMFY_PORT --enable-cors-header $MANAGER_FLAGS \${COMFYUI_ARGS:-}
EOF
chmod +x /opt/supervisor-scripts/comfyui.sh

supervisor_running() {
    command -v supervisorctl >/dev/null 2>&1 && [ -d /etc/supervisor/conf.d ] \
        && supervisorctl pid 2>/dev/null | grep -qE '^[0-9]+$'
}

start_with_supervisor() {
    cat > /etc/supervisor/conf.d/comfyui.conf <<EOF
[program:comfyui]
command=/opt/supervisor-scripts/comfyui.sh
environment=PROC_NAME="%(program_name)s"
autostart=true
autorestart=true
startsecs=5
stopasgroup=true
killasgroup=true
stdout_logfile=$LOG_DIR/comfyui.log
stdout_logfile_maxbytes=20MB
stdout_logfile_backups=2
redirect_stderr=true
EOF
    supervisorctl reread  || return 1
    supervisorctl update  || return 1
    supervisorctl restart comfyui || return 1
    echo "ComfyUI service registered with supervisor"
}

start_in_background() {
    echo "Starting ComfyUI as a background process instead"
    rm -f /etc/supervisor/conf.d/comfyui.conf
    pkill -f "main.py --listen 127.0.0.1 --port $COMFY_PORT" || true
    sleep 1
    nohup setsid /opt/supervisor-scripts/comfyui.sh >> "$LOG_DIR/comfyui.log" 2>&1 < /dev/null &
}

if supervisor_running; then
    start_with_supervisor || { echo "WARNING: supervisor did not accept the service"; start_in_background; }
else
    echo "Supervisor is not running on this instance"
    start_in_background
fi

echo "Waiting for ComfyUI to start (first start can take 1-2 minutes)..."
for i in $(seq 1 90); do
    if curl -fs "http://127.0.0.1:$COMFY_PORT/system_stats" >/dev/null 2>&1; then
        echo
        echo "=============================================="
        echo " SUCCESS: ComfyUI is running (port $COMFY_PORT)"
        echo "=============================================="
        if grep -qs "$COMFY_PORT" /etc/portal.yaml; then
            echo "Open it from the Instance Portal -> ComfyUI"
        else
            echo "NOTE: ComfyUI is not in the Instance Portal yet (template PORTAL_CONFIG)."
        fi
        exit 0
    fi
    sleep 2
done
echo
tail -n 40 "$LOG_DIR/comfyui.log" || true
fail "ComfyUI did not start within 3 minutes. The last log lines are shown above."
