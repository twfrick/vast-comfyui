# vast-comfyui: ComfyUI + JupyterLab on Vast.ai, with everything saved to Cloudflare R2

Rent any GPU on Vast.ai. Your models, custom nodes, workflows, settings and outputs live in a
Cloudflare R2 bucket (the **vault**). Every new instance installs itself, restores the vault and
is reachable at the same fixed addresses. When you stop working, it backs up and shuts down.

```
                 Cloudflare Access (email code)
   your browser ─────────────────────────────────▶  Cloudflare Tunnel ─▶  Vast.ai instance
   comfyui.<domain>   → ComfyUI        :18188                               │
   jupyter.<domain>   → JupyterLab     :18888 (menu)                        │ backup / restore
   status.<domain>    → status page    :18999                               ▼
                                                                    Cloudflare R2 "vault"
```

> No secrets are stored in this repository. All keys and tokens live in Vast.ai account
> environment variables.

---

## Files

| File | What it does |
|---|---|
| `provision.sh` | Runs on every new instance (Vast `PROVISIONING_SCRIPT`). Downloads the files below and runs the setup in order. |
| `cftunnel.sh` | Starts JupyterLab ("Vault Lab"), the status page and the Cloudflare Tunnel. |
| `install_comfyui.sh` | Installs or updates ComfyUI, PyTorch (CUDA 12.8), ComfyUI-Manager and the always-on nodes (ComfyUI-RunpodDirect, Civicomfy, ComfyUI-VaultActivity). Runs ComfyUI as a service. |
| `vault.sh` | The `vault` command: back up to and restore from R2, trash, shutdown. |
| `watcher.py` | Idle watcher + automatic backups. |
| `statuspage.py` | The status page (setup progress, restore progress, idle countdown, logs). |
| `vault_menu.py` + `ComfyUI-Menu.ipynb` | The JupyterLab control panel. |

## Setup order on a new instance

1. Download scripts, measure host download speed (shown on the status page; under 20 MB/s = rent another host)
2. Tunnel + JupyterLab + status page
3. **Jupyter settings + menu** (you can use JupyterLab now)
4. Install ComfyUI + PyTorch
5. Restore from R2: workflows, inputs, custom nodes, then models (each folder is size-checked)
6. Start the idle watcher, then **READY**

On a fast host with a small vault this takes about 2 minutes. Model restore runs at roughly
300–900 MB/s (about 2–5 minutes per 100 GB).

---

## One-time setup (to rebuild from scratch)

### 1. Cloudflare R2
1. Create a bucket, e.g. `comfyui-vault`.
2. **Manage API tokens → Create API token** with **Object Read & Write** for that bucket.
3. Note the **Access Key ID**, **Secret Access Key** and the S3 endpoint
   `https://<account-id>.r2.cloudflarestorage.com`.

### 2. Tokens
- Hugging Face: a **Read** token.
- Civitai: an API key.
- GitHub: a read-only fine-grained token (only used to avoid GitHub rate limits).

