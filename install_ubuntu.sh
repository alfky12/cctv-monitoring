#!/bin/bash

# CCTV Monitoring System - Auto Installer
# Optimized for Ubuntu/Debian and Orange Pi/Raspberry Pi (Armbian)

echo "=== INITIALIZING INSTALLATION ==="
set -e # Stop on error

# --- 1. Fix Broken Repositories ---
echo "Checking for broken repositories..."
if [ -f /etc/apt/sources.list.d/armbian.list ] || [ -f /etc/apt/sources.list ]; then
    sudo sed -i 's/.*bullseye-backports.*/# &/' /etc/apt/sources.list 2>/dev/null || true
    sudo sed -i 's/.*bullseye-backports.*/# &/' /etc/apt/sources.list.d/*.list 2>/dev/null || true
fi

# --- 2. Install Dependencies ---
echo "Updating system and installing dependencies..."
sudo apt-get update -y || echo "Warning: apt update had some errors, continuing..."
sudo apt-get install -y curl wget git ffmpeg build-essential sqlite3 ufw jq

# --- 3. Install Node.js LTS (v20) ---
if ! command -v node &> /dev/null; then
    echo "Installing Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# --- 4. Install MediaMTX ---
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    MEDIAMTX_ARCH="linux_amd64"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    MEDIAMTX_ARCH="linux_arm64"
else
    MEDIAMTX_ARCH="linux_armv7"   
fi

VERSION="v1.16.1"
if [ ! -f "mediamtx" ]; then
    echo "Downloading MediaMTX $VERSION for $ARCH..."
    DOWNLOAD_URL="https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/mediamtx_${VERSION}_${MEDIAMTX_ARCH}.tar.gz"
    wget -O mediamtx.tar.gz "$DOWNLOAD_URL"
    tar -xvzf mediamtx.tar.gz mediamtx mediamtx.yml
    rm mediamtx.tar.gz
    chmod +x mediamtx
fi

# --- 5. Create Supporting Scripts (Clean Bash Format) ---
echo "Generating supporting scripts..."
FULL_PATH=$(pwd)

cat << 'EOF' > smart_transcode.sh
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
    echo "[$(date)] Transcoding to H.264 ($RESOLUTION, $VIDEO_BITRATE_CONFIG)" >> "$LOG_FILE"
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
EOF

cat << 'RECORD_EOF' > record_notify.sh
#!/bin/bash
# Logic to notify web-app about new recording
curl -X POST -H "Content-Type: application/json" -d "{\"path\":\"$MTX_PATH\", \"file\":\"$MTX_SEGMENT_PATH\"}" http://localhost:3003/api/recordings/notify
RECORD_EOF

chmod +x smart_transcode.sh record_notify.sh

# --- 6. Patching Configuration ---
echo "Patching mediamtx.yml..."
cp mediamtx.yml mediamtx.yml.bak
sed -i 's/rtspAddress: :8554/rtspAddress: :8555/g' mediamtx.yml
sed -i 's/hlsAddress: :8888/hlsAddress: :8856/g' mediamtx.yml
sed -i 's/rtpAddress: :8000/rtpAddress: :8050/g' mediamtx.yml
sed -i 's/rtcpAddress: :8001/rtcpAddress: :8051/g' mediamtx.yml
sed -i 's/rtmpAddress: :1935/rtmpAddress: :1936/g' mediamtx.yml
sed -i 's/webrtcAddress: :8889/webrtcAddress: :8890/g' mediamtx.yml
sed -i 's/webrtcICEUDPMuxAddress: :8189/webrtcICEUDPMuxAddress: ""/g' mediamtx.yml
sed -i 's/apiAddress: :[0-9]\+/apiAddress: :9123/g' mediamtx.yml
sed -i 's/apiAddress: :[0-9]\+/apiAddress: :9123/g' mediamtx.yml
sed -i 's/^api: .*/api: yes/g' mediamtx.yml
# Set HLS to fMP4 for H265 support
sed -i 's/hlsVariant: .*/hlsVariant: fmp4/g' mediamtx.yml
sed -i 's/recordFormat: .*/recordFormat: fmp4/g' mediamtx.yml
# IMPORTANT: Disable global recording - Node.js controls recording per-path via API
# Only cam_X (transcoded) paths will be recorded, NOT cam_X_input (raw) paths
sed -i 's/^record: .*/record: false/g' mediamtx.yml
# Use %f (microseconds) in recordPath to prevent filename collisions
sed -i 's|recordPath: .*|recordPath: ./recordings/%path/%Y-%m-%d_%H-%M-%S-%f|g' mediamtx.yml
# Set recording retention to 7 days
sed -i 's/recordDeleteAfter: .*/recordDeleteAfter: 7d/g' mediamtx.yml
# Set notify script for new recordings
sed -i 's/runOnRecordSegmentComplete: .*/runOnRecordSegmentComplete: .\/record_notify.sh/g' mediamtx.yml
# Linux: use .sh for record notify (Node app will also set runOnReady via API on startup)
sed -i 's/record_notify\.bat/record_notify.sh/g' mediamtx.yml

