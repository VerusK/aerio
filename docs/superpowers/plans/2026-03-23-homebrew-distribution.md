# Homebrew Distribution & CI/CD Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Distribute Aerio via `brew install --cask aerio` with automated CI/CD that builds, signs, notarizes, and publishes releases on git tag push.

**Architecture:** Git tags trigger GitHub Actions which build a signed+notarized `.dmg`, create a GitHub Release, and update a Homebrew tap repo. OAuth credentials are injected at build time via xcconfig, never committed to source.

**Tech Stack:** GitHub Actions (macOS runners), Xcode CLI tools (xcodebuild, codesign, notarytool, hdiutil), Homebrew Cask

**Spec:** `docs/superpowers/specs/2026-03-23-homebrew-distribution-design.md`

---

## File Structure

### New files
- `Aerio/Config/OAuth.xcconfig` — xcconfig with placeholder, committed
- `Aerio/Config/OAuth.local.xcconfig.example` — template for local dev
- `Aerio/Config/OAuth.local.xcconfig` — actual local dev credentials (gitignored)
- `ExportOptions.plist` — archive export config for CI
- `.github/workflows/test.yml` — test workflow on push/PR
- `.github/workflows/release.yml` — release workflow on tag
- `scripts/create-dmg.sh` — DMG creation script

### Modified files
- `Aerio/Services/OAuthConfig.swift` — read credentials from Bundle instead of hardcoded
- `Aerio/Services/OAuthManager.swift:80` — use OAuthConfig instead of hardcoded scheme
- `Aerio/Info.plist` — use xcconfig variable for URL scheme
- `Aerio.xcodeproj/project.pbxproj` — add xcconfig reference, update signing for Release
- `.gitignore` — add `OAuth.local.xcconfig`

---

## Task 1: OAuth Build-Time Injection

Refactor OAuth credentials from hardcoded values to build-time injection via xcconfig.

**Files:**
- Create: `Aerio/Config/OAuth.xcconfig`
- Create: `Aerio/Config/OAuth.local.xcconfig.example`
- Create: `Aerio/Config/OAuth.local.xcconfig` (gitignored)
- Modify: `Aerio/Services/OAuthConfig.swift`
- Modify: `Aerio/Services/OAuthManager.swift:80`
- Modify: `Aerio/Info.plist`
- Modify: `Aerio.xcodeproj/project.pbxproj`
- Modify: `.gitignore`

### Steps

- [ ] **Step 1: Create `OAuth.xcconfig` with placeholder**

```
// OAuth.xcconfig — committed to repo
// For local development, create OAuth.local.xcconfig (see .example)
// CI overrides via xcodebuild build setting: OAUTH_CLIENT_ID=...

#include? "OAuth.local.xcconfig"

OAUTH_CLIENT_ID = REPLACE_ME
OAUTH_CALLBACK_SCHEME = com.googleusercontent.apps.$(OAUTH_CLIENT_ID)
```

Save to `Aerio/Config/OAuth.xcconfig`.

- [ ] **Step 2: Create local xcconfig template and actual file**

`Aerio/Config/OAuth.local.xcconfig.example`:
```
// Copy this file to OAuth.local.xcconfig and fill in your credentials
// OAuth.local.xcconfig is gitignored
OAUTH_CLIENT_ID = your-client-id-here
```

`Aerio/Config/OAuth.local.xcconfig`:
```
OAUTH_CLIENT_ID = 451766587137-5chs7l3rup98dkpavmijkq1gm8mj365h
```

- [ ] **Step 3: Add `OAuth.local.xcconfig` to `.gitignore`**

Add to `.gitignore`:
```
OAuth.local.xcconfig
```

- [ ] **Step 4: Wire xcconfig into Xcode project**

In Xcode project settings (or directly in `project.pbxproj`):
1. Add `OAuth.xcconfig` to the project file references
2. Set `OAuth.xcconfig` as the configuration file for both Debug and Release configurations of the Aerio target

