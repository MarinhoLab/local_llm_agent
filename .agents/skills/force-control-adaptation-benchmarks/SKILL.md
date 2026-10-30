---
name: force-control-adaptation-benchmarks
description: >-
  How to run the force-control polynomial-adaptation benchmarks for the SPARCS
  compliance-control paper (repo ~/git/paper_2026_sparcs_compliance_control,
  force_control/): the seed x force-noise matrix, the material/fixture-mismatch
  matrix (contact-stiffness solref and suspension-spring JS_3 variants), and
  the MULTI_PRESS persistent-excitation protocol on the MuJoCo stack. Covers
  detached launching, docker compose lifecycle, root-owned .mat collection,
  result aggregation, the release-asset upload flow, and the pitfalls (mirror
  must stay headless, pgrep self-match kills the shell, closing the MuJoCo
  window aborts the driver mid-run).
license: MIT
compatibility: python3 with numpy/matplotlib on the host (no marinholab
  needed); Docker + docker compose for the sparcs_rep stack; runs on the
  Linux host that carries the X session (headful driver is optional).
---

# Force-control adaptation benchmarks (MuJoCo stack)

Benchmark harness for the online polynomial force-model adaptation
(`force_control/python/src/marinholab/force_controller/force_limit_evaluation.py`)
on the SPARCS compliance-control paper repo. Three questions these matrices
answer: does adaptation survive force-sensor noise, does it survive a plant
whose material/fixture compliance differs from the identified one (Preston
scenario), and can richer excitation (MULTI_PRESS) make adapting all
polynomial orders beat adapting kappa_1 alone (it cannot under the force
clamp).

## Canonical copies and where things live

- Authoritative code: branch `feat/contact-plane-probing` (PR #4 was merged
  early; the later benchmark commits were still unmerged as of 2026-10-27 -
  CHECK `git merge-base --is-ancestor origin/feat/contact-plane-probing main`
  before assuming the stack in `force_control/` is current, and open a new PR
  if the branch is unmerged).
  - `force_control/analysis/replay_tools/adaptation_noise_matrix.py` -
    seed x sigma matrix driver; also exports the helpers the mismatch runner
    imports (`sh`, `collect_mat`, `metrics`, `identified_coeffs`, ...).
  - `force_control/analysis/replay_tools/adaptation_mismatch_matrix.py` -
    plant-variant matrix (imports the noise module as `anm`).
  - `force_control/docker/compose_robot_mirror.yml` whitelists the eval knobs:
    `FORCE_NOISE_SIGMA RANDOM_SEED POLY_ADAPT_ORDER POLY_HIGHER_ORDER_GAIN
    MULTI_PRESS PRESS_CYCLE_HOLD` and honors `ROBOT_XML` for both the mujoco
    and robot_mirror service mounts.
- `scripts/` here holds working copies of both runners plus the helpers that
  only ever existed as throwaway heredocs:
  - `make_plant_variants.py` - regenerates `/tmp/opencode/mismatch/ur3e_robot_tau_<s>.xml`
    (contact `solref` 0.005->s) and `ur3e_robot_js<k>.xml` (JS_3 `stiffness`
    4650->k). Source defaults to `stock_ur3e_robot.xml` shipped here (the
    calibrated XML of the feat branch - `main` still carries the design
    JS_3=10000 N/m and no `solref`, so never generate from a `main`
    checkout); anchors fail loudly if the XML drifts.
  - `summarize_matrix.py` - mean table (hold/peak/resid/k1/k2) over any number
    of `summary.csv` files.
  - `spring_compression_from_bag.py` - pull an `asoliman_2024` Paper_Results
    bag CSV (via the gh contents API, NOT raw - those 404) and report spring
    compression `z_sp_mm` vs measured `Fz_measured`; the hardware-spring
    reference for calibrating JS_3. See "Hardware spring reference" below.
  - `launch_matrix.sh` - the mandatory detached launcher (setsid; see below).

## Hardware spring reference (asoliman_2024 17092026_Data)

`Suspension_Identification/Paper_Results/17092026_Data/PolyManual_25` records
the real spring compression. `spring_compression_from_bag.py` reproduces:
at 25 N the spring compresses **~7 mm** (15 N~1.5-2, 20 N~4.4, 25 N~7.0,
32 N~11.5 mm) - a hardening curve (secant 3.6 N/mm at 25 N). A linear spring
matching that point is ~3.5 kN/m, i.e. the CURRENT hardware spring is SOFTER
than the current MuJoCo JS_3=4650 (5.4 mm at 25 N) and matches the js3500
cell (7.1 mm). JS_3=2500 (10 mm) over-softens these runs.

## Running a matrix

