#!/usr/bin/env python3
"""κ̂ / force comparison figure for the probed-plane adaptation matrix.

Scans a datalogger ``logs/`` dir for clean square/clamp runs (single contact
burst, ≥15k steps), fingerprints each by its ``poly_a_hat`` first sample
(the seeded κ̂) and whether κ̂ moved (adaptation) or stayed put (frozen), and
plots a 2×3 grid of κ̂₁ and f_n traces per seed.

    python3 probe_matrix.py <logs_dir> <out.png> [seeds...]   # default 1928 4650 7712

Run with the stack env of the matrix: FORCE_AVG_N=20 FORCE_NORM_LIMIT=25.0
POLY_K1_BOUNDS='[500.0,30000.0]' PROBE=yes, one recorded square per
(seed, ADAPTATION) cell; protocol per cell: recreate implementation (re-seeds
κ̂ + re-probes, ~100 s), restart sas_datalogger, run
``mujoco_excitation.py square 5 0.0215 5,7,9 0.2,0.3,0.5 20 0.020``, restart
sas_datalogger again.
"""
import sys
import glob
import os

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy.io import loadmat


def cols(mat):
    def col(k, i=0):
        a = np.asarray(mat[k])
        return a.reshape(a.shape[0], -1)[:, i]
    return col


def fingerprint(f):
    m = loadmat(f)
    col = cols(m)
    k, fn, dn, plane = col("poly_a_hat"), col("f_n"), col("d_n"), col("probe_plane_z")
    if len(k) < 15000:
        return None
    return dict(k=k, fn=fn, dn=dn, seed=k[0], adapt=abs(k[-1] - k[0]) > 300,
                plane=np.median(plane), peak=fn.max(), depth=dn.max())


def main():
    logs, out = sys.argv[1], sys.argv[2]
    seeds = [float(s) for s in sys.argv[3:]] or [1928.0, 4650.0, 7712.0]
    want = {(s, a): None for s in seeds for a in (True, False)}
    for f in sorted(glob.glob(os.path.join(logs, "sas_log_*.mat")))[-4 * len(want):]:
        r = fingerprint(f)
        if r is None:
            continue
        for s in seeds:
            if abs(r["seed"] - s) > 1:
                continue
            if want.get((s, r["adapt"])) is None:
                want[(s, r["adapt"])] = f
    missing = [k for k, v in want.items() if v is None]
    if missing:
        sys.exit(f"missing runs: {missing}")

    fig, axes = plt.subplots(2, len(seeds), figsize=(13, 7), sharex=True)
    for j, s in enumerate(seeds):
        for adapt, lab, c in [(True, "adaptation", "C0"), (False, "frozen", "C1")]:
            r = fingerprint(want[(s, adapt)])
            axes[0, j].plot(np.arange(len(r["k"])) / 200.0, r["k"], label=lab, color=c)
            axes[1, j].plot(np.arange(len(r["fn"])) / 200.0, r["fn"], label=lab, color=c)
        axes[0, j].axhline(3856, color="k", ls=":", lw=1)
        axes[0, j].set_title(f"seed κ̂(0) = {s:.0f}   plane {r['plane']:.4f} m")
        axes[1, j].axhline(25, color="r", ls="--", lw=1)
        axes[0, j].set_ylabel("κ̂₁ [N/m]")
        axes[1, j].set_ylabel("f_n [N]")
        axes[1, j].set_xlabel("t [s]")
        print(f"{s:.0f} adapt={adapt}: end {r['k'][-1]:.0f} peak {r['peak']:.1f} N depth {r['depth']*1000:.2f} mm ({want[(s, adapt)]})")
    axes[0, 0].legend(loc="lower right")
    axes[1, 0].legend(loc="upper left")
    fig.suptitle("Probed contact plane — adaptation vs frozen κ̂ (square 5/7/9 mm @ 20 mm/s, clamp 25 N)")
    fig.tight_layout()
    fig.savefig(out, dpi=130)
    print("saved", out)


if __name__ == "__main__":
    main()
