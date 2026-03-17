#!/usr/bin/env python3
import argparse
import csv
import os
import re
from pathlib import Path
from typing import Dict, List, Tuple

MIN_NS_DEFAULT = 14_000_000
MAX_NS_DEFAULT = 15_000_000
TOLERANCE_NS = 120_000  # allow small fluctuations within ~0.12 ms
TARGET_NS = 14_070_000


def find_stable_delay_index(time_lst: List[int], min_ns: int = MIN_NS_DEFAULT, max_ns: int = MAX_NS_DEFAULT) -> int:
    """Return the middle index of the longest consecutive window whose values
    are within [min_ns, max_ns] and whose local max-min <= TOLERANCE_NS.

    If none found, return -1.
    """
    best_start = -1
    best_len = 0

    n = len(time_lst)
    for start in range(n):
        first = time_lst[start]
        if first < min_ns or first > max_ns:
            continue
        local_min = first
        local_max = first
        for end in range(start, n):
            t = time_lst[end]
            if t < min_ns or t > max_ns:
                break
            if t < local_min:
                local_min = t
            if t > local_max:
                local_max = t
            if (local_max - local_min) <= TOLERANCE_NS:
                cur_len = end - start + 1
                if cur_len > best_len:
                    best_len = cur_len
                    best_start = start
            else:
                break

    if best_len == 0:
        return -1
    return best_start + best_len // 2


def pick_closest_to_target(time_lst: List[int], target_ns: int = TARGET_NS) -> int:
    best_idx = 0
    best_diff = None
    for i, t in enumerate(time_lst):
        diff = t - target_ns if t >= target_ns else target_ns - t
        if best_diff is None or diff < best_diff:
            best_diff = diff
            best_idx = i
    return best_idx


def read_numeric_times(file_path: Path) -> List[int]:
    times: List[int] = []
    with file_path.open('r', encoding='utf-8', errors='ignore') as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            # accept leading integer per line
            m = re.match(r"^([0-9]+)", s)
            if m:
                try:
                    times.append(int(m.group(1)))
                except ValueError:
                    continue
    return times


FNAME_RE = re.compile(
    # Matches:
    #   delay_<w>w_<t>t_gpu<gpu>_bank<bank>[.txt]
    #   delay_<w>w_<t>t_<extra>_gpu<gpu>_bank<bank>[.txt]
    # Optional extra token between t and gpu is supported.
    r"^delay_(?P<w>\d+)w_(?P<t>\d+)t(?:_[^_]+)?_gpu(?P<gpu>\d+)_bank(?P<bank>[A-Za-z])",
    re.IGNORECASE,
)


def parse_meta_from_name(name: str) -> Tuple[int, str, int]:
    """Return (gpu, bank, num_agg) parsed from filename.
    num_agg = w * t extracted from the leading 'delay_<w>w_<t>t'.
    """
    m = FNAME_RE.search(name)
    if not m:
        raise ValueError(f"Unrecognized delay filename pattern: {name}")
    w = int(m.group('w'))
    t = int(m.group('t'))
    gpu = int(m.group('gpu'))
    bank = m.group('bank').upper()
    num_agg = w * t
    return gpu, bank, num_agg


def compute_stable_value(times: List[int]) -> int:
    if not times:
        raise ValueError("Empty time list")
    idx = find_stable_delay_index(times, MIN_NS_DEFAULT, MAX_NS_DEFAULT)
    print(f"Stable index found at: {idx}")
    if idx < 0:
        idx = pick_closest_to_target(times, TARGET_NS)
    # kernel scanned [2000, 4000), so index maps to delay value by +2000
    stable_value = idx + 1000
    return int(stable_value)


def collect_delay_files(in_dir: Path) -> List[Path]:
    files = []
    for entry in in_dir.iterdir():
        if not entry.is_file():
            continue
        name = entry.name
        if not name.startswith('delay'):
            continue
        # filter to .txt too if present, but keep generic
        files.append(entry)
    return files


def main():
    parser = argparse.ArgumentParser(description="Process delay files and output CSV.")
    parser.add_argument("input_dir", type=str, help="Directory containing delay* files (e.g., results/fig10)")
    parser.add_argument("-o", "--out", type=str, default="results/delay/delay.csv", help="Output CSV path")
    args = parser.parse_args()

    in_dir = Path(args.input_dir).resolve()
    if not in_dir.is_dir():
        raise SystemExit(f"Input directory not found: {in_dir}")

    files = collect_delay_files(in_dir)
    if not files:
        raise SystemExit(f"No 'delay*' files found in: {in_dir}")

    rows: List[Tuple[int, str, int, int]] = []  # (gpu, bank, num_agg, delay)
    for fp in files:
        try:
            gpu, bank, num_agg = parse_meta_from_name(fp.name)
            print(f"Parsed file {fp.name}: gpu={gpu}, bank={bank}, num_agg={num_agg}")
        except ValueError:
            # skip files that don't match expected pattern
            continue
        times = read_numeric_times(fp)
        # print(f"Read {len(times)} time entries from {fp.name}")
        if not times:
            # skip empty files
            continue
        delay_value = compute_stable_value(times)
        # print(f"Parsed file {fp.name}: gpu={gpu}, bank={bank}, num_agg={num_agg}, delay={delay_value}")
        rows.append((gpu, bank, num_agg, delay_value))

    # Sort by gpu then bank
    rows.sort(key=lambda r: (r[0], r[1]))

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with out_path.open('w', newline='', encoding='utf-8') as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(["gpu", "bank", "num_agg", "delay"])
        for gpu, bank, num_agg, delay in rows:
            writer.writerow([gpu, bank, num_agg, delay])

    print(f"Wrote {len(rows)} rows to {out_path}")


if __name__ == "__main__":
    main()
