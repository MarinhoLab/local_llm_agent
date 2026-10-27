# Skill: sparcs-replay

Replay `asoliman_2024` identification bags through the `paper_2026_sparcs_compliance_control`
force-control MuJoCo stack and quantify hardware-vs-sim agreement. Use when asked to
"replay bags", "overlay forces", "check agreement", "make replay gifs/videos", or to fit
suspension models from the hardware bags.

Repo: `~/git/paper_2026_sparcs_compliance_control` (PR #3, branch `feat/polynomial-force-model`).
Bags: `Suspension_Identification/experiment_data/ur3e_freq_*.csv` in the private
`MarinhoLab/asoliman_2024` repo (download with `gh api repos/MarinhoLab/asoliman_2024/contents/Suspension_Identification/experiment_data/<f> --jq .content | base64 -d > /tmp/opencode/<f>`).
Force column: `usecols=(0,21)`, press-positive = `-Fz`.

## Stack bring-up (docker/ dir, stack `sparcs_rep`)

```bash
cd <repo>/force_control/docker
ROS_DOMAIN_ID=91 FORCE_MODEL=polynomial FORCE_NORM_LIMIT=9999.0 \
POLY_INITIAL_GUESS='[4650.0]' ADAPTATION=no TRACK_GAIN=10.0 FORCE_AVG_N=2 \
docker compose -p sparcs_rep -f compose_force_limit_mujoco.yml up -d   # ~90 s warm
```

Per-run exec env (inside `sparcs_rep-implementation-1`, `source /opt/ros/jazzy/setup.sh && source /etc/bash_env`,
then `timeout 120 python3 /root/implementation/identification/mujoco_excitation.py replay 5 /root/implementation/identification/data/<bag>.npz`):

- duty bags: `SLEW=0.200 MIN_PRESS=0.0025 TRACK_GAIN=10.0 SURFACE_Z=<z_med+0.0025>` (0.0153 / 0.0142 / 0.0154 / 0.0196)
- 1Hz sines: same but `ABS=1` instead of `SURFACE_Z`
- `POLY_INITIAL_GUESS`/`FORCE_NORM_LIMIT` need trailing `.0` (ROS INTEGER param crash otherwise);
  `FORCE_NORM_LIMIT` valid range is `(1, 1e4)`.

## Gotchas (each cost a wasted run at least once)

- First replay after a cold stack start **never contacts** — always run a throwaway, then record.
- `sas_datalogger` saves only on stop: `docker compose -p sparcs_rep -f compose_force_limit_mujoco.yml restart sas_datalogger`
  before AND after each recorded run; mats land in `docker/logs/` (root-owned).
- Never SIGKILL a replay: the zombie `mujoco_excitation` holds `frame_xd` and hangs all later runs
  (`docker exec sparcs_rep-implementation-1 pkill -f mujoco_excitation`; a full `down/up` fixes DDS).
- Per-bag rig plane: `force_control/mujoco/scene.xml` ground `pos z` is bind-mounted into the mujoco
  container — sed it (`-0.0369` duty bags, `-0.0349` 5mm_Square, `-0.0340` 1Hz sines) then
  `up -d --force-recreate mujoco implementation`. Scenes/npz are baked into images otherwise → rebuild.
- Mixed sessions: a datalogger session may contain throwaway+record; identify clean runs by
  contact-burst count (`starts == 1` in `fz>3 N` transitions).
- The evaluation script moves the sim **only** via `rdi.send_target_joint_positions(q)`; publishing
  to `frame_x`/`frame_xd` `set/pose` (even through a real `ObjectClient`) moves nothing — poses are
  bookkeeping for `last_x`/`get_pose`. Any new motion code in that script MUST send joint targets.
- `docker compose build` for this stack must carry `-p sparcs_rep` — the project pins its own image
  tag (`sparcs_rep-implementation`); a build without `-p` produces an ignored `docker-implementation`
  tag and containers silently keep the old code (verify: `docker exec ... grep -c <marker> <file>`).
- compose only forwards whitelisted env (`environment:` list + `${VAR}` interpolation) — a new
  `os.environ.get("X")` in the evaluation script is dead unless added to the service; check
  `docker exec <ctr> cat /proc/$(pgrep -f force_limit_evaluation)/environ`.

## Contact-plane probing (PROBE=yes)

`force_limit_evaluation_mujoco.py` runs an opt-in probe (default `no`) before the main loop, for the
polynomial model — it lives in `M3TaskSpaceController.probe_contact_plane` (callback-driven, unit-
tested): 3 quasi-static descents (20 mm/s → 5 mm/s on force detect), flange z captured at
`PROBE_FORCE_LOW`/`PROBE_FORCE_HIGH` (default 4/12 N), zero-force extrapolation per pass, median →
`controller.contact_plane_z`; the engage latch then uses `plane − z` instead of back-computing
the origin through κ̂ (which ratcheted adaptive runs to a ~5× attractor under the force clamp).
**Every rise is physically ramped and verified** (command only steps by `fast_speed*dt`; the pass
starts once the *measured* height reaches the start height within `retract_tol` and the force has
dropped) — hardware-safe, no teleporting between passes; a rise that cannot complete or any press
above `abort_force` fails the probe instead of pressing harder.
Knobs: `PROBE_SPEED` `PROBE_FAST_SPEED` `PROBE_DETECT_FORCE` `PROBE_ABORT_FORCE` `PROBE_N`
`PROBE_BOTTOM` `PROBE_RETRACT`; logged each step as `probe_plane_z`. After a probe at a new height
the FIRST square/replay can plunge (tool at probe-start height, excitation ramp starts lower) →
peak-force runs need the throwaway first. With the probed plane (0.0182 m on the
`-0.0369` scene), adaptive square runs converge κ̂ → ≈5.6 kN/m from any seed (truth 3856 N/m +
7.05 N offset absorbed at the origin) and the peak force is seed-independent (~14.6 N vs clamp 25);
frozen low seed under-clamps (22.4 N, 5 mm). See PR #3 comment
`#issuecomment-6415081004`. Scripts:

- `record_probe.sh` — native-recorder session of the probe (wall-clock T0/T1/T2 anchoring, trim,
  llvmpipe alive-check, first-pass gif, restores plain mujoco). Env: `REC_NAME SEED ADAPT`.
- `probe_matrix.py <logs_dir> <out.png> [seeds]` — fingerprint clean mats by `poly_a_hat[0]`
  (seed) and κ̂ drift (adapted vs frozen), 2×3 κ̂/f_n figure. `probe_plane_z`, `f_n`, `d_n`,
  `f_n_hat`, `w_force` are the polynomial-branch log keys (each key has its own length — reshape
  per key, never share `n`).

## Metrics (scripts/)

Canonical copies live in the paper repo at `force_control/analysis/replay_tools/` (with a README
of run-where/gotchas) — update there first, then sync the copies here.

`overlay_metrics.py <bag.csv> <log.mat> <t0> <t1>` — engaged-to-engaged anchor (hw F>5 N 0.5 s ↔
sim F>3 N 0.25 s), correlation-optimal fine shift ±0.3 s, peak/median both sides, flange-z RMS
vs bag FK (`identification/replay_profile.fkm`). Expect corr ≥ 0.98, peak ≤ 7 % off. The 1 Hz
sines carry a constant +0.09/+0.10 s engage-threshold bias (3 N sim vs 5 N hw) — shape corr is
1.00 in every sub-window, so report it as a shift, not a phase lag.

`make_gifs.py <bag.csv> <log.mat> <t0> <t1> <speed> <out.gif>` — progressive two-panel overlay
gif (force + flange z), ffmpeg palette encoding; ~100 KB per bag. Set `set_xlim` explicitly
(FuncAnimation with an empty initial draw otherwise pins xlim to (0,1) and renders static gifs).

## Robot-perspective videos

**Preferred: the driver's native recorder** (`mujoco_record` service, profile `record`, in
`compose_force_limit_mujoco.yml` — patched `cpp-interface-mujoco`, scene camera `contact`, ffmpeg
pipe, renders the TRUE state incl. the real JS_3 slide):
`REC_NAME=<name> docker compose -f compose_force_limit_mujoco.yml -p sparcs_rec --profile record up -d mujoco_record implementation`
(never with the plain `mujoco` service — same `ur3e_1` node). Gotchas learned:
- Force Mesa llvmpipe: the iGPU EGL path intermittently produces a **static** camera (physics keeps
  running, video is a still). Keep `LIBGL_ALWAYS_SOFTWARE=1` + `MESA_LOADER_DRIVER_OVERRIDE=swrast`
  in the service env; verify takes with `ffmpeg -i f.mp4 -vf "select='not(mod(n\,60))',signalstats,metadata=print" -f null - 2>&1 | grep -oE "YAVG=[0-9.]+" | sort -u | wc -l` (>20 = alive).
