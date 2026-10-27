import numpy as np, rclpy, signal, sys, time
from rclpy.node import Node
from sensor_msgs.msg import JointState
out = sys.argv[1]
class R(Node):
    def __init__(self):
        super().__init__("vidrec")
        self.ts, self.q = [], []
        self.create_subscription(JointState, "/ur3e_1/get/joint_states", self.cb, 10)
    def cb(self, m):
        if len(m.position):
            self.ts.append(m.header.stamp.sec + m.header.stamp.nanosec*1e-9)
            self.q.append(m.position[:6])
rclpy.init()
t0 = time.time()
r = R()
stop = []
signal.signal(signal.SIGINT, lambda *a: stop.append(1))
signal.signal(signal.SIGTERM, lambda *a: stop.append(1))
while not stop:
    try:
        rclpy.spin_once(r, timeout_sec=0.1)
    except Exception:
        break
    if time.time() - t0 > 240: break
np.savez(out, t=np.array(r.ts), q=np.array(r.q))
print("saved", out, r.q and len(r.q))