### 3. Cloudflare Tunnel (Zero Trust)
1. **Networks → Tunnels → Create a tunnel → Cloudflared**, name it e.g. `vast-comfyui`.
   Use a tunnel that is **only** for Vast (a shared tunnel splits traffic between machines).
   Copy the token (the long `eyJ…` text in the install command; don't run the command).
2. Add these hostnames (Public hostnames / Published application routes), all type **HTTP**:

   | Hostname | URL |
   |---|---|
   | `comfyui.<domain>` | `localhost:18188` |
   | `jupyter.<domain>` | `localhost:18888` |
   | `status.<domain>` | `localhost:18999` |

3. **Access → Applications → Add → Self-hosted**: add all three hostnames, policy
   **Allow → Emails → your email**, login method **One-time PIN**. Without this step the
   addresses would be open to anyone.

### 4. Vast.ai account environment variables
**Account → Settings → Environment Variables**:

| Variable | Value |
|---|---|
| `HF_TOKEN` | Hugging Face token |
| `CIVITAI_TOKEN` | Civitai key |
| `GITHUB_TOKEN` | GitHub token |
| `R2_ACCESS_KEY_ID` | R2 access key |
| `R2_SECRET_ACCESS_KEY` | R2 secret |
| `R2_ENDPOINT` | `https://<account-id>.r2.cloudflarestorage.com` |
| `R2_BUCKET` | `comfyui-vault` |
| `CF_TUNNEL_TOKEN` | the tunnel token |

Optional settings:

| Variable | Default | Meaning |
|---|---|---|
| `IDLE_MINUTES` | `30` | Minutes without activity before shutdown |
| `IDLE_ACTION` | `stop` | `stop`, `destroy` or `off` (a stopped instance still pays for its disk) |
| `AUTOBACKUP_MINUTES` | `15` | Automatic backup interval (`0` = off) |
| `COMFY_URL` / `LAB_URL` | `https://comfyui.centarione.org` / `https://jupyter.centarione.org` | Links on the menu and status page |
| `MANAGER_UI` | `new` | `legacy` = old ComfyUI-Manager window (breaks ComfyUI's "install missing nodes") |
| `TORCH_CUDA` | `cu128` | PyTorch build. `cu128` works on every host with Max CUDA ≥ 12.8. `cu130` needs Max CUDA ≥ 13.0 (falls back to cu128 on older hosts). `auto` = cu130 on Blackwell GPUs (RTX 50xx / RTX PRO) when the driver allows it, otherwise cu128 |
| `SAGEATTENTION` | `0` | `1` = install SageAttention (faster attention for KJNodes "Patch Sage Attention", SeedVR2, WAN video). Adds ~30 s to setup |
| `VAULT_MAX_DELETE_FILES` / `VAULT_MAX_DELETE_GB` | `25` / `5` | Safety limit for removing files from R2 in one backup |
| `RESTORE_OUTPUT` | `0` | `1` = also restore the output folder |

### 5. Vast.ai template
Start from Vast's **PyTorch** template and set:

- **Image:** `vastai/pytorch`, tag `cuda-12.8.1-auto`
- **Launch mode:** Jupyter. "Jupyter direct HTTPS" is optional (needs Vast's certificate in the browser).
- **Disk:** 200 GB (more if your model library grows; it can't be changed after renting)
- **Ports:** `8188`, `1111`
- **Environment variables:**
  - `PROVISIONING_SCRIPT` = `https://raw.githubusercontent.com/<user>/vast-comfyui/main/provision.sh`
  - `OPEN_BUTTON_PORT` = `1111`
  - `PORTAL_CONFIG` = (with the double quotes, because of the space)
    `"localhost:1111:11111:/:Instance Portal|localhost:8080:8080:/lab:Jupyter|localhost:8384:18384:/:Syncthing|localhost:8188:18188:/:ComfyUI"`
- **On-start script:**
  ```bash
  env >> /etc/environment
  mkdir -p ${DATA_DIRECTORY:-/workspace}/logs
  EP=$(command -v entrypoint.sh || ls /opt/instance-tools/bin/entrypoint.sh 2>/dev/null)
  if [ -n "$EP" ]; then
    "$EP" >> /workspace/logs/entrypoint.log 2>&1
  else
    echo "entrypoint.sh not found" >> /workspace/logs/onstart.log
  fi
  ```
  (Jupyter launch mode skips the image's own startup; this runs it, which starts the
  service manager that everything else relies on.)

If you fork this repo, change `REPO` at the top of `provision.sh` (or set `VAULT_REPO`).

---

## Daily use

1. **Rent** an instance with the template. Choose: Max CUDA ≥ 12.8, verified, reliability
   99%+, Inet Down 1000+ Mbps. Check the price breakdown: GPU/hr + disk/hr + internet $/TB
   (÷ 1000 = $/GB; restoring models counts as download).
2. Open **`https://status.<domain>`** and watch it reach **READY**.
3. Use **ComfyUI** at `https://comfyui.<domain>` and the **menu** at
   `https://jupyter.<domain>` → `ComfyUI-Menu.ipynb` → Shift+Enter.
4. **End** with Menu → Vault → **Backup & DESTROY**, or let the idle watcher stop the instance.

### Menu tabs
- **Download:** Hugging Face / Civitai link → models folder, with progress bars. *List folder* shows a folder's files.
- **Models:** every model file with a checkbox (filter by folder, *Select all*). *Delete selected* (after the confirm tick) removes them here and runs `vault backup --allow-delete`, so they leave R2 too; R2 keeps them in its trash until you empty it on the Vault tab.
- **Nodes:** install a custom node from a GitHub link; *Update all nodes*; *Refresh list* shows each node as loaded (green), failed (red) or waiting for a ComfyUI restart (orange).
- **Outputs:** send every output file (subfolders included, no zip) to the browser; *NEW only* skips files already downloaded.
- **Vault:** Backup now / Status / Restore; R2 trash (show, put back, delete); Backup & STOP / Backup & DESTROY / Stop now; Keep awake.
- **ComfyUI:** restart, show log.

Inside ComfyUI: **Download to Pod** (missing-models dialog) and **Civicomfy** (top bar) also save
straight to the server.

### What counts as "in use" (idle watcher)
ComfyUI jobs queued/running, clicking or typing in ComfyUI, GPU busy, a menu download/backup,
JupyterLab notebook or terminal use, or **Keep awake**. An open but untouched tab does not count.

---

## The vault (R2 layout)

| R2 path | Contents | Restored? |
|---|---|---|
| `comfyui/models`, `custom_nodes`, `user`, `input` | the ComfyUI folders | yes |
| `comfyui/jupyter` | JupyterLab settings | yes (first) |
| `comfyui/output` | your images/videos | no (backup only) |
| `comfyui/logs/<date>_<instance>/` | each instance's logs | no |
| `trash/<date>/…` | files a backup removed from the vault | via *Put back* |

Safety rules:
- An R2 error is never treated as "empty"; a failed or incomplete restore stops and is reported.
- Until a restore has fully succeeded on an instance, its backups only add files.
- One backup never removes more than 25 files / 5 GB from R2 (otherwise it warns; use
  `vault backup --allow-delete` if you really deleted them).
- Removed files go to `trash/`, never straight to deletion.

### `vault` commands (terminal)
```
vault status                         sizes here and in R2, last backup
vault backup [--allow-delete]        back up now
vault restore                        restore everything from R2
vault trash                          list R2 trash
vault undelete <date> [folder]       put trash back into the vault
vault empty-trash <date>|all --yes   permanently delete trash
vault shutdown stop|destroy          back up, then stop/destroy this instance
vault rclone <args>                  run rclone with the R2 remote, e.g. vault rclone lsf r2:comfyui-vault/comfyui
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Status page shows **SLOW HOST** or setup crawls | Bad host network. Destroy and rent another. |
| Cloudflare **error 1033** / HTTP 530 | Tunnel not connected, or hostnames on a different tunnel than the token. Compare `grep tunnelID /workspace/logs/cftunnel.log` with the DNS CNAME target. |
| Cloudflare **502** | The service on the instance is down, or an older instance is still connected to the tunnel (destroy it). |
| **RESTORE FAILED** banner | R2 couldn't be read reliably. The vault was not changed. Rent another host or run `vault restore`. |
| Restore seems stuck | A hung connection is retried after 60 s; watch the status page file bars. |
| JupyterLab can't open `models/checkpoints` | JupyterLab bug with folders named `checkpoints`. Use `/workspace/checkpoints-view` or *List folder*. |
| "Error displaying widget: model not found" when opening the menu | Old saved menu output; press Shift+Enter. |
| Menu shows old behaviour after an update | Kernel → Restart Kernel, then Shift+Enter. |

**Logs:** `/workspace/logs/` on the instance (provision, install_comfyui, comfyui, vault, watcher,
cftunnel, labvault, statuspage). The status page has *full setup log* / *full backup/restore log*
download links, and every backup copies the logs to `comfyui/logs/` in R2.
