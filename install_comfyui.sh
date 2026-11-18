#!/usr/bin/env bash
# =============================================================================
# install_comfyui.sh  -  Install or update ComfyUI on a Vast.ai instance
#
#  * Installs ComfyUI into /workspace/ComfyUI
#  * Makes sure PyTorch is a CUDA 12.8+ build (RTX 6000 Ada / 4090 / 5090 / A6000)
#  * Enables the built-in ComfyUI-Manager (legacy UI = includes Model Manager)
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
if [ -f "$COMFY_DIR/manager_requirements.txt" ]; then
    "${PIP[@]}" -c "$CONSTRAINTS" -r "$COMFY_DIR/manager_requirements.txt"
    MANAGER_FLAGS="--enable-manager --enable-manager-legacy-ui"
    echo "ComfyUI-Manager enabled (legacy UI, includes Model Manager)"
else
    echo "WARNING: manager_requirements.txt not found - Manager not enabled"
fi
mkdir -p "$COMFY_DIR/user/default/workflows" "$COMFY_DIR/output" "$COMFY_DIR/input"

# -----------------------------------------------------------------------------
step "6/6 ComfyUI service"
mkdir -p /opt/supervisor-scripts
cat > /opt/supervisor-scripts/comfyui.sh <<EOF
#!/bin/bash
# Started by supervisor. Extra ComfyUI options can be set in the COMFYUI_ARGS env var.
source $VENV/bin/activate
# Legacy Manager UI = "Manager" button with Model Manager (downloads models to the server)
export ENABLE_LEGACY_COMFYUI_MANAGER_FRONT=true
cd $COMFY_DIR
exec python main.py --listen 127.0.0.1 --port $COMFY_PORT $MANAGER_FLAGS \${COMFYUI_ARGS:-}
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
