#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p outputs
job_id="$(sbatch --parsable \
  --partition=mit_normal_gpu \
  --gres=gpu:h200:1 \
  --cpus-per-task=16 \
  --mem=128G \
  --time="${SLURM_TIME:-06:00:00}" \
  --job-name=mapanything-ui \
  --output=outputs/server-%j.log \
  --wrap="$(pwd)/scripts/reconstruct_and_serve.sh")"
echo "Submitted MapAnything UI as Slurm job ${job_id}"
echo "Wait for it with: squeue -j ${job_id}"
echo "Then run: ./scripts/tunnel.sh ${job_id} USER@LOGIN-HOST"
