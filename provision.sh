#!/usr/bin/env bash
# =============================================================================
# provision.sh  -  Runs automatically on every new Vast.ai instance
#                  (template env var PROVISIONING_SCRIPT points here)
#
#   1. Downloads the latest scripts from GitHub into /opt/vault
#   2. Installs / updates ComfyUI           (install_comfyui.sh)
#   3. Sets up R2 and restores your vault   (vault.sh setup + restore)
#
# Log: /workspace/logs/provision.log
# =============================================================================
set -Eeuo pipefail

REPO="${VAULT_REPO:-twfrick/vast-comfyui}"   # GitHub user/repo with the scripts
BRANCH="${VAULT_BRANCH:-main}"
DEST="/opt/vault"
FILES="statuspage.py cftunnel.sh install_comfyui.sh vault.sh vault_menu.py ComfyUI-Menu.ipynb watcher.py"

mkdir -p "$DEST" /workspace/logs
exec > >(tee -a /workspace/logs/provision.log) 2>&1
trap 'echo "PROVISION FAILED on line $LINENO - see /workspace/logs/provision.log"' ERR
stage() { echo; echo "===== $* ===== [t=$(date +%s)]"; }
stage "PROVISION started $(date)"

# Load account env vars if the provisioner didn't pass them through
if [ -z "${R2_BUCKET:-}" ] && [ -f /etc/environment ]; then
    for k in HF_TOKEN CIVITAI_TOKEN GITHUB_TOKEN CF_TUNNEL_TOKEN R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
        v=$(grep -m1 "^$k=" /etc/environment | cut -d= -f2- | sed 's/^"//; s/"$//' || true)
        [ -n "$v" ] && export "$k=$v"
    done
fi

REQUIRED="cftunnel.sh install_comfyui.sh vault.sh"   # setup can't work without these
fetch() {   # GitHub API = always the newest file (no raw cache). Token avoids rate limits.
    local f="$1" url="https://api.github.com/repos/$REPO/contents/$1?ref=$BRANCH"
    if { [ -n "${GITHUB_TOKEN:-}" ] && curl -fsSL -H "Accept: application/vnd.github.raw" \
            -H "Authorization: Bearer $GITHUB_TOKEN" "$url" -o "$DEST/$f.new" 2>/dev/null; } \
       || curl -fsSL --retry 3 -H "Accept: application/vnd.github.raw" "$url" -o "$DEST/$f.new"; then
        mv -f "$DEST/$f.new" "$DEST/$f"; chmod +x "$DEST/$f"
        echo "Downloaded $f"
        return 0
    fi
    rm -f "$DEST/$f.new"
    return 1
}
for f in $FILES; do
    if ! fetch "$f"; then
        case " $REQUIRED " in
            *" $f "*) echo "ERROR: $f is missing from GitHub ($REPO) - cannot continue"; exit 1 ;;
            *)        echo "WARNING: $f not found on GitHub - skipping it (upload it to $REPO)" ;;
        esac
    fi
done

# Host internet speed check (shown on the status page) - slow hosts make restores take hours
SPEED=$(curl -s -o /dev/null --max-time 20 -w "%{speed_download}" "https://speed.cloudflare.com/__down?bytes=50000000" || echo 0)
SPEED_MB=$(awk -v s="${SPEED:-0}" 'BEGIN{printf "%.0f", s/1048576}')
echo "Host download speed: ${SPEED_MB} MB/s"
if [ "${SPEED_MB:-0}" -lt 20 ]; then
    echo "WARNING: SLOW HOST (${SPEED_MB} MB/s) - consider destroying this instance and renting another"
fi

# Tunnel first, so the status page (status.<domain>) shows progress during setup
stage "Cloudflare Tunnel + JupyterLab + status page"
bash "$DEST/cftunnel.sh" || echo "WARNING: tunnel setup had problems - see /workspace/logs/cftunnel_setup.log"

stage "Installing ComfyUI"
bash "$DEST/install_comfyui.sh"

stage "Restoring vault from R2"
bash "$DEST/vault.sh" setup
vault restore


stage "Jupyter menu"
[ -f "$DEST/ComfyUI-Menu.ipynb" ] && cp -f "$DEST/ComfyUI-Menu.ipynb" /workspace/ComfyUI-Menu.ipynb
# JupyterLab can't open folders named "checkpoints" (bug) - give it a browsable shortcut
ln -sfn /workspace/ComfyUI/models/checkpoints /workspace/checkpoints-view
echo "Menu: open /workspace/ComfyUI-Menu.ipynb in JupyterLab"

# Idle watcher + automatic backups (starts counting once setup is complete)
if [ -f "$DEST/watcher.py" ]; then
cat > /opt/supervisor-scripts/watcher.sh <<'WEOF'
#!/bin/bash
exec /usr/bin/python3 /opt/vault/watcher.py
WEOF
chmod +x /opt/supervisor-scripts/watcher.sh
cat > /etc/supervisor/conf.d/watcher.conf <<'WEOF'
[program:watcher]
command=/opt/supervisor-scripts/watcher.sh
autostart=true
autorestart=true
startsecs=5
stdout_logfile=/workspace/logs/watcher-service.log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=1
redirect_stderr=true
WEOF
supervisorctl reread >/dev/null && supervisorctl update >/dev/null
supervisorctl restart watcher >/dev/null || true
echo "Idle watcher: IDLE_MINUTES=${IDLE_MINUTES:-30} IDLE_ACTION=${IDLE_ACTION:-stop} AUTOBACKUP_MINUTES=${AUTOBACKUP_MINUTES:-15}"
else
echo "WARNING: watcher.py missing - NO idle shutdown or auto-backup on this instance"
fi

stage "PROVISION COMPLETE $(date)"
