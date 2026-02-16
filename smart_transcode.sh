#!/bin/bash

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG_FILE="$SCRIPT_DIR/smart_transcode.log"
echo "[$(date)] --- Processing: $MTX_PATH ---" >> "$LOG_FILE"

# Only process streams ending in _input
if [[ "$MTX_PATH" != *"_input"* ]]; then
    exit 0
fi

SOURCE_RTSP="rtsp://127.0.0.1:8555/$MTX_PATH"
TARGET_NAME="${MTX_PATH/_input/}"
TARGET_RTSP="rtsp://127.0.0.1:8555/$TARGET_NAME"

# Global tunable parameters to keep CPU usage low when many H.265 cameras are present
VIDEO_BITRATE="800k"
MAX_VIDEO_BITRATE="900k"
VIDEO_BUF_SIZE="1600k"
VIDEO_FPS=12
GOP_SIZE=$((VIDEO_FPS * 2))
ENC_THREADS=1

sleep 2

VIDEO_CODEC=$(
  ffprobe -v error -rtsp_transport tcp -select_streams v:0 \
    -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_RTSP" 2>/dev/null | head -n1 | tr -d '\r\n'
)
echo "[$(date)] Detected codec: '$VIDEO_CODEC'" >> "$LOG_FILE"

if [[ "$VIDEO_CODEC" == "h264" || "$VIDEO_CODEC" == "mpeg4" || -z "$VIDEO_CODEC" ]]; then
  echo "[$(date)] Skipping transcode for $MTX_PATH (codec: '$VIDEO_CODEC')" >> "$LOG_FILE"
  exit 0
fi

echo "[$(date)] Transcoding $MTX_PATH to H.264/yuv420p with ${VIDEO_BITRATE}@${VIDEO_FPS}fps..." >> "$LOG_FILE"
ffmpeg -hide_banner -loglevel error -rtsp_transport tcp -i "$SOURCE_RTSP" \
  -c:v libx264 -preset ultrafast -tune zerolatency -profile:v main -level 4.0 \
  -pix_fmt yuv420p -b:v "$VIDEO_BITRATE" -maxrate "$MAX_VIDEO_BITRATE" -bufsize "$VIDEO_BUF_SIZE" \
  -r "$VIDEO_FPS" -g "$GOP_SIZE" -threads "$ENC_THREADS" \
  -an -f rtsp -rtsp_transport tcp "$TARGET_RTSP" >> "$LOG_FILE" 2>&1