Note: Custom Info.plist keys (`OAuthClientID`, `OAuthCallbackScheme`) are injected via plist variable expansion (`$(VARIABLE)`) in the next step — no `INFOPLIST_KEY_` build settings needed (that prefix is only for Xcode's auto-generated keys).

- [ ] **Step 5: Update `Info.plist` to use xcconfig variable**

Merge into the existing `Aerio/Info.plist` — keep all existing keys and add the OAuth ones. The result should be:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>com.aerio.oauth</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>$(OAUTH_CALLBACK_SCHEME)</string>
			</array>
		</dict>
	</array>
	<key>OAuthClientID</key>
	<string>$(OAUTH_CLIENT_ID)</string>
	<key>OAuthCallbackScheme</key>
	<string>$(OAUTH_CALLBACK_SCHEME)</string>
</dict>
</plist>
```

- [ ] **Step 6: Update `OAuthConfig.swift` to read from Bundle**

```swift
import Foundation

enum OAuthConfig {
    static let clientId: String = {
        guard let id = Bundle.main.infoDictionary?["OAuthClientID"] as? String,
              id != "REPLACE_ME" else {
            fatalError("OAuth Client ID not configured. See Aerio/Config/OAuth.local.xcconfig.example")
        }
        return id
    }()

    static let redirectURI: String = {
        guard let scheme = Bundle.main.infoDictionary?["OAuthCallbackScheme"] as? String else {
            fatalError("OAuth Callback Scheme not configured.")
        }
        return "\(scheme):/oauth/callback"
    }()

    static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenURL = "https://oauth2.googleapis.com/token"
    static let userinfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"
    static let scopes = "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/userinfo.email"
}
```

- [ ] **Step 7: Remove hardcoded scheme from `OAuthManager.swift`**

In `OAuthManager.swift:80`, replace:
```swift
let callbackScheme = "com.googleusercontent.apps.451766587137-5chs7l3rup98dkpavmijkq1gm8mj365h"
```
with:
```swift
let callbackScheme = OAuthConfig.redirectURI.components(separatedBy: ":").first ?? ""
```

Wait — `redirectURI` is `com.googleusercontent.apps.XXX:/oauth/callback`. The `callbackURLScheme` parameter in ASWebAuthenticationSession needs just the scheme part (before `://`). But the current redirect URI format uses `:/oauth/callback` (single colon). Let's extract correctly:

```swift
let callbackScheme = String(OAuthConfig.redirectURI.prefix(while: { $0 != ":" }))
```

- [ ] **Step 8: Build and test locally**

Run:
```bash
xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Debug build
```
Expected: Build succeeds, app launches, OAuth login works.

Run:
```bash
xcodebuild test -project Aerio.xcodeproj -scheme Aerio -destination 'platform=macOS'
```
Expected: All 390+ tests pass.

- [ ] **Step 9: Verify CI override works**

Test that xcodebuild can override the value:
```bash
xcodebuild -project Aerio.xcodeproj -scheme Aerio -configuration Release build OAUTH_CLIENT_ID=test-client-id
```
Expected: Build succeeds. The override takes precedence over xcconfig.

- [ ] **Step 10: Commit**

```bash
git add Aerio/Config/OAuth.xcconfig Aerio/Config/OAuth.local.xcconfig.example \
  Aerio/Services/OAuthConfig.swift Aerio/Services/OAuthManager.swift \
  Aerio/Info.plist Aerio.xcodeproj/project.pbxproj .gitignore
git commit -m "refactor: extract OAuth credentials to build-time xcconfig injection"
```

---

## Task 2: CI Test Workflow

Set up GitHub Actions to run tests on every push/PR to main.

**Files:**
- Create: `.github/workflows/test.yml`

### Steps

- [ ] **Step 1: Create `.github/workflows/test.yml`**

```yaml
name: Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.4.app

      - name: Build and Test
        run: |
          xcodebuild test \
            -project Aerio.xcodeproj \
            -scheme Aerio \
            -destination 'platform=macOS' \
            OAUTH_CLIENT_ID=test-ci-placeholder \
            || exit 1
```

Note: `OAUTH_CLIENT_ID=test-ci-placeholder` is fine for tests — OAuthConfig's `fatalError` only triggers at runtime when the value is actually accessed, and tests use `MockKeychainStore` so they don't hit real OAuth.

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: add test workflow for push/PR to main"
```

- [ ] **Step 3: Push and verify**

Push to a test branch, open a PR to main, verify the workflow triggers and tests pass on GitHub.

---

## Task 3: ExportOptions & DMG Script

Create the archive export config and DMG packaging script needed by the release workflow.

**Files:**
- Create: `ExportOptions.plist`
- Create: `scripts/create-dmg.sh`

### Steps

- [ ] **Step 1: Create `ExportOptions.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>YP8Y455729</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
</dict>
</plist>
```

- [ ] **Step 2: Create `scripts/create-dmg.sh`**

```bash
#!/bin/bash
set -euo pipefail

# Usage: ./scripts/create-dmg.sh <path-to-app> <version> <output-dir>
APP_PATH="$1"
VERSION="$2"
OUTPUT_DIR="$3"
DMG_NAME="Aerio-${VERSION}.dmg"
TEMP_DIR=$(mktemp -d)

echo "Creating DMG: ${DMG_NAME}"

# Create staging area with app and Applications symlink
cp -R "${APP_PATH}" "${TEMP_DIR}/Aerio.app"
ln -s /Applications "${TEMP_DIR}/Applications"

# Create DMG
hdiutil create \
  -volname "Aerio ${VERSION}" \
  -srcfolder "${TEMP_DIR}" \
  -ov \
  -format UDZO \
  "${OUTPUT_DIR}/${DMG_NAME}"

rm -rf "${TEMP_DIR}"
echo "Created: ${OUTPUT_DIR}/${DMG_NAME}"
```

- [ ] **Step 3: Make script executable and commit**

```bash
chmod +x scripts/create-dmg.sh
git add ExportOptions.plist scripts/create-dmg.sh
git commit -m "ci: add ExportOptions.plist and DMG creation script"
```

---

## Task 4: CI Release Workflow

Set up GitHub Actions to build, sign, notarize, and publish releases on tag push.

**Files:**
- Create: `.github/workflows/release.yml`

### Prerequisites
Before this workflow can run, the following GitHub Secrets must be configured:
- `DEVELOPER_ID_APPLICATION_P12` — base64-encoded P12 certificate
- `P12_PASSWORD`
- `APPLE_ID`
- `APPLE_APP_PASSWORD`
- `APPLE_TEAM_ID` — `YP8Y455729`
- `GOOGLE_CLIENT_ID`
- `TAP_GITHUB_TOKEN` — PAT with repo access to `VerusK/homebrew-aerio`

### Steps

- [ ] **Step 1: Create `.github/workflows/release.yml`**

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-14
    env:
      SCHEME: Aerio
      PROJECT: Aerio.xcodeproj
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.4.app

      - name: Extract version from tag
        id: version
        run: |
          VERSION=${GITHUB_REF_NAME#v}
          echo "version=${VERSION}" >> "$GITHUB_OUTPUT"
          echo "Building version: ${VERSION}"

      - name: Run tests
        run: |
          xcodebuild test \
            -project $PROJECT \
            -scheme $SCHEME \
            -destination 'platform=macOS' \
            OAUTH_CLIENT_ID=test-ci-placeholder \
            || exit 1

      - name: Import signing certificate
        env:
          P12_BASE64: ${{ secrets.DEVELOPER_ID_APPLICATION_P12 }}
          P12_PASSWORD: ${{ secrets.P12_PASSWORD }}
        run: |
          CERTIFICATE_PATH=$RUNNER_TEMP/certificate.p12
          KEYCHAIN_PATH=$RUNNER_TEMP/app-signing.keychain-db
          KEYCHAIN_PASSWORD=$(openssl rand -hex 16)

          echo -n "$P12_BASE64" | base64 --decode -o $CERTIFICATE_PATH

          security create-keychain -p "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH
          security set-keychain-settings -lut 21600 $KEYCHAIN_PATH
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH

          security import $CERTIFICATE_PATH -P "$P12_PASSWORD" \
            -A -t cert -f pkcs12 -k $KEYCHAIN_PATH
          security set-key-partition-list -S apple-tool:,apple: \
            -k "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH
          security list-keychain -d user -s $KEYCHAIN_PATH

      - name: Set version
        run: |
          VERSION=${{ steps.version.outputs.version }}
          # Note: agvtool requires VERSIONING_SYSTEM = apple-generic in build settings
          # If not set, use PlistBuddy as fallback
          agvtool new-marketing-version "$VERSION"
          agvtool new-version -all "${VERSION//\.}"

      - name: Archive
        run: |
          xcodebuild archive \
            -project $PROJECT \
            -scheme $SCHEME \
            -configuration Release \
            -archivePath $RUNNER_TEMP/Aerio.xcarchive \
            OAUTH_CLIENT_ID=${{ secrets.GOOGLE_CLIENT_ID }} \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGN_IDENTITY="Developer ID Application" \
            DEVELOPMENT_TEAM=${{ secrets.APPLE_TEAM_ID }}

      - name: Export archive
        run: |
          xcodebuild -exportArchive \
            -archivePath $RUNNER_TEMP/Aerio.xcarchive \
            -exportOptionsPlist ExportOptions.plist \
            -exportPath $RUNNER_TEMP/export

      - name: Create DMG
        run: |
          ./scripts/create-dmg.sh \
            "$RUNNER_TEMP/export/Aerio.app" \
            "${{ steps.version.outputs.version }}" \
            "$RUNNER_TEMP"

      - name: Notarize DMG
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_APP_PASSWORD: ${{ secrets.APPLE_APP_PASSWORD }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
        run: |
          DMG_PATH="$RUNNER_TEMP/Aerio-${{ steps.version.outputs.version }}.dmg"

          xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" \
            --wait

          xcrun stapler staple "$DMG_PATH"

      - name: Compute SHA256
        id: sha
        run: |
          DMG_PATH="$RUNNER_TEMP/Aerio-${{ steps.version.outputs.version }}.dmg"
          SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
          echo "sha256=${SHA}" >> "$GITHUB_OUTPUT"

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          DMG_PATH="$RUNNER_TEMP/Aerio-${{ steps.version.outputs.version }}.dmg"
          gh release create "$GITHUB_REF_NAME" "$DMG_PATH" \
            --title "Aerio ${{ steps.version.outputs.version }}" \
            --generate-notes

      - name: Update Homebrew tap
        env:
          TAP_TOKEN: ${{ secrets.TAP_GITHUB_TOKEN }}
        run: |
          VERSION=${{ steps.version.outputs.version }}
          SHA=${{ steps.sha.outputs.sha256 }}

          git clone https://x-access-token:${TAP_TOKEN}@github.com/VerusK/homebrew-aerio.git $RUNNER_TEMP/tap
          cd $RUNNER_TEMP/tap

          # Update version and sha in Cask formula (sed to avoid heredoc indentation issues)
          sed -i '' "s/version \".*\"/version \"${VERSION}\"/" Casks/aerio.rb
          sed -i '' "s/sha256 \".*\"/sha256 \"${SHA}\"/" Casks/aerio.rb

          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add Casks/aerio.rb
          git commit -m "Update Aerio to ${VERSION}"
          git push

      - name: Cleanup keychain
        if: always()
        run: security delete-keychain $RUNNER_TEMP/app-signing.keychain-db || true
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add release workflow with signing, notarization, and tap update"
```

---

## Task 5: Homebrew Tap Repository

Create the `VerusK/homebrew-aerio` repository with initial Cask formula.

**Files (in separate repo):**
- Create: `VerusK/homebrew-aerio` repo on GitHub
- Create: `Casks/aerio.rb`

### Steps

- [ ] **Step 1: Create the repository**

```bash
gh repo create VerusK/homebrew-aerio --public --description "Homebrew tap for Aerio"
```

- [ ] **Step 2: Clone and add initial Cask formula**

```bash
git clone git@github.com:VerusK/homebrew-aerio.git /tmp/homebrew-aerio
cd /tmp/homebrew-aerio
mkdir -p Casks
```

Create `Casks/aerio.rb`:
```ruby
cask "aerio" do
  version "0.0.0"
  sha256 "placeholder"

  url "https://github.com/VerusK/aerio/releases/download/v#{version}/Aerio-#{version}.dmg"
  name "Aerio"
  desc "Gmail client for macOS"
  homepage "https://github.com/VerusK/aerio"

  app "Aerio.app"

  zap trash: [
    "~/Library/Application Support/Aerio",
    "~/Library/Preferences/com.aerio.Aerio.plist",
    "~/Library/Caches/com.aerio.Aerio",
  ]
end
```

- [ ] **Step 3: Commit and push**

```bash
git add Casks/aerio.rb
git commit -m "Initial Cask formula (placeholder)"
git push origin main
```

- [ ] **Step 4: Create GitHub PAT for tap updates**

Go to GitHub Settings > Developer settings > Personal access tokens > Fine-grained tokens:
- Name: `aerio-tap-update`
- Repository access: Only `VerusK/homebrew-aerio`
- Permissions: Contents (Read and Write)

Save the token as `TAP_GITHUB_TOKEN` secret in the `VerusK/aerio` repository.

---

## Task 6: Apple Developer Certificates Setup

Manual steps — export Developer ID certificates and configure GitHub Secrets.

### Steps

- [ ] **Step 1: Create Developer ID Application certificate**

In Apple Developer portal (developer.apple.com):
1. Certificates, Identifiers & Profiles > Certificates > Create
2. Select "Developer ID Application"
3. Upload CSR (generated via Keychain Access > Certificate Assistant > Request a Certificate)
4. Download and install the certificate

- [ ] **Step 2: Export as P12**

In Keychain Access:
1. Find "Developer ID Application: [Your Name]"
2. Right-click > Export
3. Save as `.p12` with a strong password

- [ ] **Step 3: Base64 encode the P12**

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
```

- [ ] **Step 4: Create app-specific password**

Go to appleid.apple.com > Sign-In and Security > App-Specific Passwords > Generate.

- [ ] **Step 5: Configure GitHub Secrets**

In `VerusK/aerio` repo Settings > Secrets and variables > Actions, add:

| Secret | Value |
|--------|-------|
| `DEVELOPER_ID_APPLICATION_P12` | Base64-encoded P12 from step 3 |
| `P12_PASSWORD` | Password used in step 2 |
| `APPLE_ID` | Your Apple ID email |
| `APPLE_APP_PASSWORD` | App-specific password from step 4 |
| `APPLE_TEAM_ID` | `YP8Y455729` |
| `GOOGLE_CLIENT_ID` | `451766587137-5chs7l3rup98dkpavmijkq1gm8mj365h` |
| `TAP_GITHUB_TOKEN` | PAT from Task 5 Step 4 |

---

## Task 7: First Release

End-to-end test of the entire pipeline.

### Steps

- [ ] **Step 1: Merge all CI/CD changes to main**

Ensure Tasks 1-4 are merged to main branch.

- [ ] **Step 2: Tag and push**

```bash
git tag v1.0.0
git push origin v1.0.0
```

- [ ] **Step 3: Monitor the release workflow**

```bash
gh run watch
```

Expected: Workflow completes successfully — tests pass, archive builds, signing works, notarization succeeds, DMG is created, GitHub Release is published, tap is updated.

- [ ] **Step 4: Verify Homebrew install**

```bash
brew tap VerusK/aerio
brew install --cask aerio
```

Expected: Aerio installs and launches. OAuth login works.

- [ ] **Step 5: Verify on clean machine (optional)**

Test on a machine that has never had Aerio installed to confirm Gatekeeper doesn't block it.
