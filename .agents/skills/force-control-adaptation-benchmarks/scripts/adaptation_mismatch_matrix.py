"""
Copyright (c) 2026 Murilo M. Marinho. All rights reserved.

This file is part of a private, confidential repository and is not
distributed under any open-source license. Do not redistribute or publish
without permission from all authors.

Material-mismatch benchmark (Preston): the controller keeps the polynomial
identified on the reference surface while the MuJoCo contact is softened
(solref timeconst on the tool geom: JS_3 4650 N/m in series with a softer
surface raises the surface's share of the compliance and changes the
curvature). Compares adapting kappa_1 only (higher orders frozen at the
identified values) against adapting all orders (per-order gain decay,
POLY_HIGHER_ORDER_GAIN) under the force clamp.

Configs: tau in {0.005 (identified), 0.010, 0.020} s x mode in {frozen,
alladapt} x 5 noise realizations (sigma = 0.25 N), initial guess always the
identified coefficients. Usage (host, mujoco headful optional):
    python3 analysis/replay_tools/adaptation_mismatch_matrix.py
"""
import os
import subprocess
import sys
import time
from pathlib import Path

import importlib.util

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location(
    "anm", HERE / "adaptation_noise_matrix.py")
anm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(anm)
import numpy as _np


def _pnf(k_z, d):
    d = _np.asarray(d, dtype=float)
    i = _np.arange(1, len(k_z) + 1, dtype=float)
    return (d[..., None] ** i) @ _np.asarray(k_z, dtype=float)


anm.polynomial_normal_force = _pnf

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SIGMA = 0.25
N_RUNS = 5
def _default_taus():
    return [("0.005", "../mujoco/ur3e_robot.xml"),   # identified reference surface
            ("0.010", "/tmp/opencode/mismatch/ur3e_robot_tau_0.010.xml"),
            ("0.020", "/tmp/opencode/mismatch/ur3e_robot_tau_0.020.xml")]


_sel = os.environ.get("TAUS_LIST", "")
_var = os.environ.get("VARIANTS_LIST", "")
if _var:
    TAUS = [tuple(p.split(":", 1)) for p in _var.split(",")]
elif _sel:
    TAUS = [(t, f"/tmp/opencode/mismatch/ur3e_robot_tau_{t}.xml") for t in _sel.split(",")]
else:
    TAUS = _default_taus()
MODES = {"frozen": "1", "alladapt": ""}
BETA = "0.5"


def run_one(plane, robot_xml, tau, order, seed_i, out_dir, extras=None):
    env = dict(os.environ)
    env.update({
        "ROS_DOMAIN_ID": "91", "PROJECT": anm.PROJECT, "SENSOR": "bota",
        "ROBOT_TOPIC_NAME": "/ur3e_1", "JOINTS_TOPIC": "/ur3e_1/get/joint_states",
        "DISPLAY": "", "REC_NAME": "",
        "CONTACT_PLANE_Z": str(plane),
        "POLY_INITIAL_GUESS": "[" + ",".join(f"{c:.6e}" for c in anm.identified_coeffs(anm.POLY_FILE)) + "]",
        "POLY_K1_BOUNDS": "[500.0,30000.0]",
        "FORCE_MODEL": "polynomial", "PROBE": "no", "ADAPTATION": "yes",
        "POLY_ADAPT_ORDER": order,
        "POLY_HIGHER_ORDER_GAIN": BETA,
        "FORCE_NOISE_SIGMA": str(SIGMA),
        "RANDOM_SEED": str(4000 + seed_i),
        "DESCENT_DEPTH": "0.020", "DESCENT_SPEED": "0.005", "DESCENT_SPEED_FAST": "0.02",
        "FORCE_NORM_LIMIT": "25.0", "RUN_SECONDS": "90",
        "ROBOT_XML": robot_xml,
    })
    if extras:
        env.update(extras)
    compose = ["docker", "compose", "-p", anm.PROJECT, "-f", anm.COMPOSE]
    # (re)create mujoco with this config's ROBOT_XML, then reset the world
    anm.sh("docker", "compose", "-p", anm.PROJECT, "-f", "compose_force_limit_mujoco.yml",
           "up", "-d", "mujoco", env=env, cwd=str(anm.DOCKER_DIR))
    anm.sh("docker", "restart", f"{anm.PROJECT}-mujoco-1", env=env, check=False)
    time.sleep(8)
    anm.ensure_mujoco()
    anm.sh("docker", "restart", f"{anm.PROJECT}-sas_datalogger-1", env=env)
    time.sleep(2)
    anm.sh("docker", "rm", "-f", f"{anm.PROJECT}-implementation-1", env=env, check=False)
    anm.sh(*compose, "up", "-d", "robot_mirror", "implementation", env=env,
           cwd=str(anm.DOCKER_DIR))
    code = anm.wait_exit(f"{anm.PROJECT}-implementation-1", 420)
    if code != "0":
        log = anm.sh("docker", "logs", "--tail", "40",
                     f"{anm.PROJECT}-implementation-1", check=False)
        raise RuntimeError(f"tau {robot_xml} mode {order} run {seed_i}: exit {code}\n{log}")
    time.sleep(2)
    anm.sh("docker", "restart", f"{anm.PROJECT}-sas_datalogger-1", env=env)
    dest = out_dir / f"tau{tau}_{order or 'all'}_run{seed_i}.mat"
    return anm.collect_mat(set(), dest)