1. Bring the stack to a known state (the runners also (re)start services, but
   a clean start helps): from `force_control/docker`,
   `docker compose -p sparcs_rep -f compose_robot_mirror.yml up -d mujoco` and
   stop `implementation`/`robot_mirror` between runs.
2. Generate variants if needed:
   `python3 scripts/make_plant_variants.py --out /tmp/opencode/mismatch --taus 0.00125,0.0025,0.010,0.020 --springs 2500,3500`
3. Launch detached (NEVER a bare `nohup ... &` from an interactive tool - the
   process group dies with the tool abort; `setsid` is required):
   `./scripts/launch_matrix.sh mismatch /tmp/opencode/js_run.log VARIANTS_LIST="js4650:../mujoco/ur3e_robot.xml,js2500:/tmp/opencode/mismatch/ur3e_robot_js2500.xml" OUT_DIR=/tmp/opencode/mismatch/results_js`
   or `./scripts/launch_matrix.sh noise /tmp/opencode/noise_run.log HEADLESS=false DISPLAY=:0`.
   Follow with `tail -f`; a full cell is ~110-150 s (single press) /
   ~140-180 s (5-cycle MULTI_PRESS), and the runner prints `[i/N] ...` per run
   and a `done: ...` line, writing `summary.csv`, figures, and `mats/` into
   OUT_DIR.
4. Aggregate: `python3 scripts/summarize_matrix.py /tmp/opencode/mismatch/results*/summary.csv`.

## Interpretation anchors (why the numbers look like this)

- `resid_N` is the median |measured - f_hat| over the final hold - the
  polynomial's chance to prove itself. Frozen higher orders (kappa_2..8 at
  the identified values, only kappa_1 adapting) win every cell so far,
  including the soft-spring fixture (JS_3=2500 N/m: frozen 2.99 vs adapt-all
  3.16) - the 25 N clamp keeps d_n in a few-mm window, so the monomial
  regressor stays effectively rank-1 and free kappa_2 only drifts.
- kappa_1 (frozen-higher mode) correctly tracks the fixture: 3856 identified
  -> ~2550 at JS_3=2500. The hold then sits a few N UNDER the clamp because
  the sweep-gate residual escape only fires above `POLY_ADAPT_MIN_FORCE`
  (default 8 N) - a tuning knob, not a bug.
- The fixture spring JS_3 dominates the series compliance (4650 N/m on the
  feat branch's calibrated `force_control/mujoco/ur3e_robot.xml`; `main`
  still has the design 10000 N/m, and `force_control/identification/README.md`
  documents a hardware-matched 5750); tool-geom `solref` tau is only a fine
  knob (~<5% total stiffness). Soft-spring reference for the js2500 cell:
  Ahmed's RaiSim sim uses 4x800 N/m compliant wires (`asoliman_2024`
  `RAL_IdentificationExperiments/Suspension_Identification.cpp:272`), which
  fit to ~2.5 kN/m.

## Pitfalls (each already paid for)

- The MuJoCo driver window (`HEADLESS=false DISPLAY=:0`) is for the human;
  closing it exits the driver mid-run. `robot_mirror` must run headless
  (`DISPLAY=""`): its GLFW/glad path crashes without a GPU.
- Datalogger mats land root-owned in the bind-mounted
  `force_control/docker/logs/`; the runners use `docker cp` + in-container rm.
  If you collect by hand, do the same - `mv` on the host fails with EACCES.
- Keys in the .mat come as (N,1,1)/(N,4,1): `np.squeeze` before analysis.
- Never put the runner's literal filename in the same command line as
  `pgrep -f` - the pattern matches the invoking shell and the kill takes the
  tool down; use the `awk` PID recipe in `launch_matrix.sh` and kill by PID.
- RANDOM_SEED must arrive empty-or-digits (the eval does
  `int(seed) if seed else None`); pass `RANDOM_SEED=` for unseeded.
- Release assets: figures referenced from PR comments are uploaded to the
  GitHub release via
  `curl -s -X POST "https://uploads.github.com/repos/MarinhoLab/paper_2026_sparcs_compliance_control/releases/<id>/assets?name=<unique>.png" -H "Authorization: Bearer $(gh auth token)" -H "Content-Type: image/png" --data-binary @<file>`;
  names must be unique per release (prefix re-runs, e.g. `rich_`, `hard_`).

## Verifying a change to the eval before burning hours

`cd force_control/docker && docker compose -p sparcs_rep -f compose_robot_mirror.yml build implementation`,
run the unit tests in the image (`python3 -m pytest tests -q` - 57 expected),
then smoke ONE cell through `adaptation_mismatch_matrix.py`'s `run_one()`
before launching a full matrix. With MULTI_PRESS, the `RUN_SECONDS` deadline
must only start at the FINAL hold (see `loop_deadline` init in
`force_limit_evaluation.py`).
