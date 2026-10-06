#!/bin/bash
# Build, deploy, and run Aerio
set -euo pipefail

cd "$(dirname "$0")/.."

# A build without a real client ID installs fine and then breaks every account
# ("Could not determine client ID"), so refuse before touching anything.
CONFIG=Aerio/Config/OAuth.local.xcconfig
if [ ! -f "$CONFIG" ]; then
    echo "error: $CONFIG is missing — copy OAuth.local.xcconfig.example and set your client ID." >&2
    echo "       Nothing was built or replaced." >&2
    exit 1
fi
OAUTH_CLIENT_ID=$(sed -n 's/^[[:space:]]*OAUTH_CLIENT_ID[[:space:]]*=[[:space:]]*//p' "$CONFIG" | tr -d '[:space:]')
case "$OAUTH_CLIENT_ID" in
    "" | REPLACE_ME | your-client-id-here)
        echo "error: OAUTH_CLIENT_ID in $CONFIG is not set (got '$OAUTH_CLIENT_ID')." >&2
        echo "       Nothing was built or replaced." >&2
        exit 1
        ;;
esac

./scripts/gen-buildinfo.sh

# Sign with the same Developer ID as releases. Keychain items trust an app by its
# signature: an Apple Development build that refreshes the OAuth tokens re-creates
# them trusting only itself, so the next release (or this build, after a release)
# asks for the login password once per token item.
TEAM_ID=YP8Y455729
SIGN_ARGS=()
if security find-identity -v -p codesigning | grep -q "Developer ID Application: .*($TEAM_ID)"; then
    SIGN_ARGS=(
        CODE_SIGN_STYLE=Manual
        DEVELOPMENT_TEAM="$TEAM_ID"
        CODE_SIGN_IDENTITY="Developer ID Application"
    )
else
    echo "warning: no 'Developer ID Application ($TEAM_ID)' identity in the keychain — signing with" >&2
    echo "         Apple Development. Switching between this build and a release will ask for" >&2
    echo "         the keychain password again." >&2
fi

APP=build/Build/Products/Release/Aerio.app
# Clear the previous product so a failed build can't leave a stale one to deploy.
rm -rf "$APP"

# Build before killing or replacing anything: a failed build must leave the
# installed, running app exactly as it was. pipefail keeps tail from hiding it.
if ! xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Release \
    -derivedDataPath build \
    OAUTH_CLIENT_ID="$OAUTH_CLIENT_ID" \
    ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
    build 2>&1 | tail -3; then
    echo "error: build failed — the installed Aerio was left untouched." >&2
    exit 1
fi
if [ ! -d "$APP" ]; then
    echo "error: build reported success but $APP is missing — the installed Aerio was left untouched." >&2
    exit 1
fi

pkill -x Aerio 2>/dev/null || true
sleep 0.5

# Copy next to the old app first and swap only once the copy is complete, so a
# failed copy never leaves /Applications without Aerio.
rm -rf /Applications/Aerio.app.new
ditto "$APP" /Applications/Aerio.app.new
rm -rf /Applications/Aerio.app
mv /Applications/Aerio.app.new /Applications/Aerio.app
rm -rf "$APP"
open /Applications/Aerio.app

echo "✓ Aerio deployed and launched"
