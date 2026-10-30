#!/usr/bin/env python3
"""Generate MuJoCo plant variants (contact-stiffness / spring-rate) for the
force-control mismatch matrix.

Source defaults to stock_ur3e_robot.xml shipped next to this script (the
calibrated JS_3=4650 N/m + solref 0.005 XML of branch
feat/contact-plane-probing; the repo's main branch still carries the design
JS_3=10000 and no solref, so do NOT point this at a main checkout). Pass
--src to override.

The mismatch runner consumes the outputs via TAUS_LIST (tau name ->
<out>/ur3e_robot_tau_<t>.xml) or VARIANTS_LIST ("label:path,label:path").

Usage:
  python3 make_plant_variants.py --out /tmp/opencode/mismatch \
      [--taus 0.00125,0.0025,0.010,0.020] [--springs 2500,3500]
"""
import argparse
import os
import sys

CONTACT_ANCHOR = 'solref="0.005 1"'
SPRING_ANCHOR = 'stiffness="4650"'
STOCK = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "stock_ur3e_robot.xml")


def substitute(src_text, anchor, replacement, out_path):
    if src_text.count(anchor) != 1:
        sys.exit(f"anchor {anchor!r} found {src_text.count(anchor)}x in source; "
                 "the stock XML changed - update this script")
    text = src_text.replace(anchor, replacement)
    with open(out_path, "w") as fh:
        fh.write(text)
    print("wrote", out_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=STOCK)
    ap.add_argument("--out", default="/tmp/opencode/mismatch")
    ap.add_argument("--taus", default="")
    ap.add_argument("--springs", default="")
    args = ap.parse_args()
    text = open(args.src).read()
    os.makedirs(args.out, exist_ok=True)
    if not args.taus and not args.springs:
        sys.exit("give --taus and/or --springs")
    for t in filter(None, args.taus.split(",")):
        substitute(text, CONTACT_ANCHOR, f'solref="{t} 1"',
                   os.path.join(args.out, f"ur3e_robot_tau_{t}.xml"))
    for k in filter(None, args.springs.split(",")):
        substitute(text, SPRING_ANCHOR, f'stiffness="{k}"',
                   os.path.join(args.out, f"ur3e_robot_js{k}.xml"))


if __name__ == "__main__":
    main()
