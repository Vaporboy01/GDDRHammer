import os, sys, subprocess
import argparse
import time
import csv
from datetime import datetime

HAMMER_ROOT = os.environ['HAMMER_ROOT']

AGG_CONFIG = {
    8  : {'warp' : 8,  'thread' : 1, 'round' : 3},
    9  : {'warp' : 9,  'thread' : 1, 'round' : 2},
    10 : {'warp' : 10, 'thread' : 1, 'round' : 2},
    11 : {'warp' : 11, 'thread' : 1, 'round' : 2},
    12 : {'warp' : 6,  'thread' : 2, 'round' : 2},
    13 : {'warp' : 7,  'thread' : 2, 'round' : 1},
    14 : {'warp' : 7,  'thread' : 2, 'round' : 1},
    15 : {'warp' : 8,  'thread' : 2, 'round' : 1},
    16 : {'warp' : 8,  'thread' : 2, 'round' : 1},
    17 : {'warp' : 9,  'thread' : 2, 'round' : 1},
    18 : {'warp' : 9,  'thread' : 2, 'round' : 2},
    19 : {'warp' : 10, 'thread' : 2, 'round' : 1},
    20 : {'warp' : 10, 'thread' : 2, 'round' : 1},
    21 : {'warp' : 7,  'thread' : 3, 'round' : 1},
    22 : {'warp' : 11, 'thread' : 2, 'round' : 1},
    23 : {'warp' : 8,  'thread' : 3, 'round' : 1},
    24 : {'warp' : 8,  'thread' : 3, 'round' : 1},
    36:  {'warp' : 9,  'thread' : 4, 'round' : 1},
    40:  {'warp' : 10, 'thread' : 4, 'round' : 1}
    }


def restricted_num_agg(x):
    if 8 <= int(x) <= 24: return x
    raise argparse.ArgumentTypeError("num_agg must be between 8 and 24 inclusive")

def get_delays_from_csv(csv_file, gpu_id):
    """ 
    Reads a CSV file and returns a dictionary mapping bank IDs to their
    respective delays for different numbers of aggressors for a specific GPU.
    The CSV file is expected to have columns: gpu,bank,num_agg,delay
    """
    delays = {}
    
    try:
        with open(csv_file, 'r') as f:
            reader = csv.DictReader(f)
            for row in reader:
                # Match the specific GPU ID
                if row['gpu'].strip() == str(gpu_id):
                    bank_id = row['bank'].strip()
                    num_agg = int(row['num_agg'].strip())
                    
                    # Check if delay value exists and is not empty
                    delay_str = row['delay'].strip()
                    if delay_str:
                        delay = int(delay_str)
                        
                        if bank_id not in delays:
                            delays[bank_id] = {}
                        delays[bank_id][num_agg] = delay
                    else:
                        print(f"Warning: No delay value for GPU {gpu_id}, Bank {bank_id}, num_agg {num_agg}")
    except FileNotFoundError:
        print(f"Error: CSV file {csv_file} not found.")
        sys.exit(1)
    except KeyError as e:
        print(f"Error: Missing expected column in CSV file: {e}")
        sys.exit(1)
    except ValueError as e:
        print(f"Error: Invalid value in CSV file: {e}")
        sys.exit(1)
    
    return delays

# ==============================================================================

parser = argparse.ArgumentParser()

parser.add_argument('--bank_ids', nargs='+', required=True,
                    help="List of bank IDs to run the Rowhammer on.")
parser.add_argument('--num_agg', type=int, nargs='*', default=[24],
                    help="List of number of aggressors to run the Rowhammer on. \
                        Must be between 8 and 24, inclusive.")
parser.add_argument('--data_pattern', choices=['checkered', 'opposite', 'all'], 
                    default='checkered',
                    help="Data pattern for padding victim and aggressor rows.")

# Hammering pattern parameters
parser.add_argument('--agg_distance', type=int, default=4,
                    help="Stride between aggressor rows in each hammering pattern.")
parser.add_argument('--skip_step', type=int, default=1,
                    help="Stride between hammering patterns.")
parser.add_argument('--pattern_iteration', type=int, default=1,
                    help="Number of iterations to repeat for each hammering pattern.")

# Device parameters
parser.add_argument('--mem_size', type=int, default=24696061952,
                    help="Size of allocatable GPU memory in bytes.")
parser.add_argument('--num_rows', type=int, default=31402,
                    help="Number of rows in each bank.")
parser.add_argument('--addr_step', type=int, default=256,
                    help="Stride between addresses in the row set file. \
                        Must match the 'step' parameter used to generate row sets.")
