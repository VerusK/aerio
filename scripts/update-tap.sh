#!/bin/bash
# Manually update the Homebrew tap (VerusK/homebrew-aerio) when CI's tap-update
# step fails (typically because TAP_TOKEN secret is expired). Pushes via the
# user's local git credentials, not the CI bot.
#
# Usage:
#   scripts/update-tap.sh <version> [sha256]
#
# Examples:
#   scripts/update-tap.sh 1.5.0
#   scripts/update-tap.sh 1.5.0 8979ec7c4c361630d1c65263ef1c37cd3a0187f721c7537a1d0abe88e6e64bf5
#
# If sha256 is omitted, the script reads it from the v<version> GitHub release
# asset's digest.
set -e

if [ $# -lt 1 ]; then
    echo "usage: $0 <version> [sha256]" >&2
    exit 1
fi

VERSION="$1"
SHA="${2:-}"

if [ -z "$SHA" ]; then
    echo "Fetching SHA256 from GitHub release v${VERSION}..."
    SHA=$(gh release view "v${VERSION}" --repo VerusK/aerio --json assets \
        --jq ".assets[] | select(.name == \"Aerio-${VERSION}.dmg\") | .digest" \
        | sed 's/^sha256://')
    if [ -z "$SHA" ]; then
        echo "Could not find SHA256 for Aerio-${VERSION}.dmg in release v${VERSION}." >&2
        echo "Make sure the release exists and the DMG is uploaded." >&2
        exit 1
    fi
fi

echo "Updating tap to v${VERSION}, sha256: ${SHA}"

TMPTAP=$(mktemp -d)
trap "rm -rf $TMPTAP" EXIT

gh repo clone VerusK/homebrew-aerio "$TMPTAP" -- --quiet
cd "$TMPTAP"

sed -i '' "s/version \".*\"/version \"${VERSION}\"/" Casks/aerio.rb
sed -i '' "s/sha256 \".*\"/sha256 \"${SHA}\"/" Casks/aerio.rb

if git diff --quiet; then
    echo "Tap formula is already up to date — nothing to push."
    exit 0
fi

git commit -am "Update Aerio to ${VERSION}"
git push origin main

echo "✓ Tap updated. brew upgrade --cask aerio will now pull v${VERSION}"
