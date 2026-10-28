#!/bin/sh
# Builds build/HeaterBar.app. Pass --run to launch it afterwards.
set -eu
cd "$(dirname "$0")"

APP=build/HeaterBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
    Sources/*.swift -o "$APP/Contents/MacOS/HeaterBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--run" ]; then
    pkill -x HeaterBar 2>/dev/null || true
    open "$APP"
fi
