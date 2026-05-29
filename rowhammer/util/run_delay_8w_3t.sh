# Run the synchronization test with GPU selection

# Variables
gpu_id=1            # GPU ID to use (default: 0)
bank_id=B  

num_agg=24          # Number of aggressors
num_warp=8          # Number of warps
num_thread=3        # Number of threads per warp
round=1            # No. of round per tREFI, each round hammers <num_agg> rows

min_delay=1000         # Minimum delay to test
max_delay=500       # Maximum delay to test

num_rows=31402      # Number of rows in the row_set (line number - 1)
# num_rows=61437      
rowid=13371           # Id of a row to test the delays, can be arbitrary
iterations=10000

# Memory Properties
addr_step=256           # Set to be the <step> parameter used in finding conf_set/row_set
mem_size=24696061952    # Bytes of memory allocated for hammering (recommend: size of memory - 1GB)
# mem_size=48318382080

# Parse command line arguments
if [ $# -ge 1 ]; then
    gpu_id=$1
fi
if [ $# -ge 2 ]; then
    bank_id=$2
fi

echo "Using GPU: $gpu_id"
echo "Using Bank: $bank_id"

# File paths
rowset_file="$HAMMER_ROOT/results/row_sets/ROW_SET_${bank_id}_gpu${gpu_id}.txt"
time_file="$HAMMER_ROOT/results/delay_files/delay_8w_3t_gpu${gpu_id}_bank${bank_id}.txt"
log_file="$HAMMER_ROOT/results/delay_files/log_gpu${gpu_id}.txt"

> $log_file
> $time_file


# Running the test
nvidia-smi -q > $log_file
echo "Start hammering on GPU $gpu_id ..."

$HAMMER_ROOT/src/out/build/sync_delay_gpu_select $gpu_id $rowset_file $((num_agg - 1)) $addr_step $iterations $rowid $mem_size $time_file $num_warp $num_thread $round $min_delay $max_delay $num_rows >> $log_file 2>&1

echo "Hammering done."
