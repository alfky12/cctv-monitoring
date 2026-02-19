#!/bin/bash

echo "=== UNINSTALLING CCTV SYSTEM ==="

# 1. Stop Services
echo "Stopping services..."
sudo systemctl stop cctv-web mediamtx || true

# 2. Disable Services
echo "Disabling services..."
sudo systemctl disable cctv-web mediamtx || true

# 3. Remove Service Files
echo "Removing service configuration..."
sudo rm -f /etc/systemd/system/cctv-web.service
sudo rm -f /etc/systemd/system/mediamtx.service

# 4. Reload Daemon
echo "Reloading systemd..."
sudo systemctl daemon-reload

echo "✅ Services have been removed successfully."

# 5. Instructions for file removal
DIR_PATH=$(pwd)
echo ""
echo "⚠️  To completely remove the application files and recordings, run this command:"
echo "   cd .. && sudo rm -rf $DIR_PATH"
echo ""
echo "=== UNINSTALLATION COMPLETE ==="
