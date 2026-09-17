#!/bin/bash
set -euo pipefail

# Usage: ./scripts/test.sh [extra xcodebuild args…]
#
# Runs the AerioTests suite the way CI does, and fails when no test actually ran.
# xcodebuild prints "** TEST SUCCEEDED **" even after executing zero tests — which is
# what CI did while the repo had no shared scheme listing AerioTests as a testable.
#
# Extra arguments go straight to xcodebuild, e.g. -derivedDataPath <dir> or
# -only-testing:AerioTests/<TestCaseClass> (class names, not file names).
#
# Locally, the Debug test host registers "Aerio Dev" with LaunchServices; unregister it
# afterwards with `lsregister -u <derived data>/Build/Products/Debug/Aerio.app`.

cd "$(dirname "$0")/.."

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT

set +e
xcodebuild test \
    -project Aerio.xcodeproj \
    -scheme Aerio \
    -destination 'platform=macOS' \
    -skip-testing:AerioTests/GmailAPIClientTests/testConcurrent401sCoalesceIntoSingleRefresh \
    OAUTH_CLIENT_ID=test-ci-placeholder \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    "$@" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if [ "$status" -ne 0 ]; then
    echo "error: xcodebuild test failed (exit $status)" >&2
    exit "$status"
fi

# The last "Executed N tests" line is the total across all suites.
executed=$(grep -Eo 'Executed [0-9]+ tests?' "$LOG" | tail -1 | grep -Eo '[0-9]+' || true)
if [ -z "$executed" ] || [ "$executed" -eq 0 ]; then
    echo "error: xcodebuild reported success but ran no tests." >&2
    echo "       Check that Aerio.xcodeproj/xcshareddata/xcschemes/Aerio.xcscheme lists AerioTests" >&2
    echo "       as a testable, and that any -only-testing filter names a test class that exists." >&2
    exit 1
fi

echo "✓ ${executed} tests executed"
