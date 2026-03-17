#!/bin/bash

# Multi-GPU parallel runner for determine how many nops to add to synchronize the trefi
# Usage: ./run_delay_multi_gpus.sh <gpu_id> [<gpu_id> ...]
# Example: ./run_delay_multi_gpus.sh 0 1 2 3

set -euo pipefail

echo ""
echo "-------------------------------------------"
echo ""
echo "[INFO] Starting Experiments for calculating delay (multi-GPU parallel)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$SCRIPT_DIR}"
export HAMMER_ROOT

# Ensure results directory exists
mkdir -p "$HAMMER_ROOT/results/delay_files"

if [ $# -lt 1 ]; then
  echo "Usage: $0 <gpu_id> [<gpu_id> ...]" 1>&2
  exit 1
fi

GPUS=("$@")

echo "[INFO] Using GPUs: ${GPUS[*]}"

pids=()
for gpu_id in "${GPUS[@]}"; do
  (
    echo "[INFO] Worker for GPU ${gpu_id} started"
    for bank_id in A B C D E F; do
      echo ""
      echo "-------------------------------------------"
      echo ""
      echo "[INFO] Starting sychronization test on GPU ${gpu_id} Bank ${bank_id}"
      bash "$HAMMER_ROOT/util/run_delay_8w_3t.sh" "${gpu_id}" "${bank_id}"
      sleep 3s
    done
    echo "[INFO] Worker for GPU ${gpu_id} exiting"
  ) &
  pids+=("$!")
  sleep 1s
done

echo "[INFO] Waiting for ${#pids[@]} GPU workers to finish"
for pid in "${pids[@]}"; do
  wait "$pid"
done

echo "[INFO] Done. Delay experiments are stored in 'results/delay_files'"
