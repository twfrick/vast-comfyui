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
FILES="statuspage.py cftunnel.sh install_comfyui.sh vault.sh vault_menu.py ComfyUI-Menu.ipynb"

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

fetch() {   # GitHub API = always the newest file (no raw cache). Token avoids rate limits.
    local f="$1" url="https://api.github.com/repos/$REPO/contents/$1?ref=$BRANCH"
    if [ -n "${GITHUB_TOKEN:-}" ] && curl -fsSL -H "Accept: application/vnd.github.raw" \
            -H "Authorization: Bearer $GITHUB_TOKEN" "$url" -o "$DEST/$f"; then
        :
    else
        curl -fsSL --retry 3 -H "Accept: application/vnd.github.raw" "$url" -o "$DEST/$f"
    fi
    chmod +x "$DEST/$f"
    echo "Downloaded $f"
}
for f in $FILES; do fetch "$f"; done

# Tunnel first, so the status page (status.<domain>) shows progress during setup
stage "Cloudflare Tunnel + JupyterLab + status page"
bash "$DEST/cftunnel.sh" || echo "WARNING: tunnel setup had problems - see /workspace/logs/cftunnel_setup.log"

stage "Installing ComfyUI"
bash "$DEST/install_comfyui.sh"

stage "Restoring vault from R2"
bash "$DEST/vault.sh" setup
vault restore


stage "Jupyter menu"
cp -f "$DEST/ComfyUI-Menu.ipynb" /workspace/ComfyUI-Menu.ipynb
# JupyterLab can't open folders named "checkpoints" (bug) - give it a browsable shortcut
ln -sfn /workspace/ComfyUI/models/checkpoints /workspace/checkpoints-view
echo "Menu: open /workspace/ComfyUI-Menu.ipynb in JupyterLab"

stage "PROVISION COMPLETE $(date)"
