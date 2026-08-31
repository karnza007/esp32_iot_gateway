#!/usr/bin/env python3
"""Split a CSV that accidentally contains more than one run, and check each run's
recorded settings against the filename.

    .venv/bin/python tools/split_runs.py data/m3-A-div16.csv            # inspect
    .venv/bin/python tools/split_runs.py data/m3-A-div16.csv --write    # split it

The viewer appends, so running twice to the same --csv concatenates the runs. A new
run is detected by `t` going backwards. Each part is written as <name>.partN.csv,
named by the BCLK_DIV the data itself reports.
"""
import argparse
import csv
import os
import sys


def split(path):
    with open(path, newline="") as f:
        rdr = csv.DictReader(f)
        fields, rows = rdr.fieldnames, list(rdr)
    parts, cur, prev = [], [], -1.0
    for r in rows:
        t = float(r["t"])
        if t < prev and cur:
            parts.append(cur)
            cur = []
        cur.append(r)
        prev = t
    if cur:
        parts.append(cur)
    return fields, parts


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="+")
    ap.add_argument("--write", action="store_true", help="actually write the split files")
    a = ap.parse_args()

    for path in a.csv:
        fields, parts = split(path)
        base = os.path.splitext(path)[0]
        print(f"{os.path.basename(path)}: {len(parts)} run(s)")
        for i, p in enumerate(parts, 1):
            divs = sorted({r.get("bclk_div", "?") for r in p})
            bauds = sorted({r.get("link2_baud", "?") for r in p})
            div = divs[0] if len(divs) == 1 else "MIXED " + ",".join(divs)
            out = f"{base}.part{i}-div{div}.csv"
            flag = ""
            if len(divs) == 1 and f"div{divs[0]}" not in os.path.basename(path):
                flag = "   <-- filename disagrees with the data"
            print(f"  run {i}: {len(p):>4} rows  bclk_div={div}  link2_baud={','.join(bauds)}"
                  f"  -> {os.path.basename(out)}{flag}")
            if a.write:
                with open(out, "w", newline="") as f:
                    w = csv.DictWriter(f, fieldnames=fields)
                    w.writeheader()
                    w.writerows(p)
        if not a.write:
            print("  (dry run — pass --write to split)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
