#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 JOB_ID USER@LOGIN-HOST" >&2
  exit 2
fi

job_id="$1"
login="$2"
node="$(squeue -h -j "$job_id" -o '%N')"
if [[ -z "$node" || "$node" == "(null)" ]]; then
  echo "Job $job_id is not running yet (or no longer exists)." >&2
  exit 1
fi
user="${login%@*}"
echo "On your laptop, keep this command open:"
echo "ssh -N -J ${login} -L 7860:localhost:7860 ${user}@${node}"
echo "Then open http://localhost:7860"
