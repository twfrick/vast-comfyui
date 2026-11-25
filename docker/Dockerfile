# syntax=docker/dockerfile:1
# =============================================================================
# ComfyUI-Vault image  -  vastai/pytorch + everything the setup used to install
#
# Built by GitHub Actions (.github/workflows/build-image.yml) and pushed to
#   ghcr.io/twfrick/vast-comfyui:latest
#
# What is pre-installed (so a new instance skips these steps):
#   * system packages: git, ffmpeg, aria2, libgl1, libglib2.0-0, unzip
#   * rclone (current) and cloudflared  -> /opt/vault
#   * JupyterLab + ipywidgets            -> /venv/main
#   * ComfyUI + its requirements + Manager requirements -> /opt/comfyui-image/ComfyUI
#     (copied to /workspace/ComfyUI on first start, then updated with git pull)
#   * default nodes: ComfyUI-RunpodDirect, Civicomfy (+ requirements)
#   * SageAttention 2 compiled for RTX 30xx/A6000 (8.6), RTX 40xx/6000 Ada (8.9),
#     RTX 50xx/RTX PRO Blackwell (12.0)
#
# Your models, nodes, workflows and settings are NOT in the image: they still come
# from your R2 vault at startup. No tokens or secrets are stored in the image.
# =============================================================================
ARG BASE_IMAGE=vastai/pytorch:cuda-12.8.1-auto
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG SAGE_ARCHS="8.6;8.9;12.0"
ARG SAGE_REF=main
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    UV_NO_CACHE=1

# --- system packages ---------------------------------------------------------------------------
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends git ffmpeg aria2 libgl1 libglib2.0-0 unzip ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# --- rclone (the image's old rclone fails on R2) + cloudflared ---------------------------------
RUN mkdir -p /opt/vault && tmp=$(mktemp -d) \
 && curl -fsSL -o "$tmp/rclone.zip" https://downloads.rclone.org/rclone-current-linux-amd64.zip \
 && unzip -q "$tmp/rclone.zip" -d "$tmp" \
 && install -m 755 "$tmp"/rclone-*-linux-amd64/rclone /opt/vault/rclone \
 && curl -fsSL -o /opt/vault/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
 && chmod 755 /opt/vault/cloudflared \
 && rm -rf "$tmp" \
 && /opt/vault/rclone version | head -1 && /opt/vault/cloudflared --version

# pip helper: uv if the base image has it (fast), otherwise pip
RUN printf '#!/bin/bash\nif command -v uv >/dev/null 2>&1; then exec uv pip install --python /venv/main/bin/python "$@"; else exec /venv/main/bin/python -m pip install "$@"; fi\n' \
        > /usr/local/bin/vpip && chmod 755 /usr/local/bin/vpip

# Lock the image's PyTorch so nothing below replaces it
RUN /venv/main/bin/python - > /opt/vault/torch-constraints.txt <<'EOF'
import importlib.metadata as m
for p in ("torch", "torchvision", "torchaudio"):
    print(f"{p}=={m.version(p)}")
EOF
RUN cat /opt/vault/torch-constraints.txt

# --- JupyterLab for the "Vault Lab" + menu -----------------------------------------------------
RUN vpip -c /opt/vault/torch-constraints.txt jupyterlab ipywidgets \
 && (/usr/bin/python3 -m pip install -q --break-system-packages ipywidgets 2>/dev/null || true)

# --- ComfyUI + requirements ---------------------------------------------------------------------
RUN mkdir -p /opt/comfyui-image \
 && git clone https://github.com/comfyanonymous/ComfyUI.git /opt/comfyui-image/ComfyUI \
 && cd /opt/comfyui-image/ComfyUI \
 && vpip -c /opt/vault/torch-constraints.txt -r requirements.txt \
 && if [ -f manager_requirements.txt ]; then vpip -c /opt/vault/torch-constraints.txt -r manager_requirements.txt; fi \
 && git log -1 --format="ComfyUI %h (%cd)" --date=short | tee /opt/comfyui-image/COMFYUI_VERSION

# --- default nodes (server-side model downloads) ------------------------------------------------
RUN cd /opt/comfyui-image/ComfyUI/custom_nodes \
 && for url in https://github.com/MadiatorLabs/ComfyUI-RunpodDirect https://github.com/MoonGoblinDev/Civicomfy; do \
        d=$(basename "$url"); git clone --depth 1 "$url.git" "$d"; \
        if [ -f "$d/requirements.txt" ]; then vpip -c /opt/vault/torch-constraints.txt -r "$d/requirements.txt"; fi; \
    done

# --- SageAttention 2 (compiled here, no GPU needed: target GPUs listed in SAGE_ARCHS) -----------
# Low parallelism on purpose: GitHub's free build machines have 16 GB RAM and nvcc is hungry.
RUN vpip ninja packaging wheel setuptools \
 && tmp=$(mktemp -d) && git clone https://github.com/thu-ml/SageAttention.git "$tmp/sage" \
 && cd "$tmp/sage" && git checkout "$SAGE_REF" \
 && export CUDA_HOME=/usr/local/cuda PATH=/usr/local/cuda/bin:$PATH TORCH_CUDA_ARCH_LIST="$SAGE_ARCHS" MAX_JOBS=2 EXT_PARALLEL=2 NVCC_APPEND_FLAGS="--threads 2" \
 && /venv/main/bin/python -m pip install --no-build-isolation --no-deps -c /opt/vault/torch-constraints.txt . \
 && cd / && rm -rf "$tmp" \
 && /venv/main/bin/python -c "import importlib.metadata as m; print('SageAttention', m.version('sageattention'))"

# --- image info (install_comfyui.sh reads this) -------------------------------------------------
RUN { echo "IMAGE_BUILT=$(date -u +%Y-%m-%dT%H:%MZ)"; \
      echo "SAGE_ARCHS=$SAGE_ARCHS"; \
      echo "SAGE_VERSION=$(/venv/main/bin/python -c 'import importlib.metadata as m; print(m.version("sageattention"))')"; \
      echo "TORCH=$(tr '\n' ' ' < /opt/vault/torch-constraints.txt)"; \
      echo "COMFYUI=$(cat /opt/comfyui-image/COMFYUI_VERSION)"; } > /opt/comfyui-image/IMAGE_INFO \
 && cat /opt/comfyui-image/IMAGE_INFO

ENV DEBIAN_FRONTEND=
