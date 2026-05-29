# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GDDRHammer is a research artifact for IEEE S&P 2026 demonstrating Rowhammer attacks on GDDR6-based GPUs. It has two components:

- **`rowhammer/`** — Double-sided multibank hammering with synchronized activation sequences for amplifying Rowhammer on GDDR6 memory (§4 of the paper)
- **`exploit/`** — End-to-end GPU-to-CPU Rowhammer exploit using bit flips in GPU memory to gain arbitrary read/write access to host CPU memory (§6 of the paper)

## Target Hardware

- **NVIDIA RTX 4090** with 24GB GDDR6X (Micron DRAM)
- 原论文针对 RTX A6000 (Ampere, Samsung DRAM, sm_86)，当前适配到 Ada Lovelace 架构 (sm_89)

## Build & Run Commands

### Rowhammer (`rowhammer/`)

```bash
cd rowhammer
export HAMMER_ROOT=$(pwd)
cmake -S ./src -B ./src/out/build
cd ./src/out/build && make
```

Three-step pipeline (all run from `rowhammer/`):

1. **Generate row sets** — `bash run_row_sets_multi_gpus.sh 0`
2. **Determine nop delay** — `bash run_delay_multi_gpus.sh 0 && python util/process_delays.py results/delay_files/`
3. **Run multibank hammer** — `bash run_multibank_hammer_multi_gpus.sh 0`
4. **Parse results** — `python util/parse_flips.py <log.txt>`

Lock GPU frequencies before experiments: `bash ./util/lock_freq.sh <MAX_GPU_CLOCK> <MAX_MEMORY_CLOCK>`

### Exploit (`exploit/`)

```bash
cd exploit && make
```

## Architecture

### `rowhammer/src/` — CMake-based CUDA project (C++17/CUDA 17)

**Shared libraries:**
- `hammer_lib` (`include/rh_kernels.cu`, `rh_utils.cu`, `rh_impls.cu`) — Core Rowhammer CUDA kernels and host-side orchestration. Key types: `RowList` = `vector<vector<uint8_t*>>`, `MEM_PAT` enum for victim/aggressor data patterns.
- `re_lib` (`re_gddr/drama_conflict_prober.cu`) — DRAM address conflict probing for reverse-engineering bank/row mappings. `ConflictProber` class measures access timing to identify same-bank addresses.

**Executables** — Each has a `*_main.cu` linking against the libraries:
- Reverse engineering: `conf_set`, `row_set`, `bank_set`, `gen_time`, `gen_time_same`, `load_modifiers`
- Hammering: `multibank_hammer` (main attack binary), `sync_delay_gpu_select` (timing calibration)

**CUDA kernel hierarchy:**
- `simple_hammer_kernel` — Single-warp hammering
- `warp_simple_hammer_kernel_seq` — Multi-warp synchronized hammering with nop delay
- `multi_bank_hammer_kernel` — Parallel hammering across multiple DRAM banks with per-bank delays

**Orchestration scripts** — Shell scripts in `rowhammer/` and Python scripts in `rowhammer/util/` wrap compiled binaries for multi-GPU parallel execution via background processes. `HAMMER_ROOT` env var points to `rowhammer/`. Results go under `results/`.

### `exploit/` — Standalone nvcc build

Two CUDA programs (`make_secret.cu`, `mem_read_time.cu`) compiled directly with nvcc. Helper scripts in `exploit/scripts/` and `exploit/pyscripts/`.

## Environment Requirements

- NVIDIA RTX 4090 (Ada Lovelace, 24GB GDDR6X, Micron DRAM), ECC disabled
- Ubuntu 22.04, CMake 3.26+, CUDA 12.6+, NVIDIA-SMI 560+
- CMakeLists.txt 已设 `CMAKE_CUDA_ARCHITECTURES 89`，exploit Makefile 仍为 sm_86，需同步改为 sm_89
