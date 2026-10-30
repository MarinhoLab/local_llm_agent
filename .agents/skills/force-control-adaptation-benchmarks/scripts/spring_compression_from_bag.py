#!/usr/bin/env python3
"""Fetch an asoliman_2024 Paper_Results bag CSV and report spring compression
(z_sp_mm) vs measured force (Fz_measured) - the hardware-spring reference for
calibrating the MuJoCo fixture spring JS_3 (25 N ~ 7 mm in PolyManual_25).

CSVs are ~40 MB and raw.githubusercontent 404s on this repo; the download
URL comes from the contents API (short-lived token), so fetch via gh.
Cached under /tmp/opencode/asoliman_bags/.

Usage:
  python3 spring_compression_from_bag.py \
      Suspension_Identification/Paper_Results/17092026_Data/PolyManual_25 \
      [--bins 10,15,20,25] [--ref MarinhoLab/asoliman_2024]

CSV columns used (numpy usecols, 0-based): Fz_measured=26, F_poly=28,
z_sp_mm=29, z_contact_m=31. Header order is
time,real_time,q1..q6,dq1..dq6,q_target1..q6,Fx,Fy,Fz,Tx,Ty,Tz,
Fz_measured,F_NN,F_poly,z_sp_mm,dz_sp_mm_s,z_contact_m,computation_time_us,
z_target_m,z_target_uc_m,z_lb_m.
"""
import argparse
import os
import subprocess
import sys

import numpy as np

REF_DEFAULT = "MarinhoLab/asoliman_2024"
CACHE = "/tmp/opencode/asoliman_bags"


def fetch_csv(ref, run_dir, csv_name=None):
    os.makedirs(CACHE, exist_ok=True)
    listing = subprocess.run(
        ["gh", "api", f"repos/{ref}/contents/{run_dir}",
         "--jq", ".[] | select(.name|endswith(\".csv\")) | .name + \"\\t\" + .download_url"],
        capture_output=True, text=True, check=True).stdout.strip()
    if not listing:
        sys.exit(f"no CSVs under {ref}:{run_dir}")
    rows = [l.split("\t", 1) for l in listing.splitlines() if not l.startswith(".")]
    pick = [r for r in rows if csv_name is None or r[0] == csv_name]
    if len(pick) != 1:
        sys.exit("pick one of: " + ", ".join(r[0] for r in rows))
    name, url = pick[0]
    out = os.path.join(CACHE, name)
    if not os.path.exists(out) or os.path.getsize(out) < 10000:
        print("downloading", name, flush=True)
        subprocess.run(["curl", "-sL", "-o", out, url], check=True)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", help="path inside the repo, e.g. "
                    "Suspension_Identification/Paper_Results/17092026_Data/PolyManual_25")
    ap.add_argument("--ref", default=REF_DEFAULT)
    ap.add_argument("--csv", default=None)
    ap.add_argument("--bins", default="10,15,20,25")
    args = ap.parse_args()
    path = fetch_csv(args.ref, args.run_dir, args.csv)
    cols = np.genfromtxt(path, delimiter=",", skip_header=1,
                         usecols=(26, 28, 29, 31))
    f, fpoly, z_sp, z_con = cols.T
    m = np.isfinite(f) & np.isfinite(z_sp) & (f > 0)
    print("%s: %d samples, peak Fz %.1f N, max compression %.1f mm"
          % (os.path.basename(path), m.sum(), f[m].max(), abs(z_sp[m]).max()))
    for tgt in (float(b) for b in args.bins.split(",")):
        sel = m & (np.abs(f - tgt) < 0.5)
        if sel.sum() > 30:
            print("Fz=%4.1f N: z_sp %.2f mm (n=%d, p10-p90 %.2f-%.2f)"
                  % (tgt, np.median(z_sp[sel]), sel.sum(),
                     np.percentile(z_sp[sel], 10), np.percentile(z_sp[sel], 90)))
        else:
            print("Fz=%4.1f N: only %d samples" % (tgt, sel.sum()))


if __name__ == "__main__":
    main()
