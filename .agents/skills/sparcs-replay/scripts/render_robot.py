#!/usr/bin/env python3
"""Offline MuJoCo render of a recorded replay.

usage: render_robot.py <js.npz> <scene_dir> <plane_z> <out_frames_dir>

Loads the stack scene, sets the ground plane, plays back arm qpos from the
joint_states recording, solves JS_3 as the plate pinned at the plane when it
would penetrate (free at springref otherwise), and tracks a camera on the
flange. Run with PYTHONPATH=/tmp/opencode/mlib MUJOCO_GL=egl.
"""
import os
import sys

import numpy as np
import mujoco

t, q = (lambda d: (d["t"], d["q"]))(np.load(sys.argv[1]))
scene_dir, plane_z, out = sys.argv[2], float(sys.argv[3]), sys.argv[4]
FPS = 12

m = mujoco.MjModel.from_xml_path(os.path.join(scene_dir, "scene.xml"))
gp = mujoco.mj_name2id(m, mujoco.mjtObj.mjOBJ_GEOM, "ground_plane")
m.geom_pos[gp] = [0, 0, plane_z]
d = mujoco.MjData(m)
ee = mujoco.mj_name2id(m, mujoco.mjtObj.mjOBJ_SITE, "end_effector")
nq3 = m.nq - 6

step = max(1, int(round(1.0 / FPS / float(np.median(np.diff(t[:2000]))))))
idx = range(0, len(t), step)
os.makedirs(out, exist_ok=True)
r = mujoco.Renderer(m, 360, 480)
cam = mujoco.MjvCamera()
cam.distance, cam.elevation, cam.azimuth = 0.55, -12, -135

for k, i in enumerate(idx):
    d.qpos[:6] = q[i]
    mujoco.mj_forward(m, d)
    fl = d.site_xpos[ee].copy()
    js3 = fl[2] - 0.0544 - plane_z
    d.qpos[6] = min(0.0, max(-0.1, js3)) if nq3 >= 1 else 0.0
    mujoco.mj_forward(m, d)
    cam.lookat[:] = [fl[0], fl[1], fl[2] - 0.02]
    r.update_scene(d, camera=cam)
    img = r.render()
    from PIL import Image
    Image.fromarray(img).save(f"{out}/f{k:04d}.png")
print("rendered", len(list(idx)), "frames")
