#!/bin/bash
# Build, deploy, and run Aerio
set -e

cd "$(dirname "$0")/.."

OAUTH_CLIENT_ID=$(grep OAUTH_CLIENT_ID Aerio/Config/OAuth.local.xcconfig | cut -d= -f2 | tr -d ' ')

pkill -x Aerio 2>/dev/null || true
sleep 0.5

xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Release \
    -derivedDataPath build \
    OAUTH_CLIENT_ID="$OAUTH_CLIENT_ID" \
    build 2>&1 | tail -3

rm -rf /Applications/Aerio.app
cp -R build/Build/Products/Release/Aerio.app /Applications/Aerio.app
rm -rf build/Build/Products/Release/Aerio.app
open /Applications/Aerio.app

echo "✓ Aerio deployed and launched"
