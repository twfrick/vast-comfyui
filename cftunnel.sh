#!/usr/bin/env bash
# =============================================================================
# cftunnel.sh  -  Fixed web addresses through your Cloudflare Tunnel
#
#   * Starts your own JupyterLab (always opens in Lab, settings saved in
#     /workspace/.jupyter, which vault backs up) on 127.0.0.1:18888
#   * Starts the setup status page (127.0.0.1:18999)
#   * Starts cloudflared with your tunnel token, so your Cloudflare hostnames
#     (e.g. comfy.yourdomain.com, lab.yourdomain.com) reach this instance
#
#   Needs Vast account env var: CF_TUNNEL_TOKEN   (skips quietly if missing)
#   Safe to re-run. Log: /workspace/logs/cftunnel_setup.log
# =============================================================================
set -Eeuo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
LOG_DIR="$WORKSPACE/logs"
VENV="/venv/main"
CLOUDFLARED="/opt/vault/cloudflared"
LAB_PORT=18888
mkdir -p "$LOG_DIR" /opt/vault /opt/supervisor-scripts
exec > >(tee -a "$LOG_DIR/cftunnel_setup.log") 2>&1
trap 'echo "ERROR on line $LINENO - see $LOG_DIR/cftunnel_setup.log"' ERR
echo "===== cftunnel setup $(date) ====="

envval() {  # read a variable from the environment, or from /etc/environment
    local k="$1"
    if [ -n "${!k:-}" ]; then echo "${!k}"; return; fi
    grep -m1 "^$k=" /etc/environment 2>/dev/null | cut -d= -f2- | sed 's/^"//; s/"$//' || true
}

command -v supervisorctl >/dev/null 2>&1 && supervisorctl pid 2>/dev/null | grep -qE '^[0-9]+$' \
    || { echo "ERROR: supervisor is not running"; exit 1; }

# ---------------------------------------------------------------- JupyterLab
echo "--- JupyterLab (port $LAB_PORT)"
if ! "$VENV/bin/python" -c "import jupyterlab, ipywidgets" 2>/dev/null; then
    if command -v uv >/dev/null 2>&1; then uv pip install --python "$VENV/bin/python" jupyterlab ipywidgets
    else "$VENV/bin/python" -m pip install jupyterlab ipywidgets; fi
fi
# The notebook kernel may be the system Python - give it ipywidgets too (menu needs only that)
if [ -x /usr/bin/python3 ] && ! /usr/bin/python3 -c "import ipywidgets" 2>/dev/null; then
    /usr/bin/python3 -m pip install -q --break-system-packages ipywidgets 2>/dev/null \
        || echo "NOTE: could not add ipywidgets to system Python"
fi
mkdir -p "$WORKSPACE/.jupyter/lab/user-settings" "$WORKSPACE/.jupyter/lab/workspaces"
# Stop JupyterLab jumping to the top of the notebook when the menu's logs update
LABSET="$VENV/share/jupyter/lab/settings"
mkdir -p "$LABSET"
cat > "$LABSET/overrides.json" <<'EOF'
{
  "@jupyterlab/notebook-extension:tracker": { "windowingMode": "none" }
}
EOF

cat > /opt/supervisor-scripts/labvault.sh <<EOF
#!/bin/bash
# Private JupyterLab: only reachable through the Cloudflare Tunnel (protected by Cloudflare Access)
source $VENV/bin/activate
export JUPYTERLAB_SETTINGS_DIR=$WORKSPACE/.jupyter/lab/user-settings
export JUPYTERLAB_WORKSPACES_DIR=$WORKSPACE/.jupyter/lab/workspaces
export SHELL=/bin/bash
cd $WORKSPACE
exec jupyter lab --no-browser --allow-root --ip=127.0.0.1 --port=$LAB_PORT \\
    --IdentityProvider.token= --ServerApp.password= \\
    --ServerApp.allow_remote_access=True --ServerApp.allow_origin='*' --ServerApp.trust_xheaders=True \\
    --ServerApp.root_dir=/ --ServerApp.preferred_dir=$WORKSPACE --ServerApp.default_url=/lab
EOF
chmod +x /opt/supervisor-scripts/labvault.sh

# ---------------------------------------------------------------- services helper
write_conf() {   # name
    cat > "/etc/supervisor/conf.d/$1.conf" <<EOF
[program:$1]
command=/opt/supervisor-scripts/$1.sh
autostart=true
autorestart=true
startsecs=5
stopasgroup=true
killasgroup=true
stdout_logfile=$LOG_DIR/$1.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=1
redirect_stderr=true
EOF
}

