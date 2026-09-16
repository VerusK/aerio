#!/bin/bash
set -euo pipefail

# Usage: ./scripts/sign-and-notarize.sh <path-to-app> <version> <output-dir>
#
# Signs Aerio.app with Developer ID, notarizes it, staples the ticket, wraps it in
# a DMG, then signs/notarizes/staples the DMG too. Leaves a ready-to-ship
# <output-dir>/Aerio-<version>.dmg.
#
# Both notarization passes matter. Stapling only the DMG leaves the .app that the
# user drags to /Applications without a ticket, so its first launch needs a network
# round-trip to Apple — and fails outright with no network.
#
# Notary credentials, one of:
#   NOTARY_KEY=<path.p8> NOTARY_KEY_ID=… NOTARY_ISSUER_ID=…  # works anywhere
#   NOTARY_PROFILE=<name>                                    # interactive shells only
#
# The profile shorthand comes from `xcrun notarytool store-credentials <name> --key …`,
# which needs a real Terminal: from a non-TTY shell the keychain write fails with
# "User interaction is not allowed" — after it has already printed "Credentials
# validated", so it reads as success. Scripted callers should pass NOTARY_KEY.
#
# Optional:
#   SIGN_IDENTITY    codesign identity (default: "Developer ID Application")
#   EXPECT_TEAM_ID   fail unless the signature carries this Team ID

APP_PATH="$1"
VERSION="$2"
OUTPUT_DIR="$3"

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
DMG_PATH="${OUTPUT_DIR}/Aerio-${VERSION}.dmg"
WORK_DIR=$(mktemp -d)
MOUNT_DIR=""

cleanup() {
  [ -n "$MOUNT_DIR" ] && hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
  rm -rf "$WORK_DIR" "$MOUNT_DIR"
}
trap cleanup EXIT

if [ ! -d "$APP_PATH" ]; then
  echo "error: no app bundle at ${APP_PATH}" >&2
  exit 1
fi

# Assemble notarytool's auth flags once; every submit reuses them.
NOTARY_ARGS=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY:-}" ]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required alongside NOTARY_KEY}"
  : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required alongside NOTARY_KEY}"
  NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  echo "error: set NOTARY_PROFILE, or NOTARY_KEY + NOTARY_KEY_ID + NOTARY_ISSUER_ID" >&2
  exit 1
fi

# notarytool exits 0 for a submission that came back Invalid, so check the status
# line ourselves and dump Apple's log when it isn't Accepted.
#
# The timeout is deliberately generous. Apple clears most submissions in minutes,
# but its queue does occasionally back up for well over half an hour, and a release
# that fails because the queue was busy is worse than one that waits.
#
# tee keeps notarytool's progress visible while still capturing it — without it the
# command substitution swallows every line until the submission ends, and both the
# CI log and the terminal sit silent for the whole wait.
notarize() {
  local file="$1" output submission_id
  output=$(xcrun notarytool submit "$file" "${NOTARY_ARGS[@]}" \
    --wait --timeout 2h 2>&1 | tee /dev/stderr) || true
  if ! grep -q "status: Accepted" <<<"$output"; then
    submission_id=$(awk '/^ *id: /{print $2; exit}' <<<"$output")
    echo "error: notarization failed for ${file}" >&2
    if [ -n "$submission_id" ]; then
      xcrun notarytool log "$submission_id" "${NOTARY_ARGS[@]}" >&2 || true
    fi
    exit 1
  fi
}

# Aerio ships no frameworks or helper binaries. If that ever changes, nested code
# must be signed inside-out before the outer bundle, so stop rather than ship a
# bundle whose insides are still ad-hoc signed.
NESTED=$(find "${APP_PATH}/Contents" -mindepth 1 -type d \
  \( -name '*.framework' -o -name '*.app' -o -name '*.xpc' -o -name '*.bundle' \))
if [ -n "$NESTED" ]; then
  echo "error: nested code bundles need signing first:" >&2
  echo "$NESTED" >&2
  exit 1
fi

echo "==> Signing ${APP_PATH}"
# --options runtime enables the Hardened Runtime, which notarization requires.
# --timestamp is what keeps the signature valid after the certificate expires.
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_PATH"
codesign --verify --strict --verbose=2 "$APP_PATH"

if [ -n "${EXPECT_TEAM_ID:-}" ]; then
  ACTUAL_TEAM=$(codesign -dvv "$APP_PATH" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
  if [ "$ACTUAL_TEAM" != "$EXPECT_TEAM_ID" ]; then
    echo "error: signed with team ${ACTUAL_TEAM}, expected ${EXPECT_TEAM_ID}" >&2
    exit 1
  fi
  echo "Team ID: ${ACTUAL_TEAM}"
fi

echo "==> Notarizing app"
ditto -c -k --keepParent "$APP_PATH" "${WORK_DIR}/Aerio.zip"
notarize "${WORK_DIR}/Aerio.zip"
xcrun stapler staple "$APP_PATH"

echo "==> Building DMG"
"$(dirname "$0")/create-dmg.sh" "$APP_PATH" "$VERSION" "$OUTPUT_DIR"

echo "==> Signing DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"

echo "==> Notarizing DMG"
notarize "$DMG_PATH"
xcrun stapler staple "$DMG_PATH"

# Verify the app as the user actually receives it — inside the shipped DMG —
# rather than the copy sitting in the build directory.
echo "==> Verifying"
MOUNT_DIR=$(mktemp -d)
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" >/dev/null
xcrun stapler validate "${MOUNT_DIR}/Aerio.app"
spctl --assess --type exec --verbose=2 "${MOUNT_DIR}/Aerio.app"
hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_DIR=""

xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

echo "✓ Signed, notarized and stapled: ${DMG_PATH}"
