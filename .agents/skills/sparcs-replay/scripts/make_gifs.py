#!/usr/bin/env python3
"""Progressive hardware-vs-MuJoCo overlay gif for one bag/log pair.

usage: make_gifs.py <bag.csv> <log.mat> <t0> <t1> <speed> <out.gif>

Two panels (press force, flange z), both traces drawn progressively at 10 fps;
square bags look good at speed=4 (2.5x), 1 Hz sines at speed=1. Needs ffmpeg.
Uses the same engage-anchor + fine-shift alignment as overlay_metrics.py.
"""
import os
import shutil
import subprocess
import sys

import numpy as np
import scipy.io
from scipy.signal import savgol_filter
from scipy.interpolate import interp1d
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, "/home/b40617mm/git/paper_2026_sparcs_compliance_control/force_control/identification")
from replay_profile import fkm
from overlay_metrics import sustained

FPS = 10


def main(bag, log, t0, t1, speed, out):
    t0, t1, speed = float(t0), float(t1), int(speed)
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
    ta = np.arange(t0, t1, 0.05)
    hw_f = np.interp(ta, th, fh)
    sim_t = t_al[wi] - best[1]
    sim_f = np.interp(ta, sim_t, fz[wi], left=np.nan, right=np.nan)
    sim_z = np.interp(ta, sim_t, z[wi] * 1000, left=np.nan, right=np.nan)
    bag_z = np.interp(ta, tb, zb, left=np.nan, right=np.nan)
    zr = np.sqrt(np.nanmean((sim_z - bag_z) ** 2))

    fig, axes = plt.subplots(2, 1, figsize=(7.2, 4.5), sharex=True, constrained_layout=True)
    (lh,) = axes[0].plot([], [], lw=1.3, color="#1f77b4", label="hardware")
    (ls,) = axes[0].plot([], [], lw=1.3, color="#d62728", label="MuJoCo")
    axes[0].set_ylim(-2, fh[hw_w].max() * 1.15)
    axes[0].set_ylabel("press force (N)")
    axes[0].legend(loc="upper right", fontsize=8)
    (zh,) = axes[1].plot([], [], lw=1.3, color="#1f77b4")
    (zs,) = axes[1].plot([], [], lw=1.3, color="#d62728")
    axes[1].set_ylabel("flange z (mm)")
    axes[1].set_xlabel("t (s)")
    axes[1].set_ylim(np.nanmax(bag_z) * 1.08, np.nanmin(bag_z) * 0.92)
    axes[0].set_xlim(t0, t1)  # REQUIRED: empty initial draw otherwise pins xlim to (0,1)
    cur = axes[0].axvline(t0, color="k", lw=.6, alpha=.5)
    cur2 = axes[1].axvline(t0, color="k", lw=.6, alpha=.5)
    name = os.path.basename(bag).removesuffix(".csv")
    fig.suptitle(f"{name}: peak hw/sim {np.nanmax(hw_f):.0f}/{np.nanmax(sim_f):.0f} N  |  "
                 f"corr {best[0]:.2f}  |  flange RMS {zr:.1f} mm")
    for a in axes:
        a.grid(alpha=.3)

    def upd(k):
        j = min((k + 1) * speed, len(ta))
        lh.set_data(ta[:j], hw_f[:j])
        ls.set_data(ta[:j], sim_f[:j])
        zh.set_data(ta[:j], bag_z[:j])
        zs.set_data(ta[:j], sim_z[:j])
        cur.set_xdata([ta[j - 1]] * 2)
        cur2.set_xdata([ta[j - 1]] * 2)

    d = out + ".frames"
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    fig.canvas.draw()
    nfr = int(len(ta) / speed)
    for k in range(nfr):
        upd(k)
        fig.savefig(f"{d}/f{k:04d}.png")
    plt.close(fig)
    vf = ("fps=10,scale=720:-1:flags=lanczos,split[s0][s1];"
          "[s0]palettegen=max_colors=64[p];[s1][p]paletteuse")
    subprocess.run(f"ffmpeg -y -loglevel error -i {d}/f%04d.png -vf '{vf}' {out}",
                   shell=True, check=True)
    shutil.rmtree(d, ignore_errors=True)
    print(f"{out}: {nfr} frames, {os.path.getsize(out)/1e6:.1f} MB")


if __name__ == "__main__":
    main(*sys.argv[1:7])
