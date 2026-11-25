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

# ComfyUI-Vault Docker image? (ghcr.io/twfrick/vast-comfyui) - it has ComfyUI, requirements,
# default nodes and SageAttention 2 pre-installed, so most steps below finish in seconds.
IMAGE_DIR="/opt/comfyui-image"
IN_IMAGE=0
if [ -f "$IMAGE_DIR/IMAGE_INFO" ] && [ -d "$IMAGE_DIR/ComfyUI/.git" ]; then
    IN_IMAGE=1
    echo "ComfyUI-Vault image detected:"
    sed 's/^/    /' "$IMAGE_DIR/IMAGE_INFO"
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
# get_comfy <dest>: copy from the image (seconds) or clone from GitHub
get_comfy() {
    if [ "$IN_IMAGE" = "1" ]; then
        echo "Copying ComfyUI from the image"
        cp -a "$IMAGE_DIR/ComfyUI" "$1"
    else
        git clone https://github.com/comfyanonymous/ComfyUI.git "$1"
    fi
}
if [ -d "$COMFY_DIR/.git" ]; then
    echo "ComfyUI already installed - updating"
    git -C "$COMFY_DIR" pull --ff-only || echo "WARNING: update failed, keeping current version"
elif [ -d "$COMFY_DIR" ] && [ -n "$(ls -A "$COMFY_DIR" 2>/dev/null)" ]; then
    # Folder already has files (e.g. a model downloaded from the menu before ComfyUI was installed):
    # get a fresh copy next to it and merge it in without overwriting anything that is already there.
    echo "ComfyUI folder already has files - merging a fresh copy in"
    rm -rf "$COMFY_DIR.clone"
    get_comfy "$COMFY_DIR.clone"
    cp -an "$COMFY_DIR.clone/." "$COMFY_DIR/"
    rm -rf "$COMFY_DIR.clone"
    [ "$IN_IMAGE" = "1" ] && { git -C "$COMFY_DIR" pull --ff-only || echo "WARNING: update failed, keeping the image's version"; }
else
    get_comfy "$COMFY_DIR"
    [ "$IN_IMAGE" = "1" ] && { git -C "$COMFY_DIR" pull --ff-only || echo "WARNING: update failed, keeping the image's version"; }
fi
git -C "$COMFY_DIR" log -1 --format="ComfyUI version: %h (%cd)" --date=short

# -----------------------------------------------------------------------------
step "4/6 PyTorch (TORCH_CUDA=${TORCH_CUDA:-cu128})"
# Template setting TORCH_CUDA:
#   cu128 (default) - CUDA 12.8 build, works on every host with Max CUDA >= 12.8
#   cu130           - CUDA 13.0 build, needs Max CUDA >= 13.0; falls back to cu128 if the host is too old
#   auto            - cu130 on Blackwell GPUs (RTX 50xx / RTX PRO) when the driver allows it, otherwise cu128
if command -v uv >/dev/null 2>&1; then
    PIP_UNINSTALL=(uv pip uninstall --python "$PY")
else
    PIP_UNINSTALL=("$PY" -m pip uninstall -y)
fi

ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # ver_ge A B  ->  A >= B

# These lookups must never stop the script: an empty result just means "unknown" (-> cu128)
SMI_OUT="$(nvidia-smi 2>&1 || true)"
DRIVER_CUDA="$(printf '%s\n' "$SMI_OUT" | sed -nE 's/.*CUDA Version: *([0-9]+\.[0-9]+).*/\1/p' | head -1 || true)"
GPU_CC="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || true)"
[[ "$GPU_CC" =~ ^[0-9]+\.[0-9]+$ ]] || GPU_CC=""
echo "Host driver supports CUDA ${DRIVER_CUDA:-unknown} | GPU compute capability ${GPU_CC:-unknown}"
if [ -z "$DRIVER_CUDA" ]; then
    echo "WARNING: could not read the CUDA version from nvidia-smi. Its output was:"
    printf '%s\n' "$SMI_OUT" | head -12
fi

WANT="${TORCH_CUDA:-cu128}"
case "$WANT" in
    cu128|cu130) ;;
    auto)
        if [ -n "$GPU_CC" ] && ver_ge "$GPU_CC" "12.0" && [ -n "$DRIVER_CUDA" ] && ver_ge "$DRIVER_CUDA" "13.0"; then
            WANT=cu130; echo "auto: Blackwell GPU + CUDA 13 driver -> cu130"
        else
            WANT=cu128; echo "auto: using cu128"
        fi ;;
    *) echo "WARNING: unknown TORCH_CUDA='$WANT' - using cu128"; WANT=cu128 ;;
esac
if [ "$WANT" = "cu130" ] && { [ -z "$DRIVER_CUDA" ] || ! ver_ge "$DRIVER_CUDA" "13.0"; }; then
    echo "WARNING: TORCH_CUDA=cu130 but this host only supports CUDA ${DRIVER_CUDA:-unknown} - using cu128 instead"
    WANT=cu128
fi
WANT_MIN="12.8"; [ "$WANT" = "cu130" ] && WANT_MIN="13.0"

# Prints the torch CUDA version if torch works on the GPU, otherwise "bad"
torch_cuda() {
"$PY" - <<'EOF' 2>/dev/null || echo bad
import torch, torchvision, torchaudio
torch.zeros(1).cuda()
print(torch.version.cuda or "bad")
EOF
}
torch_matches() {   # current torch fits the wanted build?
    local c; c="$(torch_cuda | tail -1)"
    [ "$c" != "bad" ] || return 1
    ver_ge "$c" "$WANT_MIN" || return 1
    [ "$WANT" = "cu130" ] || ! ver_ge "$c" "13.0"   # cu128 wanted -> do not keep a 13.x build
}
install_torch() {   # install_torch cu128|cu130
    echo "Installing PyTorch $1 build (a few minutes)..."
    "${PIP_UNINSTALL[@]}" torch torchvision torchaudio >/dev/null 2>&1 || true
    "${PIP[@]}" torch torchvision torchaudio --index-url "https://download.pytorch.org/whl/$1"
}

