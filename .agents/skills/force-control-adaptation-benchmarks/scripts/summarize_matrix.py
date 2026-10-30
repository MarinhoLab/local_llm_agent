#!/usr/bin/env python3
"""Aggregate force-control benchmark summary.csv files into one table.

Groups rows by (variant, mode) and prints mean hold/peak/residual and final
kappa_1/kappa_2. The 'tau' column holds the variant label (tau=..., js2500,
...) from adaptation_mismatch_matrix.py.

Usage:
  python3 summarize_matrix.py /tmp/opencode/mismatch/results*/summary.csv \
      /tmp/opencode/adaptation_matrix/summary.csv
"""
import argparse
import collections
import csv
import statistics as st
import sys

COLUMNS = (("hold", "hold_mean_N"), ("peak", "peak_N"), ("resid", "resid_N"),
           ("k1", "k1_final"), ("k2", "k2_final"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csvs", nargs="+")
    args = ap.parse_args()
    agg = collections.defaultdict(lambda: collections.defaultdict(list))
    seen = 0
    for path in args.csvs:
        with open(path) as fh:
            for r in csv.DictReader(fh):
                seen += 1
                key = (r["tau"], r["mode"])
                for name, col in COLUMNS:
                    if r.get(col) not in (None, "", "nan"):
                        agg[key][name].append(float(r[col]))
    if not seen:
        sys.exit("no rows found")
    header = "%-10s %-9s" % ("variant", "mode")
    header += "".join("%9s" % n for n, _ in COLUMNS)
    print(header)
    for key in sorted(agg):
        row = "%-10s %-9s" % key
        for name, _ in COLUMNS:
            vals = agg[key][name]
            row += "%9s" % ("%.2f" % st.mean(vals) if vals else "-")
        print(row)


if __name__ == "__main__":
    main()