parser.add_argument('--trefi', type=int, default=1407,
                    help="tREFI in nanoseconds.")

# Path parameters
parser.add_argument('--hammer_root', type=str, default=HAMMER_ROOT,
                    help="Path to the gpuhammer repository.")
parser.add_argument('--row_set_dir', type=str, 
                    default=os.path.join(HAMMER_ROOT, 'results', 'row_sets'),
                    help="Path to the directory containing the row set files")
parser.add_argument('--output_dir', type=str, 
                    default=os.path.join(HAMMER_ROOT, 'results', 'Rowhammer'),
                    help="Path to store the results of the Rowhammer.")
parser.add_argument('--delay_file', type=str, 
                    default=os.path.join(HAMMER_ROOT, 'results', 'results', 'delay.csv'),
                    help="Path to the CSV file containing delay amounts.")
parser.add_argument('--num_bank', type=int, default=4,
                    help="Number of banks to use for multi-bank Rowhammer.")

parser.add_argument('--run_time', type=int, default=6*3600,
                    help="Total run time in seconds for the multi-bank Rowhammer (default: 4 hours).")
parser.add_argument('--hammer_count', type=int, default=64000,
                    help="Number of hammering acts to run.")

# GPU selection parameter
parser.add_argument('--gpu_id', type=str, default='0',
                    help="GPU ID to use for this Rowhammer instance.")

args = parser.parse_args()

# ==============================================================================

# Set CUDA_VISIBLE_DEVICES to the specified GPU
os.environ['CUDA_VISIBLE_DEVICES'] = args.gpu_id
print(f"[INFO] Running on GPU {args.gpu_id}")

hammer_path = os.path.join(args.hammer_root, 'src/out/build/multibank_hammer')
if not os.path.isfile(hammer_path):
    print(f"Error: {hammer_path} does not exist. Please build the executables \
          and set the HAMMER_ROOT environment variable.")
    sys.exit(1)
if not os.path.exists(args.row_set_dir):
    print(f"Error: Row set directory {args.row_set_dir} does not exist. \
          Please ensure the row sets are generated and available.")
    sys.exit(1)
if not os.path.isfile(args.delay_file):
    print(f"Error: Delay file {args.delay_file} does not exist. \
          Please ensure the delay file is generated and available.")
    sys.exit(1)
if not os.path.exists(args.output_dir):
    os.makedirs(args.output_dir)

# Generate pairs of data patterns for (victim, aggressor)
DATA_PATTERNS = [f"{i:01x}"*2 for i in range(16)]
if args.data_pattern == 'checkered':
    data_pattern_pairs = [('00','ff'), ('ff','00')]
elif args.data_pattern == 'opposite':
    data_pattern_pairs = [(pat, pat) for pat in DATA_PATTERNS]
elif args.data_pattern == 'all':
    data_pattern_pairs = [(pat1, pat2) for pat1 in DATA_PATTERNS for pat2 in DATA_PATTERNS]

# Load delays from CSV file for the specific GPU
delays = get_delays_from_csv(args.delay_file, args.gpu_id)
print(f"[INFO] Loaded delays for GPU {args.gpu_id}: {delays}")