if torch_matches; then
    echo "Image PyTorch already fits $WANT - keeping it"
else
    install_torch "$WANT" || echo "WARNING: PyTorch $WANT install failed"
    if ! torch_matches && [ "$WANT" = "cu130" ]; then
        echo "WARNING: PyTorch cu130 does not work on this host - falling back to cu128"
        WANT=cu128; WANT_MIN="12.8"
        install_torch cu128
    fi
fi
"$PY" -c "import torch; torch.zeros(1).cuda(); print('torch', torch.__version__, '| CUDA', torch.version.cuda, '| GPU:', torch.cuda.get_device_name(0))" \
    || fail "PyTorch cannot use the GPU. Rent a host with Max CUDA 12.8 or higher."
echo "$WANT" > "$WORKSPACE/.torch-build"

# Lock the working torch versions so nothing below can replace them
CONSTRAINTS="$WORKSPACE/.torch-constraints.txt"
"$PY" - > "$CONSTRAINTS" <<'EOF'
import importlib.metadata as m
for p in ("torch", "torchvision", "torchaudio"):
    print(f"{p}=={m.version(p)}")
EOF
echo "Locked: $(tr '\n' ' ' < "$CONSTRAINTS")"

# SageAttention (faster attention for KJNodes "Patch Sage Attention", MiniMax/WAN video, SeedVR2, ...)
# Template setting SAGEATTENTION:
#   1 = make sure SageAttention 2 works on this GPU (default with the ComfyUI-Vault image):
#       keeps the image's copy if it works, otherwise compiles it for this GPU (a few minutes)
#   0 = leave it alone (default with the plain vastai/pytorch image)
SAGE_DEFAULT=0; [ "$IN_IMAGE" = "1" ] && SAGE_DEFAULT=1
# Prints "ok <version>" if SageAttention runs a real attention call on this GPU, else "bad <reason>"
sage_check() {
"$PY" - <<'EOF' 2>/dev/null || echo "bad not-installed-or-broken"
import importlib.metadata as m
import torch
v = m.version("sageattention")
from sageattention import sageattn
q = torch.randn(1, 2, 128, 64, dtype=torch.float16, device="cuda")
out = sageattn(q, q, q, tensor_layout="HND", is_causal=False)
torch.cuda.synchronize()
print("ok" if out.shape == q.shape else "bad wrong-output", v)
EOF
}
sage_v2() { [ "${1%%.*}" -ge 2 ] 2>/dev/null; }
if [ "${SAGEATTENTION:-$SAGE_DEFAULT}" = "1" ]; then
    read -r SAGE_STATE SAGE_VER < <(sage_check | tail -1) || true
    if [ "${SAGE_STATE:-}" = "ok" ] && sage_v2 "${SAGE_VER:-0}"; then
        echo "SageAttention $SAGE_VER works on this GPU"
    else
        echo "SageAttention 2 not usable here (${SAGE_STATE:-bad} ${SAGE_VER:-}) - compiling it for this GPU (a few minutes)..."
        CC="$("$PY" -c "import torch; a,b=torch.cuda.get_device_capability(0); print(f'{a}.{b}')" 2>/dev/null || true)"
        SAGE_TMP="$(mktemp -d)"
        if [ -n "$CC" ] && [ -x /usr/local/cuda/bin/nvcc ] \
           && "${PIP[@]}" ninja packaging wheel setuptools >/dev/null \
           && git clone --depth 1 https://github.com/thu-ml/SageAttention.git "$SAGE_TMP/sage" \
           && (cd "$SAGE_TMP/sage" && CUDA_HOME=/usr/local/cuda PATH="/usr/local/cuda/bin:$PATH" \
                 TORCH_CUDA_ARCH_LIST="$CC" MAX_JOBS="$(nproc)" EXT_PARALLEL=4 NVCC_APPEND_FLAGS="--threads 8" \
                 "$PY" -m pip install --no-build-isolation --no-deps -c "$CONSTRAINTS" .); then
            read -r SAGE_STATE SAGE_VER < <(sage_check | tail -1) || true
        else
            SAGE_STATE=bad
        fi
        rm -rf "$SAGE_TMP"
        if [ "${SAGE_STATE:-}" = "ok" ]; then
            echo "SageAttention $SAGE_VER compiled and working"
        else
            echo "WARNING: SageAttention 2 could not be built - installing version 1 (works with most nodes)"
            "${PIP[@]}" -c "$CONSTRAINTS" "sageattention==1.0.6" || echo "WARNING: SageAttention install failed - ComfyUI still works without it"
        fi
    fi
fi

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
# Extra ComfyUI options from the template, e.g. COMFYUI_ARGS="--reserve-vram 1"
COMFYUI_ARGS="\$(envval COMFYUI_ARGS)"
echo "ComfyUI extra options: \${COMFYUI_ARGS:-none}"
cd $COMFY_DIR
# --enable-cors-header: ComfyUI sits behind Vast's proxy, so the browser's address
# differs from 127.0.0.1 - without this, saving workflows fails with 403 Forbidden.
exec python main.py --listen 127.0.0.1 --port $COMFY_PORT --enable-cors-header $MANAGER_FLAGS \$COMFYUI_ARGS
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
