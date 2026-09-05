#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
module load miniforge/25.11.0-0
. .venv/bin/activate
python reconstruct_uploaded.py
exec python app.py
