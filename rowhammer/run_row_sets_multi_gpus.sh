#!/bin/bash

set -euo pipefail

echo ""
echo "-------------------------------------------"
echo ""
echo "[INFO] Starting Generation of Row Sets"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HAMMER_ROOT="${HAMMER_ROOT:-$SCRIPT_DIR}"
export HAMMER_ROOT

mkdir -p "$HAMMER_ROOT/results/row_sets"

declare -A bank_map; bank_map[0]=0; bank_map[256]='A'; bank_map[2048]='B'; bank_map[5120]='C'; bank_map[6400]='D';
bank_map[1024]='E'; bank_map[1280]='F'; bank_map[3072]='G'; bank_map[4096]='H';

# Accept an optional comma-separated GPU list as first arg or from CUDA_VISIBLE_DEVICES
# Usage: ./run_row_sets.sh 0,1,2,3
GPU_LIST_ARG=${1:-}
if [ -n "$GPU_LIST_ARG" ]; then
  IFS=',' read -ra GPUS <<< "$GPU_LIST_ARG"
elif [ -n "${CUDA_VISIBLE_DEVICES:-}" ]; then
  IFS=',' read -ra GPUS <<< "${CUDA_VISIBLE_DEVICES}"
else
  GPUS=(0)
fi

NUM_GPUS=${#GPUS[@]}
echo "[INFO] Using GPUs: ${GPUS[*]} (count=${NUM_GPUS})"

bank_vals=(256 2048 5120 6400 1024 1280)

pids=()
for gpu in "${GPUS[@]}"; do
  (
    echo "[INFO] Worker for GPU ${gpu} started"
    export CUDA_VISIBLE_DEVICES=${gpu}
    for val in "${bank_vals[@]}"; do
      label=${bank_map[$val]}
      conf_file="$HAMMER_ROOT/results/row_sets/CONF_SET_${label}_gpu${gpu}.txt"
      row_file="$HAMMER_ROOT/results/row_sets/ROW_SET_${label}_gpu${gpu}.txt"

      echo "[INFO] GPU ${gpu}: Starting bank ${label} (offset=${val})"
      python3 "$HAMMER_ROOT/util/run_timing_task.py" conf_set \
        --range $((47 * (2 ** 30))) \
        --size $((47 * (2 ** 30))) \
        --it 15 \
        --step 256 \
        --threshold 27 \
        --file "$conf_file" \
        --trgtBankOfs "$val"

      sleep 3s

      python3 "$HAMMER_ROOT/util/run_timing_task.py" row_set \
        --size $((47 * (2 ** 30))) \
        --it 15 \
        --threshold 27 \
        --trgtBankOfs "$val" \
        --outputFile "$row_file" \
        "$conf_file"

      echo "[INFO] GPU ${gpu}: Finished bank ${label} (offset=${val})"
      sleep 3s
    done
    echo "[INFO] Worker for GPU ${gpu} exiting"
  ) &
  pids+=("$!")
  sleep 3s
done

echo "[INFO] Waiting for ${#pids[@]} GPU workers to finish"
for pid in "${pids[@]}"; do
  wait "$pid"
done

echo "[INFO] Done. Row Sets are stored in '$HAMMER_ROOT/results/row_sets'"