#!/usr/bin/env bash
# Record the contact-plane probing with the driver's native MuJoCo recorder.
#
#   REC_NAME=probe_demo SEED=1928.0 ADAPT=yes ./record_probe.sh
#
# Stops the plain mujoco service, brings up mujoco_record (profile record,
# Mesa llvmpipe env baked into the compose service), recreates the
# implementation so the probe runs at startup while recording, waits for the
# "Probed contact plane" log line, then stops the recorder (SIGINT + 30 s
# grace finalizes the mp4), trims by the wall-clock anchor
# (up ≈ mtime(mp4) − duration − 2 == T0) and cuts a gif of the first pass.
# Restores the plain mujoco service at the end.
set -euo pipefail

DOCKER_DIR=${DOCKER_DIR:-$HOME/git/paper_2026_sparcs_compliance_control/force_control/docker}
PROJECT=${PROJECT:-sparcs_rep}
COMPOSE=compose_force_limit_mujoco.yml
REC_NAME=${REC_NAME:-probe_demo}
SEED=${SEED:-1928.0}
ADAPT=${ADAPT:-yes}
ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-91}
OUT=${OUT:-/tmp/opencode}

cd "$DOCKER_DIR"
docker compose -p "$PROJECT" -f $COMPOSE stop mujoco >/dev/null

T0=$(date +%s)
REC_NAME=$REC_NAME ROS_DOMAIN_ID=$ROS_DOMAIN_ID docker compose -p "$PROJECT" -f $COMPOSE --profile record up -d mujoco_record >/dev/null
sleep 35

T1=$(date +%s)
ROS_DOMAIN_ID=$ROS_DOMAIN_ID FORCE_MODEL=polynomial FORCE_NORM_LIMIT=25.0 \
POLY_INITIAL_GUESS="[$SEED]" POLY_K1_BOUNDS='[500.0,30000.0]' ADAPTATION=$ADAPT \
TRACK_GAIN=10.0 FORCE_AVG_N=20 PROBE=yes \
docker compose -p "$PROJECT" -f $COMPOSE up -d --force-recreate implementation >/dev/null

T2=0
for _ in $(seq 1 40); do
    sleep 5
    if docker logs ${PROJECT}-implementation-1 2>&1 | grep -q "Probed contact plane"; then
        T2=$(date +%s); break
    fi
done
[ "$T2" -gt 0 ] || { echo "probe never completed"; docker logs ${PROJECT}-implementation-1 2>&1 | tail -20; exit 1; }
sleep 5
docker compose -p "$PROJECT" -f $COMPOSE stop mujoco_record >/dev/null

MP4=videos/$REC_NAME.mp4
MT=$(stat -c %Y "$MP4")
DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$MP4")
read -r SS TO < <(python3 -c "
mt, dur, t1, t2, up = $MT, $DUR, $T1, $T2, $MT - $DUR - 2
print(round(max(0, t1 - up - 2), 1), round(min(dur, t2 - up + 4), 1))")
ffmpeg -y -v error -ss "$SS" -i "$MP4" -to "$TO" -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p "$OUT/${REC_NAME}_cut.mp4"
ALIVE=$(ffmpeg -i "$OUT/${REC_NAME}_cut.mp4" -vf "select='not(mod(n\,60))',signalstats,metadata=print" -f null - 2>&1 | grep -oE "YAVG=[0-9.]+" | sort -u | wc -l)
[ "$ALIVE" -gt 20 ] || { echo "DEAD CAMERA: only $ALIVE distinct YAVG values"; exit 1; }

ffmpeg -y -v error -ss 6 -t 30 -i "$OUT/${REC_NAME}_cut.mp4" -vf "fps=10,scale=480:-1:flags=lanczos,palettegen=max_colors=32" "$OUT/palette.png"
ffmpeg -y -v error -ss 6 -t 30 -i "$OUT/${REC_NAME}_cut.mp4" -i "$OUT/palette.png" -lavfi "fps=10,scale=480:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5" "$OUT/${REC_NAME}_pass1.gif"

docker compose -p "$PROJECT" -f $COMPOSE up -d mujoco >/dev/null
echo "mp4: $OUT/${REC_NAME}_cut.mp4 (alive: $ALIVE) | gif: $OUT/${REC_NAME}_pass1.gif"
