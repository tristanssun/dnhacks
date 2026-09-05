"""Modal deployment for the MapAnything Gradio application.

Development: modal serve modal_app.py
Persistent:  modal deploy modal_app.py
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import modal

APP_DIR = "/opt/dnhacks"
DATA_DIR = "/data"
PORT = 7860
LOCAL_ROOT = Path(__file__).resolve().parent

# Set MODAL_KEEP_WARM=1 while deploying to continuously reserve one GPU. The
# default scales to zero after 20 idle minutes and keeps the public URL active.
keep_warm = int(os.getenv("MODAL_KEEP_WARM", "0"))
gpu_type = os.getenv("MODAL_GPU", "H200")

image = (
    modal.Image.from_registry(
        "nvidia/cuda:12.9.1-cudnn-runtime-ubuntu24.04", add_python="3.12"
    )
    .apt_install("ffmpeg", "git", "libgl1", "libglib2.0-0")
    .add_local_dir(
        LOCAL_ROOT,
        remote_path=APP_DIR,
        copy=True,
        ignore=[
            ".git/**", ".venv/**", "outputs/**", "uploads/**",
            "live_sessions/**", "__pycache__/**", "*.pyc", "*.zip",
            "*.MOV", "*.mov", "*.MP4", "*.mp4", "*.pdf",
        ],
    )
    .run_commands(
        "python -m pip install torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0 "
        "--index-url https://download.pytorch.org/whl/cu129",
        f"cd {APP_DIR} && python -m pip install -r requirements.txt",
    )
    .env({
        "DATA_ROOT": DATA_DIR,
        "HF_HOME": f"{DATA_DIR}/huggingface",
        "TORCH_HOME": f"{DATA_DIR}/torch",
        "GRADIO_TEMP_DIR": f"{DATA_DIR}/gradio-temp",
        "HOST": "0.0.0.0",
        "PORT": str(PORT),
        "PYTHONUNBUFFERED": "1",
    })
)

app = modal.App("dnhacks-mapanything-v2-modal")
data_volume = modal.Volume.from_name("dnhacks-mapanything-data", create_if_missing=True)


@app.function(
    image=image,
    gpu=gpu_type,
    timeout=24 * 60 * 60,
    startup_timeout=20 * 60,
    min_containers=keep_warm,
    max_containers=1,
    scaledown_window=20 * 60,
    volumes={DATA_DIR: data_volume},
)
@modal.concurrent(max_inputs=32)
@modal.web_server(PORT, startup_timeout=20 * 60)
def ui():
    """Launch the GPU-backed Gradio server."""
    subprocess.Popen(["python", "app.py"], cwd=APP_DIR)
