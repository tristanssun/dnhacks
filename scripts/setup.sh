#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
module load miniforge/25.11.0-0
python -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu129
python -m pip install -r requirements.txt
