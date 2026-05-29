#!/bin/bash

set -euo pipefail

echo ""
echo "-------------------------------------------"
echo ""
echo "[INFO] Starting Multi-GPU Multi--bank Rowhammer"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$SCRIPT_DIR}"
export HAMMER_ROOT

export CUDA_VISIBLE_DEVICES=0

# Accept an optional comma-separated GPU list as first arg or from CUDA_VISIBLE_DEVICES
# Usage: ./run_multibank_hammer_multi_gpus.sh 0,1,2,3
GPU_LIST_ARG=${1:-}
if [ -n "$GPU_LIST_ARG" ]; then
  IFS=',' read -ra GPUS <<< "$GPU_LIST_ARG"
elif [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
  IFS=',' read -ra GPUS <<< "${CUDA_VISIBLE_DEVICES}"
else
  # Default to single GPU 0
  GPUS=(0)
fi

NUM_GPUS=${#GPUS[@]}
echo "[INFO] Using GPUs: ${GPUS[*]} (count=${NUM_GPUS})"

num_bank_list=(6)

pids=()
for gpu in "${GPUS[@]}"; do
  (
    echo "[INFO] Worker for GPU ${gpu} started"
    export CUDA_VISIBLE_DEVICES=${gpu}
    
    for num_bank in "${num_bank_list[@]}"; do
      echo "[INFO] GPU ${gpu}: Running multi-bank Rowhammer for ${num_bank} banks ..."
      
      output_dir="$HAMMER_ROOT/results/test_${num_bank}banks_gpu${gpu}_11_6"
      
      python3 "$HAMMER_ROOT/util/run_multibank_multi_gpus.py" \
        --bank_ids multi_banks \
        --num_bank "$num_bank" \
        --num_agg 24 \
        --output_dir "$output_dir" \
        --delay_file "$HAMMER_ROOT/results/delay/delay.csv" \
        --gpu_id "$gpu" \
        --run_time 10800 \
      
      echo "[INFO] GPU ${gpu}: Finished ${num_bank} banks Rowhammer"
      sleep 5s
    done

    echo "[INFO] Worker for GPU ${gpu} exiting"
  ) &
  pids+=("$!")
  # small stagger between launching workers
  sleep 3s
done

echo "[INFO] Waiting for ${#pids[@]} GPU workers to finish"
for pid in "${pids[@]}"; do
  wait "$pid"
done

echo "[INFO] Done. All multi-bank Rowhammer completed across all GPUs."
