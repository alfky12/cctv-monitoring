#!/bin/bash

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG_FILE="$SCRIPT_DIR/smart_transcode.log"
echo "[$(date)] --- Processing: $MTX_PATH ---" >> "$LOG_FILE"

# Only process streams ending in _input
if [[ "$MTX_PATH" != *"_input"* ]]; then
    exit 0
fi

# Read recording settings from config.json
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Helper function to get config value using jq (more robust)
get_config_value() {
    local key="$1"
    local default="$2"
    
    if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
        local value=$(jq -r ".. | .$key? | select(. != null)" "$CONFIG_FILE" | head -n 1)
        if [ -n "$value" ] && [ "$value" != "null" ]; then
            echo "$value"
            return
        fi
    fi

    # Fallback to grep method if jq is missing
    if [ -f "$CONFIG_FILE" ]; then
        local value=$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CONFIG_FILE" | cut -d'"' -f4 | head -n 1)
        if [ -z "$value" ]; then
             value=$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*[^,}]*" "$CONFIG_FILE" | cut -d':' -f2 | tr -d ' "' | head -n 1)
        fi
        if [ -n "$value" ]; then
            echo "$value"
            return
        fi
    fi
    
    echo "$default"
}

# Get RTSP port
RTSP_PORT=$(get_config_value "rtsp_port" "8555")
if [ -z "$RTSP_PORT" ]; then
    RTSP_PORT="8555"
fi

SOURCE_RTSP="rtsp://127.0.0.1:$RTSP_PORT/$MTX_PATH"
TARGET_NAME="${MTX_PATH/_input/}"
TARGET_RTSP="rtsp://127.0.0.1:$RTSP_PORT/$TARGET_NAME"

VIDEO_CODEC_CONFIG=$(get_config_value "video_codec" "h264")
RESOLUTION_CONFIG=$(get_config_value "resolution" "1080p")
VIDEO_BITRATE_CONFIG=$(get_config_value "bitrate" "1200k")
MAX_VIDEO_BITRATE_CONFIG=$(get_config_value "max_bitrate" "1500k")
VIDEO_FPS_CONFIG=$(get_config_value "frame_rate" "10")
AUDIO_ENABLED_CONFIG=$(get_config_value "audio_enabled" "true")
AUDIO_BITRATE_CONFIG=$(get_config_value "audio_bitrate" "64k")

# Map resolution
case "$RESOLUTION_CONFIG" in
    "720p") RESOLUTION="1280:720" ;;
    "1080p") RESOLUTION="1920:1080" ;;
    "480p") RESOLUTION="854:480" ;;
    *) RESOLUTION="1920:1080" ;;
esac

# Detect Source Codec
sleep 2
VIDEO_CODEC=$(
  ffprobe -v error -rtsp_transport tcp -select_streams v:0 \
    -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 \
    "$SOURCE_RTSP" 2>/dev/null | head -n1 | tr -d '\r\n'
)
echo "[$(date)] Detected source codec: '$VIDEO_CODEC'" >> "$LOG_FILE"

# Build FFmpeg command
FFMPEG_CMD="ffmpeg -hide_banner -loglevel error -fflags +genpts -analyzeduration 10M -probesize 10M -flags +discardcorrupt -fps_mode passthrough -rtsp_transport tcp -i \"$SOURCE_RTSP\""

# Smart codec selection
if [ "$VIDEO_CODEC" = "h264" ] && [ "$VIDEO_CODEC_CONFIG" != "libx264" ]; then
    # Camera already H.264 and not forced to transcode -> COPY
    echo "[$(date)] H.264 detected, using COPY mode" >> "$LOG_FILE"
    FFMPEG_CMD="$FFMPEG_CMD -c:v copy"
    
    if [ "$AUDIO_ENABLED_CONFIG" = "true" ]; then
        FFMPEG_CMD="$FFMPEG_CMD -c:a copy"
    else
        FFMPEG_CMD="$FFMPEG_CMD -an"
    fi
else
    # Transcode required
    echo "[$(date)] Transcoding to H.264 ($RESOLUTION, $VIDEO_BITRATE)" >> "$LOG_FILE"
    FFMPEG_CMD="$FFMPEG_CMD -c:v libx264 -preset superfast -tune zerolatency -profile:v main -pix_fmt yuv420p"
    FFMPEG_CMD="$FFMPEG_CMD -s \"$RESOLUTION\" -b:v \"$VIDEO_BITRATE_CONFIG\" -maxrate \"$MAX_VIDEO_BITRATE_CONFIG\" -bufsize 3000k"
    FFMPEG_CMD="$FFMPEG_CMD -r \"$VIDEO_FPS_CONFIG\" -g $(($VIDEO_FPS_CONFIG * 2))"
    
    if [ "$AUDIO_ENABLED_CONFIG" = "true" ]; then
        FFMPEG_CMD="$FFMPEG_CMD -c:a aac -ac 1 -ar 44100 -b:a \"$AUDIO_BITRATE_CONFIG\""
    else
        FFMPEG_CMD="$FFMPEG_CMD -an"
    fi
fi

# Output
FFMPEG_CMD="$FFMPEG_CMD -f rtsp -rtsp_transport tcp \"$TARGET_RTSP\""

echo "[$(date)] Command: $FFMPEG_CMD" >> "$LOG_FILE"
eval $FFMPEG_CMD >> "$LOG_FILE" 2>&1