def metrics(path):
    import scipy.io
    d = scipy.io.loadmat(path)
    a = anm.np.squeeze(anm.np.asarray(d["poly_a_hat"], dtype=float))
    k1 = a if a.ndim == 1 else a[:, 0]
    a_last = a[-1] if a.ndim == 2 else anm.np.array([a[-1]])
    cp = anm.np.squeeze(anm.np.asarray(d["contact_point"], dtype=float))
    cp = cp.reshape(cp.shape[0], -1)[:, 1:4]
    touched = anm.np.where(anm.np.linalg.norm(cp, axis=1) > 1e-9)[0]
    f_n = anm.np.squeeze(anm.np.asarray(d["f_n"], dtype=float)).ravel()
    if len(touched) == 0:
        return None
    i0 = int(touched[0])
    tail = f_n[i0:][-4000:]   # last 20 s
    dn = anm.np.squeeze(anm.np.asarray(d["d_n"], dtype=float)).ravel()
    resid = anm.np.nanmedian(anm.np.abs(
        anm.polynomial_normal_force(a_last, anm.np.clip(dn[i0:][-4000:], 0.0, None))
        - f_n[i0:][-4000:]))
    return dict(peak=float(anm.np.nanmax(f_n[i0:])), t=anm.np.arange(len(f_n) - i0) * 0.005,
                f=anm.np.clip(f_n[i0:], 0, None), mean=float(anm.np.nanmean(tail)),
                std=float(anm.np.nanstd(tail)), k1f=float(k1[-1]),
                resid=float(resid),
                k2f=float(a_last[1]) if len(a_last) > 1 else 0.0)


def plot(tau, rows, out_dir):
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.6), sharey=True)
    for ax, (mode, _) in zip(axes, MODES.items()):
        rs = [r for r in rows if r["mode"] == mode]
        for r in rs:
            ax.plot(r["m"]["t"], r["m"]["f"], lw=1.0,
                    label=f"run {r['i']}: pk {r['m']['peak']:.1f}, hold {r['m']['mean']:.1f}±{r['m']['std']:.1f}")
        ax.axhline(25.0, color="k", ls="--", lw=1.2, label="clamp 25 N")
        ax.set_title(f"{mode} — contact solref {tau} s")
        ax.set_xlabel("t since first contact (s)")
        ax.grid(alpha=0.3)
        ax.legend(fontsize=6)
    axes[0].set_ylabel("measured press f_n (N)")
    fig.tight_layout()
    fig.savefig(out_dir / f"mismatch_tau_{tau}.png", dpi=150)
    plt.close(fig)


def main():
    out_dir = Path(os.environ.get("OUT_DIR", "/tmp/opencode/mismatch/results"))
    (out_dir / "mats").mkdir(parents=True, exist_ok=True)
    plane = anm.plane_from_yaml(anm.PLANE_YAML)
    env = dict(os.environ, ROS_DOMAIN_ID="91", PROJECT=anm.PROJECT,
               JOINTS_TOPIC="/ur3e_1/get/joint_states", OBJECT_PREFIX="/sas_robot_driver_coppeliasim/object",
               REC_NAME="", DISPLAY="")
    rows = []
    n = 0
    total = len(TAUS) * len(MODES) * N_RUNS
    for tau, xml in TAUS:
        for mode, order in MODES.items():
            for i in range(N_RUNS):
                n += 1
                t0 = time.time()
                extras = None
                if os.environ.get("RICH_RUN"):
                    extras = {"MULTI_PRESS": os.environ.get("MULTI_PRESS", "5"),
                              "PRESS_CYCLE_HOLD": os.environ.get("PRESS_CYCLE_HOLD", "4"),
                              "RUN_SECONDS": os.environ.get("FINAL_HOLD", "30")}
                for attempt in range(3):
                    try:
                        mat = run_one(plane, xml, tau, order, i, out_dir / "mats", extras)
                        m = metrics(mat)
                        break
                    except Exception as e:
                        if attempt == 2:
                            raise
                        print(f"  retry ({e})", flush=True)
                        time.sleep(10)
                rows.append(dict(tau=tau, mode=mode, i=i, m=m))
                print(f"[{n}/{total}] tau={tau} {mode} run{i}: peak {m['peak']:.1f} "
                      f"hold {m['mean']:.1f}±{m['std']:.1f} resid {m['resid']:.2f} k1f {m['k1f']:.0f} "
                      f"k2f {m['k2f']:.0f} ({time.time()-t0:.0f}s)", flush=True)
        plot(tau, [r for r in rows if r["tau"] == tau], out_dir)
        print(f"plotted {out_dir / f'mismatch_tau_{tau}.png'}", flush=True)
    with open(out_dir / "summary.csv", "w") as f:
        f.write("tau,mode,run,peak_N,hold_mean_N,hold_std_N,resid_N,k1_final,k2_final\n")
        for r in rows:
            f.write(f"{r['tau']},{r['mode']},{r['i']},{r['m']['peak']:.2f},"
                    f"{r['m']['mean']:.2f},{r['m']['std']:.2f},{r['m']['resid']:.3f},{r['m']['k1f']:.1f},"
                    f"{r['m']['k2f']:.1f}\n")
    print("done: 3 figures + mats + summary.csv in", out_dir, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