if 'multi_banks' in args.bank_ids:
    print(f"\n=== Starting multi-bank Rowhammer on GPU {args.gpu_id} ===\n")

    # Define canonical bank list to choose from (order matters for selection)
    BANKLIST = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']

    # Validate requested num_bank
    if args.num_bank < 1 or args.num_bank > len(BANKLIST):
        print(f"Error: --num_bank must be between 1 and {len(BANKLIST)} (inclusive).")
        sys.exit(1)

    # Collect available banks from BANKLIST in order until we have args.num_bank
    # For multi-GPU setup, try to find GPU-specific row set files first
    available_banks = []
    for bank_id in BANKLIST:
        if len(available_banks) >= args.num_bank:
            break
        
        # Try GPU-specific row set file first
        row_set_file_gpu = os.path.join(args.row_set_dir, f'ROW_SET_{bank_id}_gpu{args.gpu_id}.txt')
        row_set_file_default = os.path.join(args.row_set_dir, f'ROW_SET_{bank_id}.txt')
        
        if os.path.isfile(row_set_file_gpu):
            available_banks.append((bank_id, row_set_file_gpu))
            print(f"[INFO] Using GPU-specific row set: {row_set_file_gpu}")
        elif os.path.isfile(row_set_file_default):
            available_banks.append((bank_id, row_set_file_default))
            print(f"[INFO] Using default row set: {row_set_file_default}")
        else:
            print(f"Warning: Row set file for {bank_id} does not exist, skipping bank")

    if len(available_banks) < args.num_bank:
        print(f"Error: Requested {args.num_bank} banks but only found {len(available_banks)} available row set files.")
        sys.exit(1)

    print(f"Selected banks for multi-bank Rowhammer: {[b[0] for b in available_banks]}")

    # Create multi-bank output directory
    multi_bank_dir = os.path.join(args.output_dir, 'multi_banks')
    if not os.path.exists(multi_bank_dir):
        os.makedirs(multi_bank_dir)

    for num_agg in args.num_agg:
        print(f"\n=== Starting multi-bank Rowhammer with {num_agg}-sided patterns on GPU {args.gpu_id} ===\n")

        # Get delays for the selected banks
        # print(delays)
        bank_delays = {}
        for bank_id, _ in available_banks:
            delay = delays.get(bank_id, {}).get(num_agg)
            if delay is None:
                print(f"Warning: No delay found for bank {bank_id} with {num_agg} aggressors.")
                break
            bank_delays[bank_id] = delay

        if len(bank_delays) != len(available_banks):
            print(f"Error: Missing delay entries for some selected banks for {num_agg} aggressors. Skipping this agg count.")
            continue

        for victim_pattern, aggressor_pattern in data_pattern_pairs:
            print(f"Testing victim pattern '0x{victim_pattern}' and aggressor pattern '0x{aggressor_pattern}' across {len(available_banks)} banks")

            output_log_file = os.path.join(multi_bank_dir, 
                                f'{num_agg}agg_{victim_pattern}{aggressor_pattern}_log.txt')
            output_flip_file = os.path.join(multi_bank_dir, 
                                f'{num_agg}agg_{victim_pattern}{aggressor_pattern}_flip_count.txt')

            with open(output_log_file, 'w') as log_file:
                log_file.write(f"\n=== Started at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ===\n")
                log_file.write(f"Running multi-bank Rowhammer with {num_agg} aggressors across banks: {[b[0] for b in available_banks]}\n")
                log_file.write(f"GPU ID: {args.gpu_id}\n")
                log_file.flush()

                # Use the new multi-bank hammer program for true simultaneous multi-bank hammering
                multi_bank_hammer_path = os.path.join(args.hammer_root, 'src/out/build/multibank_hammer')

                # Prepare command line arguments for multi-bank hammer
                cmd_args = [
                    multi_bank_hammer_path,         # Path to the multi-bank hammer executable
                    str(len(available_banks)),      # num_banks
                ]

                # Add row set files for all selected banks
                for bank_id, row_set_file in available_banks:
                    cmd_args.append(row_set_file)

                # Add common parameters
                cmd_args.extend([
                    str(num_agg),                   # num_aggressors
                    str(args.addr_step),            # step
                    str(args.hammer_count),         # iterations
                    str(6),                         # min_rowid
                    str(args.num_rows - 150),       # max_rowid
                    str(args.agg_distance),         # row_step
                    str(args.skip_step),            # skip_step
                    str(args.mem_size),             # mem_size
                    str(AGG_CONFIG[num_agg]['warp']),       # num_warp
                    str(AGG_CONFIG[num_agg]['thread']),     # num_thread
                ])

                # Add delays for each selected bank
                for bank_id, _ in available_banks:
                    cmd_args.append(str(bank_delays[bank_id]))

                # Insert run_time (seconds) so the C++ binary runs for a time limit
                cmd_args.append(str(args.run_time))

                # Add remaining parameters
                cmd_args.extend([
                    str(AGG_CONFIG[num_agg]['round']),      # round
                    str(args.pattern_iteration),            # count_iter
                    str(args.num_rows),                     # num_rows
                    victim_pattern,                         # vic_pat
                    aggressor_pattern,                      # agg_pat
                    output_flip_file                        # output file
                ])

                log_file.write(f"\n--- Running multi-bank hammer with command: {' '.join(cmd_args)} ---\n")
                log_file.flush()

                subprocess.run(cmd_args, stdout=log_file, stderr=subprocess.STDOUT)

                log_file.write(f"\n=== Completed at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ===\n")

            time.sleep(3)

    print(f"\n=== Multi-bank Rowhammer on GPU {args.gpu_id} completed ===\n")
else:
    print("Error: Only 'multi_banks' mode is supported in this multi-GPU script.")
    sys.exit(1)
