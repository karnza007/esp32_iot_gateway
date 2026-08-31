#!/usr/bin/env python3
"""Reduce a viewer CSV to the numbers that go in a report.

    .venv/bin/python tools/summarize_run.py data/run-*.csv
    .venv/bin/python tools/summarize_run.py --markdown data/*.csv     # table rows

Skips the first row of each run by default: the viewer joins a stream already in
progress, so row 1 always shows a startup resync that is an artefact of when you
pressed enter, not a property of the link. --keep-first disables that.
"""
import argparse
import csv
import os
import sys

FPGA_CLK = 24_000_000
LINK1_BPS = 200_000          # FPGA -> ESP32 @ 2 Mbaud (fixed for the whole project)
LINK2_DEFAULT_BAUD = 921_600  # only for CSVs written before link2_baud was recorded


def summarize(path: str, keep_first: bool = False,
              link2_baud: int | None = None) -> dict | None:
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        print(f"{path}: empty", file=sys.stderr)
        return None
    body = rows if keep_first else rows[1:]
    if not body:
        body = rows

    def isum(k):
        return sum(int(r[k]) for r in body)

    def fmean(k):
        vals = [float(r[k]) for r in body]
        return sum(vals) / len(vals) if vals else 0.0

    ok = isum("frames_ok")
    cks = isum("checksum_errors")
    lost = isum("frames_lost")
    seen = ok + cks
    expected = seen + lost
    duration = float(body[-1]["t"]) - float(body[0]["t"]) + 1.0

    # link 2's capacity is a property of THE RUN, not a constant: it is swept in
    # M3 phase C. Newer CSVs record it; older ones predate the column.
    if link2_baud is None:
        if "link2_baud" in body[0] and int(body[0]["link2_baud"]):
            link2_baud = int(body[0]["link2_baud"])
        else:
            link2_baud = LINK2_DEFAULT_BAUD
    link2_bps = link2_baud / 10
    bclk_div = int(body[0].get("bclk_div") or 0)

    verdicts = {}
    for r in body:
        verdicts[r["verdict"]] = verdicts.get(r["verdict"], 0) + 1
    worst = max(verdicts, key=lambda v: (v != "OK", verdicts[v]))

    return {
        "file": os.path.basename(path),
        "seconds": duration,
        "intervals": len(body),
        "frames_ok": ok,
        "frames_seen": seen,
        "frames_expected": expected,
        "frames_lost": lost,
        "drop_rate": lost / expected if expected else 0.0,
        "checksum_errors": cks,
        "checksum_rate": cks / seen if seen else 0.0,
        "ovf_bytes": isum("ovf_delta"),
        "ovf_rate_Bps": isum("ovf_delta") / duration if duration else 0.0,
        "resync_events": isum("resync_events"),
        "bytes_skipped": isum("bytes_skipped"),
        "frames_short": isum("frames_short") if "frames_short" in body[0] else 0,
        "bytes_missing": isum("bytes_missing") if "bytes_missing" in body[0] else 0,
        "received_Bps": (seen * 1036 - (isum("bytes_missing") if "bytes_missing" in body[0] else 0)) / duration if duration else 0.0,
        "payload_Bps": fmean("payload_Bps"),
        "wire_Bps": fmean("wire_Bps"),
        "verdict": worst,
        "verdicts": verdicts,
        "link2_baud": link2_baud,
        "link2_bps": link2_bps,
        "bclk_div": bclk_div,
        "assumed_baud": "link2_baud" not in body[0] or not int(body[0].get("link2_baud") or 0),
    }


def report(s: dict) -> str:
    div = f"BCLK_DIV={s['bclk_div']}" if s['bclk_div'] else "BCLK_DIV=?"
    note = "  (baud not recorded in CSV — assumed)" if s['assumed_baud'] else ""
    return f"""{s['file']}   [{div}, link 2 = {s['link2_baud']:,} baud = {s['link2_bps']:,.0f} B/s{note}]
  duration           {s['seconds']:.0f} s ({s['intervals']} one-second intervals)
  frames received    {s['frames_seen']}  (of {s['frames_expected']} expected)
  frames intact      {s['frames_ok']}
  frames lost        {s['frames_lost']}  -> drop rate {100*s['drop_rate']:.2f} %
  checksum errors    {s['checksum_errors']}  -> {100*s['checksum_rate']:.2f} % of received
  FPGA overflow      {s['ovf_bytes']:,} bytes  ({s['ovf_rate_Bps']:,.0f} B/s discarded)
  short frames       {s['frames_short']}  ({s['bytes_missing']:,} payload bytes missing)
  resync events      {s['resync_events']}  ({s['bytes_skipped']:,} bytes skipped)
  bytes on the wire  {s['received_Bps']:,.0f} B/s   (everything that arrived, intact or not)
  delivered payload  {s['payload_Bps']:,.0f} B/s   (usable audio only)
  delivered wire     {s['wire_Bps']:,.0f} B/s   \
= {100*s['wire_Bps']/LINK1_BPS:.0f} % of link 1, {100*s['wire_Bps']/s['link2_bps']:.0f} % of link 2
  verdict            {s['verdict']}   {s['verdicts']}"""


MD_HEADER = ("| run | s | frames ok | lost | drop % | cksum err | ovf bytes | "
             "resync | wire B/s | % link2 | verdict |\n"
             "|-----|---|-----------|------|--------|-----------|-----------|"
             "--------|----------|---------|---------|")


def md_row(s: dict) -> str:
    return (f"| `{s['file']}` | {s['seconds']:.0f} | {s['frames_ok']} | {s['frames_lost']} "
            f"| {100*s['drop_rate']:.2f} | {s['checksum_errors']} | {s['ovf_bytes']:,} "
            f"| {s['frames_short']} | {s['wire_Bps']:,.0f} "
            f"| {100*s['wire_Bps']/s['link2_bps']:.0f}{'*' if s['assumed_baud'] else ''} "
            f"| {s['verdict']} |")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="+")
    ap.add_argument("--markdown", action="store_true", help="emit a markdown table")
    ap.add_argument("--link2-baud", type=int, default=None,
                    help="override link 2 baud (for CSVs written before it was recorded)")
    ap.add_argument("--keep-first", action="store_true",
                    help="include the first interval (startup resync artefact)")
    a = ap.parse_args()

    summaries = [s for s in (summarize(p, a.keep_first, a.link2_baud) for p in a.csv) if s]
    if not summaries:
        return 1
    if a.markdown:
        print(MD_HEADER)
        for s in summaries:
            print(md_row(s))
        if any(x["assumed_baud"] for x in summaries):
            print("\n`*` link 2 baud not recorded in that CSV; "
                  f"assumed {LINK2_DEFAULT_BAUD:,}. Pass --link2-baud to correct.")
    else:
        for s in summaries:
            print(report(s))
            print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
