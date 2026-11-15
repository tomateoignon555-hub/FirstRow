#!/bin/bash
# Builds "First Row.app" (no ARC: no libarclite needed to target 10.9).
# Run on a Mac with the Xcode command line tools.
set -e
cd "$(dirname "$0")"
APP="build/First Row.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -fno-objc-arc -O2 -Wall -Wno-deprecated-declarations \
  -arch x86_64 -mmacosx-version-min=10.9 \
  -framework Cocoa -framework AVFoundation -framework CoreMedia \
  -framework QuartzCore -framework IOKit -framework ApplicationServices -framework Carbon \
  src/*.m -o "$APP/Contents/MacOS/FirstRow"

cp Info.plist "$APP/Contents/Info.plist"
# navigation sounds (.aif), menu icons (.png) and logo (frontrow.icns)
cp Resources/* "$APP/Contents/Resources/" 2>/dev/null || true
echo "OK -> $APP"
