"""
Copyright (c) 2026 Murilo M. Marinho. All rights reserved.

This file is part of a private, confidential repository and is not
distributed under any open-source license. Do not redistribute or publish
without permission from all authors.

Adaptation-robustness matrix: 20 polynomial seeds x 4 zero-mean Gaussian
force-sensor noise levels, pressed along the simulated contact plane with the
polynomial identification (ForcePolynomial_MuJoCo.txt) as the baseline.

Each run is one phase-3 style evaluation on the MuJoCo stack (plane from
identified_plane_simulation.yaml, no probing, ADAPTATION=yes), driven through
docker compose exactly as experiments/phase_3.sh does: the world is reset,
the datalogger flushed, and the run auto-exits on RUN_SECONDS. One figure
per noise level, each with the 20 kappa_1 traces (from first contact) and
the identified baseline as a dashed line.

Usage (host):
    python3 analysis/replay_tools/adaptation_noise_matrix.py \
        [--out /tmp/opencode/adaptation_matrix] [--run-seconds 90]
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import scipy.io

REPO = Path(__file__).resolve().parents[2]
DOCKER_DIR = REPO / "docker"
COMPOSE = "compose_robot_mirror.yml"  # relative to DOCKER_DIR
PROJECT = "sparcs_rep"
PLANE_YAML = REPO / "experiments" / "identified_plane_simulation.yaml"
POLY_FILE = REPO / "identification" / "ForcePolynomial_MuJoCo.txt"

SIGMAS = [0.05, 0.25, 0.5, 1.0]  # N, per force component
N_SEEDS = 20
SEEDS = np.logspace(np.log10(600.0), np.log10(25000.0), N_SEEDS)
SAMPLING_TIME = 0.005


def sh(*args, env=None, check=True, cwd=None):
    return subprocess.run(args, check=check, env=env, cwd=cwd,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout


def plane_from_yaml(path: Path) -> float:
    for line in path.read_text().splitlines():
        if "plane_z_m:" in line:
            return float(line.split(":", 1)[1])
    raise RuntimeError(f"no plane_z_m in {path}")


def identified_coeffs(path: Path) -> list:
    """k1..kn in N/m^i from the identification file (k0 dropped, z mm -> m)."""
    vals = [float(t) for t in open(path) if not t.startswith("#") for t in t.split()]
    k0_dropped, k_idents = vals[1], vals[2:]
    assert len(k_idents) == vals[0] - 1, "coefficient count mismatch"
    return [k * 1000.0 ** (i + 1) for i, k in enumerate(k_idents)]


def container_state(name: str) -> str:
    try:
        return sh("docker", "inspect", "-f", "{{.State.Status}}", name).strip()
    except subprocess.CalledProcessError:
        return "missing"


def wait_exit(name: str, timeout: float) -> str:
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = container_state(name)
        if state != "running":
            return sh("docker", "inspect", "-f", "{{.State.ExitCode}}", name).strip()
        if container_state(f"{PROJECT}-mujoco-1") != "running":
            # the world died mid-run (e.g. someone closed its window); fail fast
            sh("docker", "rm", "-f", name, check=False)
            raise RuntimeError("mujoco exited during the run")
        time.sleep(5)
    raise TimeoutError(f"{name} still running after {timeout}s")


def ensure_mujoco() -> None:
    # headful window: recreate with the CALLER's DISPLAY/HEADLESS, never with
    # the per-run env (its DISPLAY is blanked for the mirror)
    env = dict(os.environ, ROS_DOMAIN_ID="91")
    for _ in range(6):
        if container_state(f"{PROJECT}-mujoco-1") == "running":
            return
        sh("docker", "compose", "-p", PROJECT, "-f", "compose_force_limit_mujoco.yml",
           "up", "-d", "mujoco", env=env, cwd=str(DOCKER_DIR))
        time.sleep(8)
    raise RuntimeError("mujoco refuses to start")


def collect_mat(before: set, dest: Path) -> Path:
    """Copy the freshest root-owned datalogger mat out (docker cp) and remove it."""
    logs = DOCKER_DIR / "logs"
    fresh = sorted(set(p.name for p in logs.glob("sas_log_*.mat")) - before,
                   key=lambda n: (logs / n).stat().st_mtime)
    if not fresh:
        raise RuntimeError("no fresh datalogger mat appeared")
    name = fresh[-1]
    sh("docker", "cp", f"{PROJECT}-sas_datalogger-1:/root/logs/{name}", str(dest))
    sh("docker", "exec", f"{PROJECT}-sas_datalogger-1", "rm", "-f", f"/root/logs/{name}",
       check=False)
    return dest


def run_one(plane: float, seed: float, sigma: float, seed_index: int,
            run_seconds: float, out_dir: Path, higher_order: list) -> Path:
    """One adaptive press; returns the copied mat path."""
    env = dict(os.environ)
    env.update({
        "ROS_DOMAIN_ID": "91", "PROJECT": PROJECT, "SENSOR": "bota", "DISPLAY": "",
        "ROBOT_TOPIC_NAME": "/ur3e_1", "JOINTS_TOPIC": "/ur3e_1/get/joint_states",
        "CONTACT_PLANE_Z": str(plane),
        "POLY_INITIAL_GUESS": "[" + ",".join(
            [f"{float(seed):.6f}"] + [f"{c:.6e}" for c in higher_order]) + "]",
        "POLY_K1_BOUNDS": "[500.0,30000.0]",
        "FORCE_MODEL": "polynomial", "PROBE": "no", "ADAPTATION": "yes",
        "POLY_ADAPT_ORDER": "",
        "POLY_HIGHER_ORDER_GAIN": os.environ.get("POLY_HIGHER_ORDER_GAIN", "0.2"),
        "FORCE_NOISE_SIGMA": str(sigma),
        "RANDOM_SEED": str(1000 * seed_index + int(sigma * 1000)),
        "DESCENT_DEPTH": "0.020", "DESCENT_SPEED": "0.005", "DESCENT_SPEED_FAST": "0.02",
        "FORCE_NORM_LIMIT": "25.0", "RUN_SECONDS": str(run_seconds),
        "REC_NAME": "",
    })
    # fresh world + datalogger session (the restart also reopens the headful
    # window; if it was closed between runs, ensure_mujoco starts it again)
    sh("docker", "restart", f"{PROJECT}-mujoco-1", env=env, check=False)
    time.sleep(8)
    ensure_mujoco()
    sh("docker", "restart", f"{PROJECT}-sas_datalogger-1", env=env)
    time.sleep(2)
    sh("docker", "rm", "-f", f"{PROJECT}-implementation-1", env=env, check=False)
    before = set(p.name for p in (DOCKER_DIR / "logs").glob("sas_log_*.mat"))

    compose = ["docker", "compose", "-p", PROJECT, "-f", COMPOSE]
    sh(*compose, "up", "-d", "robot_mirror", "implementation", env=env, cwd=str(DOCKER_DIR))
    code = wait_exit(f"{PROJECT}-implementation-1", 420)
    if code != "0":
        log = sh("docker", "logs", "--tail", "40", f"{PROJECT}-implementation-1", check=False)
        raise RuntimeError(f"seed {seed} sigma {sigma}: evaluation exit {code}\n{log}")
    time.sleep(2)
    sh("docker", "restart", f"{PROJECT}-sas_datalogger-1", env=env)
    dest = out_dir / f"sigma{sigma:.2f}_seed{seed:.1f}.mat"
    return collect_mat(before, dest)


def trace_from_mat(path: Path):
    """kappa_1 trace (t, k) from first contact; also the peak measured press."""
    d = scipy.io.loadmat(path)
    a = np.squeeze(np.asarray(d["poly_a_hat"], dtype=float))
    k1 = a if a.ndim == 1 else a[:, 0]
    cp = np.squeeze(np.asarray(d["contact_point"], dtype=float))
    cp = cp.reshape(cp.shape[0], -1)[:, 1:4]
    touched = np.where(np.linalg.norm(cp, axis=1) > 1e-9)[0]
    if len(touched) == 0:
        return np.zeros_like(k1), k1, 0.0
    i0 = int(touched[0])
    f_n = np.squeeze(np.asarray(d["f_n"], dtype=float)).ravel()
    a_final = a[-1] if a.ndim == 2 else np.array([a[-1]])
    return (np.arange(len(k1) - i0) * SAMPLING_TIME, k1[i0:],
            float(np.nanmax(f_n[i0:])) if len(f_n) > i0 else 0.0, a_final)


def plot(sigma: float, traces: list, out_dir: Path, identified_k1: float):
    fig, ax = plt.subplots(figsize=(9, 5.5))
    cmap = plt.get_cmap("viridis")
    for (seed, t, k, peak) in traces:
        color = cmap(np.log10(seed / 600.0) / np.log10(25000.0 / 600.0))
        ax.plot(t, k, lw=1.2, color=color,
                label=f"{seed:.0f} → {k[-1]:.0f} (peak {peak:.1f} N)")
    ax.axhline(identified_k1, color="k", ls="--", lw=1.5,
               label=f"identified baseline κ₁ = {identified_k1:.0f}")
    ax.set_xlabel("t since first contact (s)")
    ax.set_ylabel("κ̂₁ (N/m)")
    ax.set_title(f"polynomial-model adaptation — sensor noise σ = {sigma} N "
                 f"(20 seeds, plane fixed, clamp 25 N)")
    ax.grid(alpha=0.3)
    ax.legend(fontsize=7, ncol=2, loc="best")
    fig.tight_layout()
    fig.savefig(out_dir / f"adaptation_noise_sigma_{sigma:.2f}.png", dpi=150)
    plt.close(fig)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/tmp/opencode/adaptation_matrix")
    ap.add_argument("--run-seconds", type=float, default=90.0)
    args = ap.parse_args()
    out_dir = Path(args.out)
    (out_dir / "mats").mkdir(parents=True, exist_ok=True)

    plane = plane_from_yaml(PLANE_YAML)
    identified = identified_coeffs(POLY_FILE)
    higher_order = identified[1:]
    print(f"plane {plane} m from {PLANE_YAML.name}; identified k_z (N/m^i) = {identified}",
          flush=True)

    # keep the mirror (object servers) up for the whole matrix, no recording
    # the mirror runs headless (its GLFW viewer path has no GPU access in the
    # container; the user watches the mujoco driver window instead)
    env = dict(os.environ, ROS_DOMAIN_ID="91", PROJECT=PROJECT, DISPLAY="",
               JOINTS_TOPIC="/ur3e_1/get/joint_states",
               OBJECT_PREFIX="/sas_robot_driver_coppeliasim/object", REC_NAME="")
    sh("docker", "compose", "-p", PROJECT, "-f", COMPOSE, "up", "-d", "robot_mirror",
       env=env, cwd=str(DOCKER_DIR))
    # mujoco comes from the evaluation compose; HEADLESS=false + DISPLAY make it headful
    sh("docker", "compose", "-p", PROJECT, "-f", "compose_force_limit_mujoco.yml",
       "up", "-d", "mujoco", env=env, cwd=str(DOCKER_DIR))

    summary = []
    total = len(SIGMAS) * N_SEEDS
    n = 0
    for sigma in SIGMAS:
        traces = []
        for i, seed in enumerate(SEEDS):
            n += 1
            t0 = time.time()
            for attempt in range(3):
                try:
                    mat = run_one(plane, float(seed), sigma, i, args.run_seconds,
                                  out_dir / "mats", higher_order)
                    break
                except Exception as e:
                    if attempt == 2:
                        raise
                    print(f"  retry ({e})", flush=True)
                    time.sleep(10)
            t, k, peak, a_final = trace_from_mat(mat)
            traces.append((float(seed), t, k, peak))
            k2f = float(a_final[1]) if len(a_final) > 1 else 0.0
            k8f = float(a_final[7]) if len(a_final) > 7 else 0.0
            summary.append((sigma, float(seed), float(k[0]), float(k[-1]), peak, k2f, k8f))
            print(f"[{n}/{total}] sigma={sigma} seed={seed:.0f} k1 {k[0]:.0f}->{k[-1]:.0f} "
                  f"k2f {k2f:.0f} k8f {k8f:.2e} peak {peak:.1f} N ({time.time()-t0:.0f}s)",
                  flush=True)
        plot(sigma, traces, out_dir, identified[0])
        print(f"plotted {out_dir / f'adaptation_noise_sigma_{sigma:.2f}.png'}", flush=True)

    with open(out_dir / "summary.csv", "w") as f:
        f.write("sigma_N,seed_k1,k1_start,k1_final,peak_press_N,k2_final,k8_final\n")
        for row in summary:
            f.write(",".join(f"{v:.4f}" for v in row) + "\n")
    print(f"done: 4 figures + mats + summary.csv in {out_dir}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
