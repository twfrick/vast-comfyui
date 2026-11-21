#!/usr/bin/env bash
# =============================================================================
# vault.sh  -  Back up / restore ComfyUI to Cloudflare R2
#
#   vault setup     install rclone, test R2, install the "vault" command
#   vault backup    copy models, custom_nodes, workflows, input, output -> R2
#   vault restore   copy everything back from R2 + reinstall node requirements
#   vault status    show local vs R2 sizes and last backup time
#   vault trash     list files that backups moved to R2 trash
#   vault undelete <date> [folder]   put trash back into the vault
#   vault empty-trash <date>|all --yes   permanently delete trash
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
          --exclude "*.part" --exclude "*.aria2" --exclude "*.tmp" --exclude "*.incomplete"
          --exclude "**/__manager/cache/**" --exclude "*.partial")
# --timeout/--contimeout: a silent (hung) connection is retried after 60 s instead of rclone's default 5 min
RCLONE_FLAGS=(--fast-list --transfers 16 --checkers 32 --s3-chunk-size 64M --s3-upload-concurrency 8
              --timeout 60s --contimeout 20s --multi-thread-streams 8 --multi-thread-cutoff 256M
              --stats 5s --stats-one-line --stats-log-level NOTICE --retries 5 --low-level-retries 20)

mkdir -p "$LOG_DIR"
log()  { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
section() {   # a step header framed by lines, easy to spot in the log
    local bar="============================================================"
    printf '\n%s\n' "$bar" | tee -a "$LOG"
    log "$*"
    printf '%s\n' "$bar" | tee -a "$LOG"
}
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

# Copy with progress: overall line "NOTICE: [3/9]  4.1 GiB / 18.6 GiB, 22%, ..." (counted against the
# bytes that still need downloading) and "  done [n/N] name" as each file finishes. Per-file progress
# goes to /workspace/.restore_files for the status page's small bars.
COUNT_FILTER=/opt/vault/count_filter.py
write_count_filter() {
    mkdir -p /opt/vault
    cat > "$COUNT_FILTER" <<'PYEOF'
import re, sys
# args: total_files have_files need_bytes
total, done, need = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
FILES_STATE = "/workspace/.restore_files"
U = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5}
SZ = r"[\d.]+\s*[KMGTP]?i?B?"
copied = re.compile(r"INFO\s*:\s*(.+?):\s*(?:Multi-thread )?Copied \((?:new|replaced existing)\)")
bytes_line = re.compile(rf"(?:Transferred:|NOTICE:)\s+({SZ}) / ({SZ}), [^,]*, ({SZ}/s)")
file_line = re.compile(rf"^\s*\*\s+(.+?):\s*(\d+)%\s*/\s*({SZ}),\s*({SZ}/s),\s*(\S+)")
pending = {"x": None, "speed": "", "files": []}


def to_b(v):
    m = re.match(r"([\d.]+)\s*([KMGTP]?)", v.strip())
    return float(m.group(1)) * U[m.group(2)] if m else 0.0


def h(b):
    for u in ("B", "KiB", "MiB", "GiB", "TiB"):
        if b < 1024 or u == "TiB":
            return f"{b:.3f} {u}" if u != "B" else f"{int(b)} B"
        b /= 1024


def secs(s):
    s = int(s)
    return f"{s // 3600}h{s % 3600 // 60}m" if s >= 3600 else (f"{s // 60}m{s % 60}s" if s >= 60 else f"{s}s")


def flush():
    if pending["x"] is None:
        pending["files"] = []
        return
    x, sp = pending["x"], pending["speed"]
    # rclone prints rounded sizes (e.g. 51.429 GiB), so treat "within 0.05%" or all files done as 100%
    pct = 100 if need <= 0 or x >= need * 0.9995 or done >= total else min(99, int(x * 100 / need))
    spb = to_b(sp)
    eta = secs((need - x) / spb) if spb > 0 and need > x else ("0s" if need <= x else "-")
    print(f"NOTICE: [{done}/{total}]  {h(x)} / {h(max(need, x))}, {pct}%, {h(spb)}/s, ETA {eta}", flush=True)
    # per-file progress goes to a small side file for the status page's file bars (not into the log)
    try:
        with open(FILES_STATE, "w") as fh:
            for name, p, size, fsp, feta in sorted(pending["files"], key=lambda f: -to_b(f[2]))[:4]:
                fh.write(f"   > {name}: {p}% of {h(to_b(size))}, {h(to_b(fsp))}/s, ETA {feta}\n")
    except OSError:
        pass
    pending.update(x=None, speed="", files=[])


for raw in sys.stdin:
    line = raw.rstrip("\n")
    m = copied.search(line)
    if m:
        done += 1
        print(f"  done [{done}/{total}] {m.group(1)}", flush=True)
        continue
    m = file_line.search(line)
    if m:
        pending["files"].append(m.groups())
        continue
    m = bytes_line.search(line)
    if m:
        flush()                                   # previous block (if any)
        pending["x"], pending["speed"] = to_b(m.group(1)), m.group(3)
        if "NOTICE:" in line and "Transferred:" not in line:
            flush()                               # one-line stats: nothing more follows
        continue
    s = line.strip()
    if not s:
        flush()
        continue
    if " INFO " in line or "INFO  :" in line or s.startswith(("Transferred:", "Elapsed time:", "Checks:",
                                                              "Transferring:", "Errors:", "Renamed:", "Deleted:")) \
            or re.search(r"NOTICE:\s*$", line):
        continue
    flush()
    print(line, flush=True)
flush()
PYEOF
}

