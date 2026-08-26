#!/usr/bin/env bash
set -euo pipefail

exec 9>/tmp/teremoq-preview-source.lock
if ! flock -n 9; then
  echo "Another Teremoq preview source is already running." >&2
  exit 3
fi

readonly GATEWAY_SRT_URL="${TEREMOQ_PREVIEW_GATEWAY_SRT_URL:-srt://127.0.0.1:19000?mode=caller&streamid=teremoq-main&latency=120000}"
readonly OBSERVER_SRT_URL="${TEREMOQ_PREVIEW_OBSERVER_SRT_URL:-srt://input-observer:8890?mode=caller&streamid=publish\:input&latency=120000}"
readonly TIMECODE_X=12
readonly TIMECODE_Y=234
readonly TIMECODE_BLOCK_WIDTH=6
readonly TIMECODE_BLOCK_HEIGHT=18
readonly TIMECODE_STRIDE=7
readonly TIMECODE_PREAMBLE=10110100
readonly TIMECODE_BITS=38

video_filters="drawtext=text='TEREMOQ SOURCE  %{pts\\:hms}':x=20:y=20:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.70"
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

exec ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i 'testsrc2=size=480x270:rate=30' \
  -vf "${video_filters}" \
  -map 0:v:0 -c:v libx264 -preset ultrafast -tune zerolatency \
  -threads 2 \
  -profile:v baseline -pix_fmt yuv420p -g 15 -keyint_min 15 \
  -sc_threshold 0 -bf 0 \
  -f tee \
  "[f=mpegts:onfail=ignore:mpegts_start_pid=256:mpegts_service_id=1]${GATEWAY_SRT_URL}|[f=mpegts:onfail=ignore:mpegts_start_pid=256:mpegts_service_id=1]${OBSERVER_SRT_URL}"
