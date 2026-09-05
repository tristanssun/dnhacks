#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
module load miniforge/25.11.0-0
python -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
# Keep the three compiled PyTorch packages on the same release. Uniception
# depends on torchaudio, so allowing pip to choose it independently can produce
# an ABI mismatch even though MapAnything itself imports successfully.
python -m pip install \
  torch==2.11.0+cu129 \
  torchvision==0.26.0+cu129 \
  torchaudio==2.11.0+cu129 \
  --index-url https://download.pytorch.org/whl/cu129
python -m pip install -r requirements.txt
