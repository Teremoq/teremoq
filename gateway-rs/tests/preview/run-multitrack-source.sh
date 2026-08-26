#!/usr/bin/env bash
set -euo pipefail

exec 9>/tmp/teremoq-preview-source.lock
if ! flock -n 9; then
  echo "Another Teremoq preview source is already running." >&2
  exit 3
fi

readonly GATEWAY_HOST="${TEREMOQ_PREVIEW_GATEWAY_HOST:-127.0.0.1}"
readonly GATEWAY_PORT="${TEREMOQ_PREVIEW_GATEWAY_PORT:-19000}"
readonly OBSERVER_SRT_URL="${TEREMOQ_PREVIEW_OBSERVER_SRT_URL:-srt://input-observer:8890?mode=caller&streamid=publish\:input&latency=120000}"
readonly HQ_SRT_URL="srt://${GATEWAY_HOST}:${GATEWAY_PORT}?mode=caller&streamid=teremoq-main&latency=120000"
readonly LQ_SRT_URL="srt://${GATEWAY_HOST}:${GATEWAY_PORT}?mode=caller&streamid=teremoq-lq&latency=120000"
readonly TELEMETRY_SRT_URI="srt://${GATEWAY_HOST}:${GATEWAY_PORT}"
readonly TIMECODE_X=12
readonly TIMECODE_Y=234
readonly TIMECODE_BLOCK_WIDTH=6
readonly TIMECODE_BLOCK_HEIGHT=18
readonly TIMECODE_STRIDE=7
readonly TIMECODE_PREAMBLE=10110100
readonly TIMECODE_BITS=38

video_filters="drawtext=text='TEREMOQ MULTITRACK  %{pts\:hms}':x=20:y=20:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.70"
video_filters+=",drawbox=x=${TIMECODE_X}:y=${TIMECODE_Y}:w=378:h=${TIMECODE_BLOCK_HEIGHT}:color=black:t=fill"

for ((index = 0; index < ${#TIMECODE_PREAMBLE}; index += 1)); do
  if [[ "${TIMECODE_PREAMBLE:index:1}" == "1" ]]; then
    x=$((TIMECODE_X + index * TIMECODE_STRIDE))
    video_filters+=",drawbox=x=${x}:y=${TIMECODE_Y}:w=${TIMECODE_BLOCK_WIDTH}:h=${TIMECODE_BLOCK_HEIGHT}:color=white:t=fill"
  fi
done

for ((bit = 0; bit < TIMECODE_BITS; bit += 1)); do
  x=$((TIMECODE_X + (${#TIMECODE_PREAMBLE} + bit) * TIMECODE_STRIDE))
  divisor=$((1 << bit))
  next_divisor=$((divisor << 1))
  enable="abs(mod(floor(time(0)*100/${divisor}),2)-mod(floor(time(0)*100/${next_divisor}),2))"
  video_filters+=",drawbox=x=${x}:y=${TIMECODE_Y}:w=${TIMECODE_BLOCK_WIDTH}:h=${TIMECODE_BLOCK_HEIGHT}:color=white:t=fill:enable='${enable}'"
done

for ((bit = 0; bit < 8; bit += 1)); do
  x=$((TIMECODE_X + (${#TIMECODE_PREAMBLE} + TIMECODE_BITS + bit) * TIMECODE_STRIDE))
  divisor=$((1 << bit))
  enable="eq(mod(floor(time(0)*100/${divisor}),2),1)"
  video_filters+=",drawbox=x=${x}:y=${TIMECODE_Y}:w=${TIMECODE_BLOCK_WIDTH}:h=${TIMECODE_BLOCK_HEIGHT}:color=white:t=fill:enable='${enable}'"
done

run_hq_and_audio() {
  ffmpeg -hide_banner -loglevel warning -re \
    -f lavfi -i 'testsrc2=size=480x270:rate=30' \
    -f lavfi -i 'sine=frequency=1000:sample_rate=48000' \
    -vf "${video_filters}" \
    -map 0:v:0 -map 1:a:0 \
    -c:v libx264 -preset ultrafast -tune zerolatency -threads 2 \
    -profile:v baseline -pix_fmt yuv420p -g 15 -keyint_min 15 -sc_threshold 0 -bf 0 \
    -c:a aac -b:a 96k -ar 48000 -ac 1 \
    -f tee \
    "[f=mpegts:onfail=ignore:mpegts_start_pid=256:mpegts_service_id=1]${HQ_SRT_URL}|[f=mpegts:onfail=ignore:mpegts_start_pid=256:mpegts_service_id=1]${OBSERVER_SRT_URL}"
}

run_lq() {
  ffmpeg -hide_banner -loglevel warning -re \
    -f lavfi -i 'testsrc2=size=320x180:rate=15' \
    -vf "drawtext=text='TEREMOQ LQ FALLBACK  %{pts\:hms}':x=12:y=12:fontsize=18:fontcolor=white:box=1:boxcolor=black@0.70" \
    -map 0:v:0 -c:v libx264 -preset ultrafast -tune zerolatency -threads 1 \
    -profile:v baseline -pix_fmt yuv420p -g 15 -keyint_min 15 -sc_threshold 0 -bf 0 \
    -b:v 350k -maxrate 350k -bufsize 175k \
    -f mpegts -mpegts_start_pid 256 -mpegts_service_id 1 \
    "${LQ_SRT_URL}"
}

telemetry_records() {
  local sequence=0
  local payload
  while true; do
    payload="{\"sequence\":${sequence},\"vehicle\":\"car-01\",\"lat_e7\":$((404168000 + sequence % 1000)),\"lon_e7\":$((-37038000 + sequence % 1000)),\"speed_kph\":$((80 + sequence % 121))}"
    printf '%-255s\n' "${payload}"
    sequence=$((sequence + 1))
    sleep 0.2
  done
}

run_telemetry() {
  telemetry_records | gst-launch-1.0 -q \
    fdsrc fd=0 blocksize=256 do-timestamp=true \
    ! 'meta/x-klv,parsed=(boolean)true' \
    ! queue max-size-buffers=8 max-size-bytes=0 max-size-time=0 \
    ! mux.sink_300 \
    mpegtsmux name=mux alignment=7 \
    ! srtsink uri="${TELEMETRY_SRT_URI}" mode=caller streamid=teremoq-telemetry latency=120 wait-for-connection=false
}

pids=()
cleanup() {
  if ((${#pids[@]} > 0)); then
    kill "${pids[@]}" 2>/dev/null || true
    wait "${pids[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

run_hq_and_audio &
pids+=("$!")
run_lq &
pids+=("$!")
run_telemetry &
pids+=("$!")

set +e
wait -n "${pids[@]}"
exit_code=$?
set -e
exit "${exit_code}"
