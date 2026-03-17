# Rowhammering GPU

This fold contains the implementation of the GPU Rowhammer techniques described in Section 4.

The implementation coordinates multiple GPU warps to issue carefully ordered memory accesses within refresh intervals while performing parallel hammering across multiple DRAM banks. By combining partially synchronized hammering sequences with multi-bank parallel execution, the system can efficiently trigger Rowhammer-induced bit flips in GDDR6 memory.


## Required Environment
- Hardware Requirements:
   - NVIDIA RTX A6000 Ampere GPU (Samsung DRAM)

- Software Requirements:
   - Ubuntu 22.04
   - CMake 3.26+
   - g++ with C++17 Support
   - NVIDIA CUDA 12.6+
   - NVIDIA-SMI 560+

## Prerequisites

### 1. Disable ECC

For the Rowhammer attack, a prerequiste is having **ECC disabled**. This is already the default setting on A6000 GPUs. But if it is enabled, use the following commands to disable it:
```bash
for i in $(nvidia-smi --query-gpu=index --format=csv,noheader); do
    sudo nvidia-smi -i $i -e 0
done
sudo reboot
```

### 2. Lock Frequency

The number of **nop** is easier to be determined with the persistence mode enabled, and with fixed GPU and memory clock rates. The following script locks the frequence of all 8 GPUs in one machine:
```bash
# Example usage: 
#  bash ./util/lock_freq.sh <MAX_GPU_CLOCK> <MAX_MEMORY_CLOCK>
bash ./util/lock_freq.sh 1800 7600
```


## Building
Generate the build files and compile:

```bash
cd rowhammer
export HAMMER_ROOT=`pwd`
cmake -S ./src -B ./src/out/build
cd ./src/out/build
make
```

## Running

### 1. Generating Rowset from the same bank
By default this generate the rowsets of 6 banks, since 6 is the optimal number for multibank hammer in Section 4. Results are stored in results/row_sets.

```bash
# Accept an optional comma-separated GPU list as first arg or from CUDA_VISIBLE_DEVICES
bash run_row_sets_multi_gpus.sh 0
```


### 2. Determining nop number to synchronize with the trefi
This step determine the number of nops added after each hammer iteration. Results are stored in results/delay/delay.csv
```bash
bash run_delay_multi_gpus.sh 0
python util/process_delays.py  results/delay_files/
```

### 3. Running Multibank Rowhammer
Results and log file are stored in results/hammer. By default, the code runs 6 banks hammer for 6 hours with victim-aggressor data pattern 0x00 and 0xff, respectively. 
```bash
bash run_multibank_hammer_multi_gpus.sh 0
```


### 4. Parsing the log file
We have already prepare a python file to parse the log file to count the unique flips and calculate the flips/GB and flips/hour.
```bash
python util/parse_flips <log.txt>
```

