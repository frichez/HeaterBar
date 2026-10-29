#!/bin/sh
# Builds build/HeaterBar.app. Pass --run to launch it afterwards.
set -eu
cd "$(dirname "$0")"

APP=build/HeaterBar.app
# macOS ties the Local Network permission to the exact build, so a running
# copy whose app is replaced loses access to the heaters: restart it too.
RUN="${1:-}"
pgrep -x HeaterBar >/dev/null && RUN=--run
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
    Sources/*.swift -o "$APP/Contents/MacOS/HeaterBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "$RUN" = "--run" ]; then
    pkill -x HeaterBar 2>/dev/null || true
    open "$APP"
fi