rc_counted() {   # src dst label  (download into a local folder, with progress)
    local list total have need
    list=$("$RCLONE" lsf -R --files-only --format sp "$1" "${EXCLUDES[@]}" 2>/dev/null) || list=""
    total=$(printf '%s' "$list" | grep -c . || true)
    # files already here with the right size are skipped (resumed restore); count what is left
    read -r have need < <(printf '%s\n' "$list" | python3 -c '
import os, sys
dst = sys.argv[1]; n = 0; need = 0
for line in sys.stdin:
    size, _, path = line.rstrip("\n").partition(";")
    if not path:
        continue
    p = os.path.join(dst, path)
    if os.path.isfile(p) and str(os.path.getsize(p)) == size:
        n += 1
    else:
        need += int(size or 0)
print(n, need)' "$2")
    section "Restoring ${3:-files} ($total file(s), $have already here, $(awk -v b="$need" 'BEGIN{printf "%.2f GB", b/1073741824}') to download)"
    write_count_filter
    "$RCLONE" copy "$1" "$2" "${RCLONE_FLAGS[@]}" "${EXCLUDES[@]}" -v --stats-one-line=false 2>&1 \
        | python3 -u "$COUNT_FILTER" "$total" "$have" "$need" | tee -a "$LOG"
    rm -f "$WORKSPACE/.restore_files"
}

restart_comfyui() {
    if supervisorctl status comfyui >/dev/null 2>&1; then
        log "Restarting ComfyUI..."
        supervisorctl restart comfyui >/dev/null
    else
        log "NOTE: restart ComfyUI yourself to load restored nodes"
    fi
}

# -----------------------------------------------------------------------------
# R2 safety helpers - an R2 *error* is never treated as "empty"
remote_state() {   # path -> prints data|empty ; exits on any other error
    local out code
    out=$("$RCLONE" lsf "$1" --max-depth 1 2>/tmp/vault_lsf.err) && code=0 || code=$?
    if [ "$code" -eq 0 ]; then
        if [ -n "$out" ]; then echo data; else echo empty; fi
        return 0
    fi
    if [ "$code" -eq 3 ] || grep -qi "directory not found" /tmp/vault_lsf.err; then
        echo empty; return 0
    fi
    log "ERROR: could not read R2 ($1): $(head -c 300 /tmp/vault_lsf.err | tr '\n' ' ')" >&2
    exit 1
}

bytes_of() {   # rclone path -> total bytes (exits on error)
    "$RCLONE" size "$1" --json "${EXCLUDES[@]}" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["bytes"])' \
        || { log "ERROR: could not measure $1" >&2; exit 1; }
}

would_remove() {   # local remote -> "files bytes" that are in R2 but not on this instance
    "$RCLONE" lsf -R --files-only --format sp "$2" "${EXCLUDES[@]}" > /tmp/vault_r.txt 2>/dev/null || return 1
    "$RCLONE" lsf -R --files-only --format p  "$1" "${EXCLUDES[@]}" > /tmp/vault_l.txt 2>/dev/null || return 1
    python3 - <<'PY'
local = set(open('/tmp/vault_l.txt').read().splitlines())
n = b = 0
for line in open('/tmp/vault_r.txt'):
    size, _, path = line.rstrip('\n').partition(';')
    if path not in local:
        n += 1
        b += int(size or 0)
print(n, b)
PY
}

MAX_DEL_FILES="${VAULT_MAX_DELETE_FILES:-25}"
MAX_DEL_GB="${VAULT_MAX_DELETE_GB:-5}"

