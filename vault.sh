#!/usr/bin/env bash
# =============================================================================
# vault.sh  -  Back up / restore ComfyUI to Cloudflare R2
#
#   vault setup     install rclone, test R2, install the "vault" command
#   vault backup    copy models, custom_nodes, workflows, input, output -> R2
#   vault restore   copy everything back from R2 + reinstall node requirements
#   vault status    show local vs R2 sizes and last backup time
#   vault shutdown stop|destroy [--no-backup]   back up, then stop or destroy this instance
#
# Saved in R2 (bucket $R2_BUCKET):
#   comfyui/models        comfyui/custom_nodes   comfyui/user (workflows+settings)
#   comfyui/input         comfyui/output (backup only, not restored by default)
#   comfyui/jupyter       JupyterLab settings + layouts
#   trash/<date>/...      files you deleted locally (kept, never lost)
#
# Needs Vast account env vars: R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET
# Log: /workspace/logs/vault.log
# =============================================================================
set -Eeuo pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
COMFY="$WORKSPACE/ComfyUI"
LOG_DIR="$WORKSPACE/logs"
LOG="$LOG_DIR/vault.log"
MARKER="$WORKSPACE/.vault_restored"     # exists = safe to mirror deletions to R2
CONSTRAINTS="$WORKSPACE/.torch-constraints.txt"
PY="/venv/main/bin/python"

MIRROR_DIRS="models custom_nodes user input"   # backed up AND restored
KEEP_DIRS="output"                             # backed up only, never deleted in R2
RESTORE_OUTPUT="${RESTORE_OUTPUT:-0}"          # set to 1 to also restore outputs

EXCLUDES=(--exclude "**/__pycache__/**" --exclude "**/.cache/**" --exclude "**/.ipynb_checkpoints/**"
          --exclude "*.part" --exclude "*.aria2" --exclude "*.tmp" --exclude "*.incomplete")
RCLONE_FLAGS=(--fast-list --transfers 16 --checkers 32 --s3-chunk-size 64M --s3-upload-concurrency 8
              --stats 5s --stats-one-line --stats-log-level NOTICE --retries 5 --low-level-retries 20)

