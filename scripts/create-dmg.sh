#!/bin/bash
set -euo pipefail

# Usage: ./scripts/create-dmg.sh <path-to-app> <version> <output-dir>
APP_PATH="$1"
VERSION="$2"
OUTPUT_DIR="$3"
DMG_NAME="AgMail-${VERSION}.dmg"
TEMP_DIR=$(mktemp -d)

echo "Creating DMG: ${DMG_NAME}"

# Create staging area with app and Applications symlink
cp -R "${APP_PATH}" "${TEMP_DIR}/AgMail.app"
ln -s /Applications "${TEMP_DIR}/Applications"

# Create DMG
hdiutil create \
  -volname "AgMail ${VERSION}" \
  -srcfolder "${TEMP_DIR}" \
  -ov \
  -format UDZO \
  "${OUTPUT_DIR}/${DMG_NAME}"

rm -rf "${TEMP_DIR}"
echo "Created: ${OUTPUT_DIR}/${DMG_NAME}"
