#!/usr/bin/env bash
# Detached launcher for the force-control adaptation benchmark runners.
#
# REQUIRED: the runners must survive tool/session aborts, so they are started
# with setsid (a plain `nohup ... &` is killed with the shell's process group
# when an interactive tool aborts). Kill a run by PID only - NEVER with
# `pgrep -f <runner-name>` in the same command line as the literal filename
# (self-match kills the calling shell). Get PIDs with:
#   ps -eo pid,cmd | awk '/adaptation_mismatch_matri[x]/ && !/awk/ {print $1}'
#
# Usage: ./launch_matrix.sh <noise|> <logfile> [VAR=VALUE ...]
#   ./launch_matrix.sh mismatch /tmp/opencode/js_run.log \
#       VARIANTS_LIST="js4650:../mujoco/ur3e_robot.xml,js2500:/tmp/opencode/mismatch/ur3e_robot_js2500.xml" \
#       OUT_DIR=/tmp/opencode/mismatch/results_js
#   ./launch_matrix.sh noise /tmp/opencode/noise_run.log HEADLESS=false DISPLAY=:0
#
# Env knobs (see each runner's header): NOISE_SIGMAS/SEEDS/N_RUNS/MODES,
# TAUS_LIST/VARIANTS_LIST/OUT_DIR/RICH_RUN/MULTI_PRESS/PRESS_CYCLE_HOLD/
# FINAL_HOLD/HEADLESS/DISPLAY.
set -euo pipefail

which=${1:?usage: launch_matrix.sh <noise|mismatch> <logfile> [VAR=VALUE ...]}
log=${2:?give a log file path}
shift 2

case "$which" in
  noise)    runner=adaptation_noise_matrix.py ;;
  mismatch) runner=adaptation_mismatch_matrix.py ;;
  *) echo "unknown runner '$which' (noise|mismatch)" >&2; exit 2 ;;
esac

repo=${PAPER_REPO:-$HOME/git/paper_2026_sparcs_compliance_control}
cd "$repo/force_control" || exit 1

# the runners drive docker compose -p sparcs_rep and need the repo cwd;
# mirror runs headless unless HEADLESS=false + DISPLAY are passed explicitly
env "$@" setsid python3 "analysis/replay_tools/$runner" \
  </dev/null >"$log" 2>&1 &
pid=$!
echo "launched $runner (pgid $pid) -> $log"
echo "follow with: tail -f $log"