mirror_or_copy() {   # local remote trash-dir allow-delete(0/1)
    # Mirror (sync) only when it is safe: a restore ran on this instance AND the files that
    # would leave R2 are few/small. Otherwise copy only and warn - nothing disappears from R2.
    local st n b gb
    if [ ! -f "$MARKER" ]; then rc copy "$1" "$2"; return; fi
    st=$(remote_state "$2") || exit 1
    if [ "$st" = empty ]; then rc copy "$1" "$2"; return; fi
    read -r n b < <(would_remove "$1" "$2" || echo "999999 0")
    gb=$(awk -v b="$b" 'BEGIN{printf "%.1f", b/1073741824}')
    if [ "$4" != "1" ] && { [ "$n" -gt "$MAX_DEL_FILES" ] || awk -v g="$gb" -v m="$MAX_DEL_GB" 'BEGIN{exit !(g>m)}'; }; then
        log "WARNING: backup would remove $n file(s) ($gb GB) from R2 ($(basename "$2")) that are not on this instance."
        log "WARNING: kept them in R2 (copy only). If you really deleted them, run: vault backup --allow-delete"
        rc copy "$1" "$2"
        return
    fi
    [ "$n" -gt 0 ] && log "  $n file(s) ($gb GB) you deleted here move to R2 trash"
    rc sync "$1" "$2" --backup-dir "$3"
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

cmd_backup() {   # [--allow-delete]
    ensure_rclone; load_env; need_comfy; take_lock
    local stamp d allow=0; stamp=$(date '+%Y-%m-%d_%H%M%S')
    [ "${1:-}" = "--allow-delete" ] && allow=1
    log "===== BACKUP started ====="
    if [ ! -f "$MARKER" ]; then
        log "NOTE: no complete restore on this instance - safe mode (nothing removed from R2)"
    fi
    for d in $MIRROR_DIRS; do
        [ -d "$COMFY/$d" ] || continue
        section "Backing up $d"
        mirror_or_copy "$COMFY/$d" "$REMOTE/$d" "$TRASH/$stamp/$d" "$allow"
    done
    if [ -d "$WORKSPACE/.jupyter" ]; then
        section "Backing up Jupyter settings"
        mirror_or_copy "$WORKSPACE/.jupyter" "$REMOTE/jupyter" "$TRASH/$stamp/jupyter" "$allow"
    fi
    if [ -d "$WORKSPACE/logs" ]; then
        # logs of this instance, kept in R2 so you can see what happened after it is gone
        "$RCLONE" copy "$WORKSPACE/logs" "$REMOTE/logs/$(date +%Y-%m-%d)_$(envget CONTAINER_ID)" \
            -q 2>/dev/null || true
    fi
    for d in $KEEP_DIRS; do
        [ -d "$COMFY/$d" ] || continue
        section "Backing up $d (never deleted in R2)"
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

restore_dir() {   # remote-subdir local-dir  (fails loudly; verifies size)
    local st r l
    mkdir -p "$2"
    st=$(remote_state "$REMOTE/$1") || exit 1
    if [ "$st" = empty ]; then section "Restoring $1 (nothing in R2)"; return 0; fi
    rc_counted "$REMOTE/$1" "$2" "$1"
    r=$(bytes_of "$REMOTE/$1") || exit 1
    l=$(bytes_of "$2") || exit 1
    if [ "$l" -lt "$r" ]; then
        log "ERROR: $1 restore incomplete: $l of $r bytes. NOT marking this instance as restored."
        exit 1
    fi
    log "  $1 verified ($(awk -v b="$r" 'BEGIN{printf "%.2f GB", b/1073741824}'))"
}

cmd_restore() {   # [jupyter | --skip-jupyter]
    local mode="${1:-all}"
    ensure_rclone; load_env; take_lock
    [ "$mode" = "jupyter" ] || need_comfy
    local d top
    if [ "$mode" = "jupyter" ]; then
        log "===== RESTORE (Jupyter settings) ====="
        restore_jupyter
        log "===== RESTORE (Jupyter settings) COMPLETE ====="
        return 0
    fi
    log "===== RESTORE started ====="
    top=$(remote_state "$REMOTE") || exit 1
    if [ "$top" = empty ]; then
        log "R2 has no backup yet (first run) - nothing to restore"
        touch "$MARKER"
        log "===== RESTORE COMPLETE (nothing to restore) ====="
        return 0
    fi
    "$RCLONE" cat "$REMOTE/.last_backup" 2>/dev/null | sed 's/^/Last backup: /' | tee -a "$LOG" || true
    [ "$mode" = "--skip-jupyter" ] || restore_jupyter
    # Small things first (workflows, inputs, nodes); the big models come last.
    for d in user input custom_nodes models; do
        restore_dir "$d" "$COMFY/$d"
    done
    if [ "$RESTORE_OUTPUT" = "1" ]; then
        restore_dir output "$COMFY/output"
    fi
    install_node_requirements
    touch "$MARKER"
    restart_comfyui
    log "===== RESTORE COMPLETE ====="
}

restore_jupyter() {
    restore_dir jupyter "$WORKSPACE/.jupyter"
    # Restart JupyterLab to load them - only during instance setup. A restore started from the
    # menu/terminal runs *inside* JupyterLab, and restarting it would kill the restore.
    if [ "${VAULT_PROVISIONING:-0}" = "1" ] && supervisorctl status labvault >/dev/null 2>&1; then
        supervisorctl restart labvault >/dev/null || true
        log "JupyterLab ready with your settings"
    fi
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

cmd_trash() {   # list what is in R2 trash
    ensure_rclone; load_env
    local st t d
    st=$(remote_state "$TRASH") || exit 1
    [ "$st" = empty ] && { echo "R2 trash is empty."; return 0; }
    echo "R2 trash (files removed by backups - restore with: vault undelete <date> [folder]):"
    for t in $("$RCLONE" lsf "$TRASH" --dirs-only | tr -d '/'); do
        echo "  $t"
        for d in $("$RCLONE" lsf "$TRASH/$t" --dirs-only | tr -d '/'); do
            printf "      %-14s %s\n" "$d" "$("$RCLONE" size "$TRASH/$t/$d" 2>/dev/null | grep 'Total size' | sed 's/Total size: //')"
        done
    done
}

cmd_empty_trash() {   # <date>|all  --yes   (permanently deletes from R2 trash)
    ensure_rclone; load_env; take_lock
    local t="${1:-}" yes="${2:-}" st what
    [ -n "$t" ] || die "Usage: vault empty-trash <date>|all --yes   (see: vault trash)"
    [ "$yes" = "--yes" ] || die "This permanently deletes from R2 trash. Add --yes to confirm."
    if [ "$t" = "all" ]; then what="$TRASH"; else what="$TRASH/$t"; fi
    st=$(remote_state "$what") || exit 1
    [ "$st" = data ] || { log "Nothing in R2 trash for '$t'."; return 0; }
    log "Permanently deleting R2 trash: $t ($("$RCLONE" size "$what" 2>/dev/null | grep 'Total size' | sed 's/Total size: //'))"
    "$RCLONE" purge "$what" 2>&1 | tee -a "$LOG"
    log "Trash '$t' deleted."
}

cmd_undelete() {   # <date> [folder]  -> copy trash back into the vault (keeps the trash copy)
    ensure_rclone; load_env; take_lock
    local t="${1:-}" only="${2:-}" d st
    [ -n "$t" ] || die "Usage: vault undelete <date-from-vault-trash> [models|custom_nodes|user|input|jupyter]"
    st=$(remote_state "$TRASH/$t") || exit 1
    [ "$st" = data ] || die "Nothing in R2 trash for '$t' - run: vault trash"
    for d in $("$RCLONE" lsf "$TRASH/$t" --dirs-only | tr -d '/'); do
        [ -n "$only" ] && [ "$d" != "$only" ] && continue
        log "Putting back $d from trash $t"
        rc copy "$TRASH/$t/$d" "$REMOTE/$d" --ignore-existing
    done
    log "Done. Run 'vault restore' (or start a new instance) to get the files onto an instance."
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
    backup)  cmd_backup "${2:-}" ;;
    trash)   cmd_trash ;;
    rclone)  shift; ensure_rclone; load_env; exec "$RCLONE" "$@" ;;
    undelete) cmd_undelete "${2:-}" "${3:-}" ;;
    empty-trash) cmd_empty_trash "${2:-}" "${3:-}" ;;
    restore) cmd_restore "${2:-all}" ;;
    status)  cmd_status ;;
    shutdown) cmd_shutdown "${2:-}" "${3:-}" ;;
    *) echo "Usage: vault setup | backup [--allow-delete] | restore | status | trash | undelete <date> [folder] | empty-trash <date>|all --yes | shutdown stop|destroy [--no-backup] | rclone <args>  (paths: r2:$R2_BUCKET/...)"; exit 1 ;;
esac
