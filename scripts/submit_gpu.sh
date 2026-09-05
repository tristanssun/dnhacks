#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p outputs
exec sbatch --parsable \
  --partition=mit_normal_gpu \
  --gres=gpu:h200:1 \
  --cpus-per-task=16 \
  --mem=128G \
  --time=06:00:00 \
  --job-name=mapanything-ui \
  --output=outputs/server-%j.log \
  --wrap="$(pwd)/scripts/reconstruct_and_serve.sh"