mkdir -p "$LOG_DIR"
log()  { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
die()  { log "ERROR: $*"; exit 1; }
trap 'log "ERROR: vault ${CMD:-} failed (line $LINENO). See $LOG"' ERR

# -----------------------------------------------------------------------------
# Use our own up-to-date rclone (old distro builds fail on R2 with "501 Not Implemented")
RCLONE="/opt/vault/rclone"
ensure_rclone() {
    mkdir -p /root/.config/rclone && touch /root/.config/rclone/rclone.conf
    if [ -x "$RCLONE" ]; then return 0; fi
    log "Installing latest rclone..."
    if ! command -v unzip >/dev/null 2>&1; then
        apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip </dev/null
    fi
    local tmp; tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/rclone.zip" https://downloads.rclone.org/rclone-current-linux-amd64.zip
    unzip -q "$tmp/rclone.zip" -d "$tmp"
    mkdir -p /opt/vault
    install -m 755 "$tmp"/rclone-*-linux-amd64/rclone "$RCLONE"
    rm -rf "$tmp"
}

load_env() {
    local k v
    for k in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do
        if [ -z "${!k:-}" ] && [ -f /etc/environment ]; then
            v=$(grep -m1 "^$k=" /etc/environment | cut -d= -f2- | sed 's/^"//; s/"$//' || true)
            export "$k=$v"
        fi
        [ -n "${!k:-}" ] || die "$k is not set. Add it in Vast: Account > Settings > Environment Variables"
    done
    # Endpoint must be just https://<account>.r2.cloudflarestorage.com (strip any /bucket path)
    R2_ENDPOINT=$(echo "$R2_ENDPOINT" | sed -E 's#^(https://[^/]+).*#\1#')
    export RCLONE_CONFIG_R2_TYPE=s3
    export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
    export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
    export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
    REMOTE="r2:$R2_BUCKET/comfyui"
    TRASH="r2:$R2_BUCKET/trash"
}

take_lock() {
    exec 9>/tmp/vault.lock
    flock -n 9 || die "Another backup or restore is already running. Try again when it finishes."
}

need_comfy() { [ -d "$COMFY" ] || die "ComfyUI not found at $COMFY - run install_comfyui.sh first"; }

rc() { "$RCLONE" "$@" "${RCLONE_FLAGS[@]}" "${EXCLUDES[@]}" 2>&1 | tee -a "$LOG"; }

restart_comfyui() {
    if supervisorctl status comfyui >/dev/null 2>&1; then
        log "Restarting ComfyUI..."
        supervisorctl restart comfyui >/dev/null
    else
        log "NOTE: restart ComfyUI yourself to load restored nodes"
    fi
}

# -----------------------------------------------------------------------------
cmd_setup() {
    ensure_rclone
    "$RCLONE" version | head -1
    load_env
    log "Testing R2 bucket '$R2_BUCKET' (read + write)..."
    "$RCLONE" lsf "r2:$R2_BUCKET" --max-depth 1 >/dev/null \
        || die "Cannot read the R2 bucket. Check R2_ENDPOINT, keys, and bucket name."
    echo "test $(date)" > /tmp/.vault_test
    "$RCLONE" copyto /tmp/.vault_test "$REMOTE/.vault_test" \
        || die "Cannot write to the R2 bucket. The API token needs 'Object Read & Write'."
    "$RCLONE" deletefile "$REMOTE/.vault_test"
    if [ "$(readlink -f "$0")" != "/usr/local/bin/vault" ]; then
        install -m 755 "$0" /usr/local/bin/vault
    fi
    log "SETUP OK - R2 works. You can now use: vault backup | vault restore | vault status"
}

cmd_backup() {
    ensure_rclone; load_env; need_comfy; take_lock
    local stamp d; stamp=$(date '+%Y-%m-%d_%H%M%S')
    log "===== BACKUP started ====="
    if [ ! -f "$MARKER" ]; then
        log "NOTE: no restore done on this instance yet - using safe mode (nothing deleted in R2)"
    fi
    for d in $MIRROR_DIRS; do
        [ -d "$COMFY/$d" ] || continue
        log "Backing up $d"
        if [ -f "$MARKER" ]; then
            # Mirror: files you deleted locally are moved to R2 trash, not destroyed
            rc sync "$COMFY/$d" "$REMOTE/$d" --backup-dir "$TRASH/$stamp/$d"
        else
            rc copy "$COMFY/$d" "$REMOTE/$d"
        fi
    done
    if [ -d "$WORKSPACE/.jupyter" ]; then
        log "Backing up Jupyter settings"
        if [ -f "$MARKER" ]; then
            rc sync "$WORKSPACE/.jupyter" "$REMOTE/jupyter" --backup-dir "$TRASH/$stamp/jupyter"
        else
            rc copy "$WORKSPACE/.jupyter" "$REMOTE/jupyter"
        fi
    fi
    for d in $KEEP_DIRS; do
        [ -d "$COMFY/$d" ] || continue
        log "Backing up $d (never deleted in R2)"
        rc copy "$COMFY/$d" "$REMOTE/$d"
    done
    local gpu; gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
    echo "$(date '+%F %T %Z') instance=${CONTAINER_ID:-?} gpu=${gpu:-?}" > "$WORKSPACE/.vault_last_backup"
    "$RCLONE" copyto "$WORKSPACE/.vault_last_backup" "$REMOTE/.last_backup"
    log "===== BACKUP COMPLETE ====="
}

install_node_requirements() {
    local PIP dir name
    if command -v uv >/dev/null 2>&1; then PIP=(uv pip install --python "$PY"); else PIP=("$PY" -m pip install); fi
    [ -f "$CONSTRAINTS" ] && PIP+=(-c "$CONSTRAINTS")
    for dir in "$COMFY"/custom_nodes/*/; do
        name=$(basename "$dir")
        if [ -f "$dir/requirements.txt" ]; then
            log "Installing requirements: $name"
            "${PIP[@]}" -r "$dir/requirements.txt" >>"$LOG" 2>&1 \
                || log "WARNING: requirements failed for $name (node may not load)"
        fi
        if [ -f "$dir/install.py" ]; then
            log "Running install.py: $name"
            (cd "$dir" && timeout 600 "$PY" install.py) >>"$LOG" 2>&1 \
                || log "WARNING: install.py failed for $name"
        fi
    done
}

restore_dir() {   # remote-subdir local-dir   (skips if nothing in R2)
    mkdir -p "$2"
    if "$RCLONE" lsf "$REMOTE/$1" --max-depth 1 2>/dev/null | head -1 | grep -q .; then
        rc copy "$REMOTE/$1" "$2"
    else
        log "  (nothing in R2 for $1)"
    fi
}

cmd_restore() {
    ensure_rclone; load_env; need_comfy; take_lock
    local d
    log "===== RESTORE started ====="
    if [ -z "$("$RCLONE" lsf "$REMOTE" --max-depth 1 2>/dev/null | head -1 || true)" ]; then
        log "R2 has no backup yet (first run) - nothing to restore"
        touch "$MARKER"
        log "===== RESTORE COMPLETE (nothing to restore) ====="
        return 0
    fi
    "$RCLONE" cat "$REMOTE/.last_backup" 2>/dev/null | sed 's/^/Last backup: /' | tee -a "$LOG" || true
    # Small things first: Jupyter settings (then JupyterLab is fully usable), workflows,
    # inputs and nodes; the big models come last.
    log "Restoring Jupyter settings"
    restore_dir jupyter "$WORKSPACE/.jupyter"
    if supervisorctl status labvault >/dev/null 2>&1; then
        supervisorctl restart labvault >/dev/null || true
        log "JupyterLab ready with your settings (models still restoring)"
    fi
    for d in user input custom_nodes models; do
        log "Restoring $d"
        restore_dir "$d" "$COMFY/$d"
    done
    if [ "$RESTORE_OUTPUT" = "1" ]; then
        log "Restoring output"
        restore_dir output "$COMFY/output"
    fi
    install_node_requirements
    touch "$MARKER"
    restart_comfyui
    log "===== RESTORE COMPLETE ====="
}

cmd_status() {
    ensure_rclone; load_env
    local d
    echo "---- Local (this instance) ----"
    for d in $MIRROR_DIRS $KEEP_DIRS; do
        if [ -d "$COMFY/$d" ]; then
            du -sh "$COMFY/$d" 2>/dev/null | awk -v n="$d" '{printf "  %-13s %s\n", n, $1}' || true
        fi
    done
    echo "---- R2 bucket $R2_BUCKET ----"
    for d in $MIRROR_DIRS $KEEP_DIRS; do
        printf "  %-13s " "$d"
        "$RCLONE" size "$REMOTE/$d" --fast-list 2>/dev/null | grep "Total size" | sed 's/Total size: //' || echo "-"
    done
    echo "---- Info ----"
    echo "  Last backup (R2):       $("$RCLONE" cat "$REMOTE/.last_backup" 2>/dev/null || echo never)"
    echo "  Restored on this instance: $([ -f "$MARKER" ] && echo yes || echo no)"
    df -h "$WORKSPACE" | awk 'NR==2 {print "  Disk: " $3 " used of " $2 " (" $4 " free)"}'
}

# -----------------------------------------------------------------------------
envget() {   # value from environment, else /etc/environment
    local k="$1"
    if [ -n "${!k:-}" ]; then echo "${!k}"; return; fi
    grep -m1 "^$k=" /etc/environment 2>/dev/null | cut -d= -f2- | sed 's/^"//; s/"$//' || true
}

vast_api() {   # METHOD [json-body]  -> acts on this instance via the Vast API
    local id key code
    id="$(envget CONTAINER_ID)"
    key="$(envget VAST_API_KEY)"                       # optional: full account key
    [ -n "$key" ] || key="$(envget CONTAINER_API_KEY)" # default: this instance's own key
    [ -n "$id" ]  || die "CONTAINER_ID unknown - is this a Vast instance?"
    [ -n "$key" ] || die "No Vast API key found (CONTAINER_API_KEY / VAST_API_KEY)"
    code=$(curl -sS -o /tmp/vast_api.out -w "%{http_code}" -X "$1" \
        -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
        ${2:+-d "$2"} "https://console.vast.ai/api/v0/instances/$id/") || code=000
    if [ "${code:0:1}" != "2" ]; then
        log "Vast API answered HTTP $code: $(head -c 300 /tmp/vast_api.out 2>/dev/null)"
        die "Vast refused the request. If this says 401/403, add your account API key as VAST_API_KEY in Vast settings."
    fi
}

cmd_shutdown() {   # stop|destroy [--no-backup]
    local mode="${1:-}" opt="${2:-}"
    case "$mode" in stop|destroy) ;; *) die "Usage: vault shutdown stop|destroy [--no-backup]" ;; esac
    if [ "$opt" = "--no-backup" ]; then
        [ "$mode" = "destroy" ] && die "Refusing to destroy without a backup."
        log "Skipping backup (stop keeps this instance's disk)"
    else
        cmd_backup      # exits on failure, so we never stop/destroy after a failed backup
    fi
    log "===== Asking Vast to ${mode^^} instance $(envget CONTAINER_ID) ====="
    if [ "$mode" = "destroy" ]; then
        vast_api DELETE
    else
        vast_api PUT '{"state": "stopped"}'
    fi
    log "Vast accepted - this instance will shut down in a few seconds."
}

# -----------------------------------------------------------------------------
CMD="${1:-}"
case "$CMD" in
    setup)   cmd_setup ;;
    backup)  cmd_backup ;;
    restore) cmd_restore ;;
    status)  cmd_status ;;
    shutdown) cmd_shutdown "${2:-}" "${3:-}" ;;
    *) echo "Usage: vault setup | backup | restore | status | shutdown stop|destroy [--no-backup]"; exit 1 ;;
esac
