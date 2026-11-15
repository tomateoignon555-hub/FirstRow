#!/bin/bash
# Builds First Row and installs it in /Applications, replacing the copy that is running (if any), then starts it.
#   bash install.sh
set -e
cd "$(dirname "$0")"

bash build.sh

echo "==> Installing"
killall FirstRow 2>/dev/null || true      # a running copy would keep the old version alive
sleep 1
rm -rf "/Applications/First Row.app"
cp -R "build/First Row.app" /Applications/

echo "Installed: /Applications/First Row.app"
open "/Applications/First Row.app"