- The mp4 is finalized on node STOP (grace 30 s): `docker compose ... stop mujoco_record` after each
  run; a new `REC_NAME` on the next `up` recreates the node → one mp4 per run.
- Each recording = idle(~45 s) + throwaway replay + real replay (the per-node-first-replay-never-contacts
  rule still applies). Trim window: `up ≈ mtime(mp4) − duration − 2`, run ends at
  `retract2_epoch − up`, cut `[tr−78, tr+10]` duty / `[tr−34, tr+10]` sines. Scene-motion detection is
  NOT reliable (dwell-heavy profiles); the retract clock is.

**Fallback (no record image / no EGL at all): offline playback** —
`record_js.py` (run INSIDE the implementation container with a sourced ROS env:
`python3 /tmp/record_js.py /root/logs/vid_<bag>.npz` via `docker exec -d`, stop with `pkill -TERM -f
record_js`) records the arm qpos from `/ur3e_1/get/joint_states` at ~500 Hz.

`render_robot.py` (run INSIDE the mujoco container: it has no python bindings or GL libs out of the
box — `apt-get update && apt-get install -y libosmesa6 libopengl0 && python3 -m pip install
--break-system-packages mujoco pillow` after every container recreate, then
`MUJOCO_GL=osmesa python3 render_robot.py <js.npz> /root/mujoco <plane_z> <out_dir>`; there is no
`/root/logs` mount there — write frames under `/root/out` and `docker cp` out) does offline playback:
JS_3 solved geometrically (plate pinned at the plane), camera tracks the flange site. Subsample step
MUST use `median(diff(t[:2000]))`, not `t[1]-t[0]` (duplicate first stamps once rendered 15k frames).
Encode on the host: `ffmpeg -framerate 12 -i f%04d.png -vf "fps=10,scale=480:-1,palettegen=max_colors=32
+paletteuse=dither=bayer:bayer_scale=5"` with a `drawtext` plane-label — keeps 76 s runs at 2–9 MB.

## Figures into PR comments (private repo)

Images can't be attached via API; upload to the draft release then link:
`curl -X POST https://uploads.github.com/repos/MarinhoLab/paper_2026_sparcs_compliance_control/releases/422857582/assets?name=<f>`
with `-H "Authorization: Bearer $(gh auth token)" -H "Content-Type: image/png" --data-binary @<f>`;
embed from `.../releases/download/untagged-302e0d137c288efe3681/<f>`. Re-uploading after
`DELETE /releases/assets/<id>` keeps the same URL.

## Teardown

`docker compose -p sparcs_rep -f compose_force_limit_mujoco.yml down` and restore
`scene.xml` to `-0.0369` before committing.
