#!/usr/bin/env python3
"""
Parse one multi-bank-hammer log file and extract bit-flip information.

What it does
- Parses one log file
- Extracts for each flip: file, bank, row, byte, bit, direction, address
- Prints totals and unique flip count (dedup by bank,row,byte,bit,direction)
- Optionally writes CSV

Usage examples
  python parse_flips_single.py /path/to/xxx_log.txt
  python parse_flips_single.py /path/to/xxx_log.txt --csv flips.csv
"""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path
from typing import Dict, List, Optional, Tuple

BITFLIP_DETECTED = re.compile(r"^Bit-flip detected!\s*$")
OBSERVED_LINE = re.compile(
    r"^Observed\s+(?P<count>\d+)\s+bit-flip\(s\)\s+in\s+Row\s+(?P<row>\d+),\s+Byte\s+(?P<byte>\d+),\s+Address\s+(?P<addr>0x[0-9a-fA-F]+)\s*$"
)
BITFLIP_DETAIL = re.compile(
    r"^The\s+(?P<bit>\d+)(?:st|nd|rd|th)\s+bit\s+flipped\s+from\s+(?P<frm>[01])\s+to\s+(?P<to>[01])\s+\(Data Pattern: .*\)\s*$"
)
BANK_RESULT = re.compile(
    r"^\(multi-bank-hammer\):\s+Bank\s+(?P<bank>\d+)\s+-\s+Bit-flip in victim rows:\s+(?P<status>.+?)\s*$"
)
NUM_BANKS_LINE = re.compile(r"^num_banks:\s*(?P<num>\d+)\s*$", re.IGNORECASE)
TOTAL_ATTACKS_LINE = re.compile(
    r"^\(multi-bank-hammer\):\s+Total attacks attempted:\s*(?P<num>\d+)\s*$",
    re.IGNORECASE,
)


def _new_flip(path: Path) -> Dict:
    return {
        "file": str(path),
        "bank": None,
        "row": None,
        "byte": None,
        "bit": None,
        "direction": None,
        "address": None,
    }


def _first_pending(pending: List[Dict], key: str) -> Optional[Dict]:
    for item in pending:
        if item.get(key) is None:
            return item
    return None


def parse_file(path: Path) -> List[Dict]:
    flips: List[Dict] = []
    pending: List[Dict] = []

    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception as exc:
        print(f"[warn] Failed to read {path}: {exc}")
        return flips

    for line in lines:
        if BITFLIP_DETECTED.match(line):
            pending.append(_new_flip(path))
            continue

        m_obs = OBSERVED_LINE.match(line)
        if m_obs:
            target = _first_pending(pending, "row")
            if target is None:
                target = _new_flip(path)
                pending.append(target)
            target["row"] = int(m_obs.group("row"))
            target["byte"] = int(m_obs.group("byte"))
            target["address"] = m_obs.group("addr")
            continue

        m_det = BITFLIP_DETAIL.match(line)
        if m_det:
            target = _first_pending(pending, "bit")
            if target is None:
                target = _new_flip(path)
                pending.append(target)
            target["bit"] = int(m_det.group("bit"))
            target["direction"] = f"{m_det.group('frm')}->{m_det.group('to')}"
            continue

        m_bank = BANK_RESULT.match(line)
        if m_bank:
            status = m_bank.group("status").strip().lower()
            if "observed" in status:
                bank = int(m_bank.group("bank"))
                for item in pending:
                    if item.get("bank") is None:
                        item["bank"] = bank
                        flips.append(item)
                pending.clear()

    if pending:
        flips.extend(pending)

    return flips


def parse_run_meta(path: Path) -> Tuple[Optional[int], Optional[int]]:
    num_banks: Optional[int] = None
    no_attacks: Optional[int] = None

    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except Exception:
        return num_banks, no_attacks

    for line in lines:
        m_banks = NUM_BANKS_LINE.match(line)
        if m_banks:
            num_banks = int(m_banks.group("num"))
            continue

        m_attacks = TOTAL_ATTACKS_LINE.match(line)
        if m_attacks:
            no_attacks = int(m_attacks.group("num"))

    return num_banks, no_attacks


def is_complete(flip: Dict) -> bool:
    return all(
        flip.get(k) is not None
        for k in ("row", "byte", "bit", "direction")
    )


def unique_key(flip: Dict) -> Tuple:
    return (
        flip.get("bank"),
        flip.get("row"),
        flip.get("byte"),
        flip.get("bit"),
        flip.get("direction"),
    )


def summarize(flips: List[Dict]):
    total = len(flips)
    complete = [f for f in flips if is_complete(f)]
    partial = total - len(complete)
    unique_count = len({unique_key(f) for f in complete})

    per_bank: Dict[Optional[int], int] = {}
    for f in complete:
        bank = f.get("bank")
        per_bank[bank] = per_bank.get(bank, 0) + 1

    return total, len(complete), partial, unique_count, per_bank


def write_csv(flips: List[Dict], out_path: Path, include_partial: bool = False):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fields = ["file", "bank", "row", "byte", "bit", "direction", "address"]
    rows = flips if include_partial else [f for f in flips if is_complete(f)]

    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in fields})


def main():
    ap = argparse.ArgumentParser(description="Parse one multi-bank-hammer log file for bit-flips")
    ap.add_argument("file", type=str, help="Path to one log file")
    ap.add_argument("--csv", type=str, default=None, help="Optional path to write CSV")
    ap.add_argument("--hours", type=float, default=6.0, help="Duration in hours for flips/hour (default: 6)")
    ap.add_argument(
        "--include-partial-csv",
        action="store_true",
        help="Include partial entries in CSV",
    )
    args = ap.parse_args()

    log_path = Path(args.file).resolve()
    if not log_path.is_file():
        ap.error(f"File not found: {log_path}")

    flips = parse_file(log_path)
    total, complete_cnt, partial_cnt, unique_cnt, per_bank = summarize(flips)
    no_banks, no_attacks = parse_run_meta(log_path)

    print("==== Bit-Flip Summary ====")
    print(f"Searched: file: {log_path}")
    print(f"Total flips found (all entries): {total}")
    print(f"Complete flips (with row/byte/bit/direction): {complete_cnt}")
    print(f"Partial entries (skipped in CSV by default): {partial_cnt}")
    print(f"Unique flips (by bank,row,byte,bit,direction among complete): {unique_cnt}")
    print("Per-bank counts (complete flips):")
    for bank in sorted(per_bank.keys(), key=lambda b: (-1 if b is None else b)):
        print(f"  Bank {bank}: {per_bank[bank]}")

    print("==== Derived Metrics ====")
    if args.hours <= 0:
        print("flips/hour: N/A (hours must be > 0)")
    else:
        print(f"flips/hour (using complete flips): {unique_cnt / args.hours:.6f}")

    if no_banks is None or no_attacks is None:
        print("flips/GB: N/A (missing num_banks or Total attacks attempted in log)")
    else:
        no_attacks_gb = no_banks * no_attacks * (2 << 10) / (1024 ** 3)
        if no_attacks_gb == 0:
            print("flips/GB: N/A (no_attacks_gb is 0)")
        else:
            ours = unique_cnt / no_attacks_gb
            print(f"no_banks: {no_banks}")
            print(f"no_attacks: {no_attacks}")
            print(f"no_attacks_gb: {no_attacks_gb:.12f}")
            print(f"flips/GB (ours): {ours:.6f}")

    if args.csv:
        out_path = Path(args.csv)
        write_csv(flips, out_path, include_partial=args.include_partial_csv)
        print(f"Wrote CSV: {out_path.resolve()}")


if __name__ == "__main__":
    main()