# ---------------------------------------------------------------- status page
cat > /opt/supervisor-scripts/statuspage.sh <<'EOF'
#!/bin/bash
# "Is my instance ready?" page on 127.0.0.1:18999 (reach it via the tunnel: status.<your domain>)
exec /usr/bin/python3 /opt/vault/statuspage.py
EOF
chmod +x /opt/supervisor-scripts/statuspage.sh

# Start JupyterLab + status page now (before any slow download)
write_conf labvault
[ -f /opt/vault/statuspage.py ] && write_conf statuspage
supervisorctl reread
supervisorctl update
supervisorctl restart labvault
if [ -f /opt/vault/statuspage.py ]; then supervisorctl restart statuspage; fi

# ---------------------------------------------------------------- cloudflared
TOKEN="$(envval CF_TUNNEL_TOKEN)"
if [ -z "$TOKEN" ]; then
    echo "CF_TUNNEL_TOKEN not set - tunnel skipped (add it in Vast: Account > Settings > Environment Variables)"
elif [ ! -x "$CLOUDFLARED" ]; then
    echo "--- Installing cloudflared"
    # 1) GitHub release - give up quickly if the host's GitHub download is crawling
    if curl -fsSL --connect-timeout 15 --speed-limit 300000 --speed-time 15 --max-time 180 \
            -o "$CLOUDFLARED.tmp" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64; then
        mv "$CLOUDFLARED.tmp" "$CLOUDFLARED"; chmod +x "$CLOUDFLARED"
        echo "cloudflared from GitHub"
    else
        rm -f "$CLOUDFLARED.tmp"
        # 2) Cloudflare's own package repository (served by Cloudflare's network)
        echo "GitHub download too slow/failed - trying pkg.cloudflare.com"
        mkdir -p --mode=0755 /usr/share/keyrings
        if curl -fsSL --max-time 60 https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg \
           && echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
                > /etc/apt/sources.list.d/cloudflared.list \
           && timeout 300 apt-get update -qq -o Dir::Etc::sourcelist=sources.list.d/cloudflared.list \
                -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 \
           && DEBIAN_FRONTEND=noninteractive timeout 300 apt-get install -y -qq cloudflared </dev/null \
           && [ -x /usr/bin/cloudflared ]; then
            ln -sf /usr/bin/cloudflared "$CLOUDFLARED"
            echo "cloudflared from pkg.cloudflare.com"
        else
            echo "ERROR: could not install cloudflared - tunnel skipped"
            TOKEN=""
        fi
    fi
fi
if [ -n "$TOKEN" ]; then
    "$CLOUDFLARED" --version
    cat > /opt/supervisor-scripts/cftunnel.sh <<'EOF'
#!/bin/bash
# Token: /opt/vault/cf_token (manual override) > CF_TUNNEL_TOKEN env > /etc/environment
if [ -s /opt/vault/cf_token ]; then
    TOKEN=$(cat /opt/vault/cf_token)
else
    TOKEN="${CF_TUNNEL_TOKEN:-$(grep -m1 '^CF_TUNNEL_TOKEN=' /etc/environment | cut -d= -f2- | sed 's/^"//; s/"$//')}"
fi
TOKEN=$(printf '%s' "$TOKEN" | tr -d " \r\n\"'")
exec /opt/vault/cloudflared tunnel --no-autoupdate run --token "$TOKEN"
EOF
    chmod +x /opt/supervisor-scripts/cftunnel.sh
    write_conf cftunnel
    supervisorctl reread
    supervisorctl update
    supervisorctl restart cftunnel
fi

# ---------------------------------------------------------------- check
echo "--- Checking"
ok_lab=no; ok_tun=no
for i in $(seq 1 30); do
    curl -fs -o /dev/null "http://127.0.0.1:$LAB_PORT/lab" && ok_lab=yes
    grep -qs "Registered tunnel connection" "$LOG_DIR/cftunnel.log" && ok_tun=yes
    [ "$ok_lab" = yes ] && { [ "$ok_tun" = yes ] || [ -z "$TOKEN" ]; } && break
    sleep 2
done
echo "JupyterLab running:         $ok_lab"
[ -n "$TOKEN" ] && echo "Cloudflare tunnel connected: $ok_tun"
if [ "$ok_lab" = yes ] && { [ "$ok_tun" = yes ] || [ -z "$TOKEN" ]; }; then
    echo "===== cftunnel setup OK ====="
else
    echo "Last tunnel log lines:"; tail -n 15 "$LOG_DIR/cftunnel.log" 2>/dev/null || true
    echo "===== cftunnel setup had problems (see above) ====="
    exit 1
fi
