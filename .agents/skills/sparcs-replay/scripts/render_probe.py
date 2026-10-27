#!/usr/bin/env python3
"""Offline MuJoCo render of a probing run with the identified planes.

usage: render_probe.py <js.npz> <events.json> <scene_dir> <plane_z> <out_frames_dir>

Plays back arm qpos from a wall-clock joint_states recording and, at each
probe-pass timestamp, drops a translucent green marker plate at the flange
height that the pass identified (0.0184 / 0.0182 / 0.0183 m ...), with the
finally-probed plane persisting through the end; an on-image label lists the
planes identified so far. Solves JS_3 as the plate pinned at the plane when
it would penetrate, and tracks a camera on the flange.
Run inside the mujoco container with MUJOCO_GL=osmesa.
"""
import json
import os
import sys

sys.path = [p for p in sys.path if p not in ("", "/root", os.getcwd())]  # /root/mujoco shadows the pip package

import numpy as np
import mujoco
from PIL import Image, ImageDraw

js_path, ev_path, scene_dir, plane_z, out = sys.argv[1:6]
plane_z = float(plane_z)
t, q = (lambda d: (d["t"], d["q"]))(np.load(js_path))
events = json.load(open(ev_path))
events.sort(key=lambda e: e["t"])
t_lo, t_hi = events[0]["t"] - 75.0, events[-1]["t"] + 5.0
FPS = 12

src = open(os.path.join(scene_dir, "scene.xml")).read()
MARK_X, MARK_Y = 0.4706, 0.1310
xml = src.replace("</worldbody>",
                  '  <geom name="probe_marker" type="box" size="0.055 0.055 0.00035" '
                  f'pos="{MARK_X} {MARK_Y} -1" contype="0" conaffinity="0" '
                  'rgba="0.1 0.9 0.2 0.45" mass="1e-6"/>\n  </worldbody>', 1)
if "probe_marker" not in xml:
    sys.exit("could not inject the marker geom into scene.xml")
tmp = os.path.join(scene_dir, "scene_probe_tmp.xml")  # sibling: relative includes/meshdirs resolve as usual
open(tmp, "w").write(xml)

m = mujoco.MjModel.from_xml_path(tmp)
os.remove(tmp)
gp = mujoco.mj_name2id(m, mujoco.mjtObj.mjOBJ_GEOM, "ground_plane")
m.geom_pos[gp] = [0, 0, plane_z]
mk = mujoco.mj_name2id(m, mujoco.mjtObj.mjOBJ_GEOM, "probe_marker")
d = mujoco.MjData(m)
ee = mujoco.mj_name2id(m, mujoco.mjtObj.mjOBJ_SITE, "end_effector")
nq3 = m.nq - 6

sel = (t >= t_lo) & (t <= t_hi)
t, q = t[sel], q[sel]
step = max(1, int(round(1.0 / FPS / float(np.median(np.diff(t[:2000]))))))
idx = list(range(0, len(t), step))
os.makedirs(out, exist_ok=True)
r = mujoco.Renderer(m, 360, 480)
cam = mujoco.MjvCamera()
cam.distance, cam.elevation, cam.azimuth = 0.42, -10, -135

for k, i in enumerate(idx):
    now = t[i]
    shown = [e for e in events if e["t"] <= now]
    latest = shown[-1]["plane"] if shown else None
    d.qpos[:6] = q[i]
    mujoco.mj_forward(m, d)
    fl = d.site_xpos[ee].copy()
    js3 = fl[2] - 0.0544 - plane_z
    d.qpos[6] = min(0.0, max(-0.1, js3)) if nq3 >= 1 else 0.0
    m.geom_pos[mk] = [MARK_X, MARK_Y, latest] if latest is not None else [MARK_X, MARK_Y, -1.0]
    mujoco.mj_forward(m, d)
    cam.lookat[:] = [fl[0], fl[1], fl[2] - 0.02]
    r.update_scene(d, camera=cam)
    img = Image.fromarray(r.render())
    dr = ImageDraw.Draw(img)
    if shown:
        vals = "  ".join(f"{e['plane']:.4f}" for e in shown)
        tag = f"(median -> {events[-1]['plane']:.4f} m)" if len(shown) == len(events) else \
              f"pass {len(shown)}/{len(events)}"
        dr.rectangle([6, 6, 320, 40], fill=(0, 0, 0))
        dr.text((10, 10), f"probed flange planes: {vals} m", fill=(50, 255, 75))
        dr.text((10, 24), f"{tag}   marker at {latest:.4f} m", fill=(1, 1, 1))
    img.save(f"{out}/f{k:04d}.png")
print("rendered", len(idx), "frames")
