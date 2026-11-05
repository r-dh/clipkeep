#!/bin/sh
# Builds build/Clipkeep.app (ad-hoc signed, sandboxed, hardened runtime).
set -eu
cd "$(dirname "$0")"

APP=build/Clipkeep.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -O Sources/Core/*.swift Sources/App/*.swift \
  -o "$APP/Contents/MacOS/Clipkeep"
cp Info.plist "$APP/Contents/"
cp Resources/*.png Resources/AppIcon.icns Resources/MACCY-LICENSE "$APP/Contents/Resources/"
codesign --force --sign - --options runtime --entitlements Clipkeep.entitlements "$APP"
echo "built $APP"
