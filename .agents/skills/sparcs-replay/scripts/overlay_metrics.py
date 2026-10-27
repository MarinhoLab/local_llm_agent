#!/usr/bin/env python3
"""Hardware-vs-MuJoCo agreement metrics for one bag/log pair.

usage: overlay_metrics.py <bag.csv> <log.mat> <t0> <t1>

Prints peak/median (sim vs hw), correlation-optimal shift, and flange-z RMS
against the bag FK. Force column is index 21 (press-positive = -Fz).
"""
import sys
import numpy as np
import scipy.io
from scipy.signal import savgol_filter
from scipy.interpolate import interp1d

sys.path.insert(0, "/home/b40617mm/git/paper_2026_sparcs_compliance_control/force_control/identification")
from replay_profile import fkm


def sustained(x, thr, dt, s):
    w = int(s / dt)
    c = np.convolve((x > thr).astype(float), np.ones(w), "valid") >= w
    idx = np.flatnonzero(c)
    return int(idx[0]) if len(idx) else None


def main(bag, log, t0, t1):
    t0, t1 = float(t0), float(t1)
    hw = np.genfromtxt(bag, delimiter=",", skip_header=1, usecols=(0, 21))
    th, fh = hw[::10, 0], savgol_filter(-hw[::10, 1], 11, 2)
    m = scipy.io.loadmat(log)
    n = min(m[k].shape[0] for k in ("effective_sampling_time", "t", "f_y_eff"))
    dt = float(np.median(m["effective_sampling_time"][:n]))
    to = np.cumsum(m["effective_sampling_time"][:n].ravel())
    z = m["t"][:n].squeeze()[:n, 3]
    fz = -m["f_y_eff"][:n].squeeze()[:n, 3]
    ih = sustained(fh, 5.0, th[1] - th[0], 0.5)
    is_ = sustained(fz, 3.0, dt, 0.25)
    if ih is None or is_ is None:
        sys.exit("no sustained contact found — wrong log or window")
    t_al = to - (to[is_] - th[ih])
    wi = (t_al >= t0) & (t_al <= t1)
    hw_w = (th >= t0) & (th <= t1)
    hw_i = interp1d(th, fh, bounds_error=False)
    b0 = fz[wi] - np.median(fz[wi])
    best = (-9.0, 0.0)
    for sh in np.arange(-0.3, 0.31, 0.01):
        hi = hw_i(np.clip(t_al[wi] - sh, th[0], th[-1]))
        a = hi - np.nanmedian(hi)
        ok = ~np.isnan(a)
        cc = (a[ok] * b0[ok]).sum() / np.sqrt((a[ok] ** 2).sum() * (b0[ok] ** 2).sum())
        if cc > best[0]:
            best = (cc, sh)
    b = np.genfromtxt(bag, delimiter=",", skip_header=1)
    zb = np.array([fkm(q)[2, 3] * 1000 for q in b[::10, 1:7]])
    tb = b[::10, 0]
    z_bat = interp1d(tb, zb, bounds_error=False)(np.clip(t_al[wi], tb[0], tb[-1]))
    ok = ~np.isnan(z_bat)
    zr = np.sqrt(np.mean((z[wi][ok] * 1000 - z_bat[ok]) ** 2))
    print(f"peak sim/hw {fz[wi].max():.0f}/{fh[hw_w].max():.0f} N | "
          f"median {np.median(fz[wi]):.0f}/{np.median(fh[hw_w]):.0f} N | "
          f"corr {best[0]:.2f} (shift {best[1]:+.2f} s) | flange-z RMS {zr:.1f} mm")


if __name__ == "__main__":
    main(*sys.argv[1:5])
