#!/bin/bash

core=$1
mem=$2

for i in {0..7}; do
    echo "Setting GPU $i: core=${core} MHz, mem=${mem} MHz"
    sudo nvidia-smi -i $i -pm 1
    sudo nvidia-smi -i $i -lgc $core,$core
    sudo nvidia-smi -i $i -lmc $mem,$mem
done

for i in {0..7}; do
    sudo nvidia-smi -i $i -pm 1
done

echo "All 8 GPUs have been locked."