# --- 7. Setup Services ---
CURRENT_USER=$(whoami)
sudo bash -c "cat > /etc/systemd/system/mediamtx.service <<EOF
[Unit]
Description=MediaMTX Streaming Server
After=network.target

[Service]
ExecStart=$FULL_PATH/mediamtx $FULL_PATH/mediamtx.yml
WorkingDirectory=$FULL_PATH
User=$CURRENT_USER
Environment=TZ=Asia/Jakarta
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

sudo bash -c "cat > /etc/systemd/system/cctv-web.service <<EOF
[Unit]
Description=CCTV Web Monitoring System
After=network.target mediamtx.service

[Service]
ExecStart=$(which node || echo /usr/bin/node) $FULL_PATH/index.js
WorkingDirectory=$FULL_PATH
User=$CURRENT_USER
Environment=NODE_ENV=production
Environment=TZ=Asia/Jakarta
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

# --- 8. Finalize ---
echo "Creating recordings directory..."
mkdir -p recordings
chmod 777 recordings

npm install --omit=dev --no-audit --no-fund

echo "Configuring firewall..."
sudo ufw allow 3003/tcp || true
sudo ufw allow 8555/tcp || true
sudo ufw allow 8856/tcp || true
sudo ufw allow 9123/tcp || true

echo "Setting up systemd services..."
sudo systemctl daemon-reload
sudo systemctl enable mediamtx cctv-web
sudo systemctl restart mediamtx cctv-web

# Wait for services to start
sleep 3

echo "=== INSTALLATION COMPLETE ==="
IP_ADDR=$(hostname -I | awk '{print $1}')
echo ""
echo "🎉 CCTV Monitoring System is ready!"
echo ""
echo "📺 Dashboard: http://$IP_ADDR:3003"
echo "🔐 Default Login: admin / admin123"
echo ""
echo "📊 Services Status:"
systemctl is-active --quiet cctv-web && echo "   ✅ Web App: Running" || echo "   ❌ Web App: Failed (check: journalctl -u cctv-web -n 50)"
systemctl is-active --quiet mediamtx && echo "   ✅ MediaMTX: Running" || echo "   ❌ MediaMTX: Failed"
echo ""
echo "🔧 Configuration:"
echo "   - HLS Port: 8856 (fMP4 with H265 support)"
echo "   - RTSP Port: 8555"
echo ""
echo "🧪 Quick Check Commands:"
echo "   - systemctl status cctv-web --no-pager"
echo "   - systemctl status mediamtx --no-pager"
echo "   - journalctl -u cctv-web -n 50 --no-pager"
echo "   - journalctl -u mediamtx -n 50 --no-pager"
echo "   - curl -I http://127.0.0.1:8856/healthz || true"
echo "   - Recording: 7 days retention"
echo ""
