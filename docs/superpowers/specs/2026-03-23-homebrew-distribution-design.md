# Aerio: Homebrew Distribution & CI/CD

## Goal

Distribute Aerio via Homebrew Cask so users can install with `brew install --cask aerio` without needing to configure Google Console credentials themselves. Set up CI/CD that builds, signs, notarizes, and publishes releases automatically on git tag push.

## Decisions

- **Distribution format:** Homebrew Cask (`.dmg` with signed `.app`)
- **Versioning:** Git tags (`v1.x.x`) trigger releases; CI injects version into build
- **Tap:** Own repository `VerusK/homebrew-aerio` (can migrate to main homebrew-cask later)
- **OAuth:** Credentials injected at build time via CI secrets, not hardcoded in source
- **Signing:** Developer ID Application certificate + Apple notarization

## Architecture

### Pipeline Overview

1. Developer pushes tag `v1.x.x` to main
2. GitHub Actions CI:
   - Runs tests
   - Builds Release archive
   - Signs with Developer ID certificate + notarizes with Apple
   - Packages into `.dmg`
   - Creates GitHub Release with `.dmg` asset
   - Updates Cask formula in `VerusK/homebrew-aerio`
3. User installs:
   ```bash
   brew tap VerusK/aerio
   brew install --cask aerio
   ```

### Components

- **GitHub Actions workflows** — in `VerusK/aerio` repo
- **Homebrew tap repo** — `VerusK/homebrew-aerio` with Cask formula
- **Apple Developer certificates** — stored in GitHub Secrets
- **Google OAuth credentials** — injected at build time from GitHub Secrets

## Code Signing & Notarization

### Apple Developer Setup

- Developer ID Application certificate — signs `.app`
- Developer ID Installer certificate (optional) — signs `.dmg`
- App-specific password — for `notarytool` (created at appleid.apple.com)
- Team ID

### CI Signing Process

1. Import P12 certificate from GitHub Secrets into temporary keychain
2. `codesign --deep --force --options runtime` — sign `.app`
3. `hdiutil create` — package into `.dmg`
4. `xcrun notarytool submit` — submit for Apple notarization
5. `xcrun stapler staple` — staple notarization ticket to `.dmg`

### GitHub Secrets Required

| Secret | Purpose |
|--------|---------|
| `DEVELOPER_ID_APPLICATION_P12` | Exported signing certificate |
| `P12_PASSWORD` | Certificate password |
| `APPLE_ID` | Apple ID for notarization |
| `APPLE_APP_PASSWORD` | App-specific password for notarytool |
| `APPLE_TEAM_ID` | Developer team ID |
| `GOOGLE_CLIENT_ID` | OAuth client ID for build injection |
| `TAP_GITHUB_TOKEN` | PAT with repo access to `VerusK/homebrew-aerio` for Cask updates |

## OAuth Credentials

### Build-time Injection

Only `clientId` needs injection — `redirectURI` is derived from it, and `authURL`/`tokenURL`/`scopes` are public constants.

**Approach:** `.xcconfig` files + Info.plist variable expansion.

1. Create `OAuth.xcconfig` (committed, with placeholder): `OAUTH_CLIENT_ID = REPLACE_ME`
2. Create `OAuth.local.xcconfig` (in `.gitignore`): `OAUTH_CLIENT_ID = 451766...` (real dev value)
3. `OAuth.xcconfig` includes `OAuth.local.xcconfig` if it exists (via `#include?`)
4. Add `OAUTH_CLIENT_ID` to Info.plist as `$(OAUTH_CLIENT_ID)`
5. `OAuthConfig.swift` reads from `Bundle.main.infoDictionary["OAUTH_CLIENT_ID"]`
6. CI sets the value via `xcodebuild` build setting override: `OAUTH_CLIENT_ID=...`

### Local Development

- `OAuth.local.xcconfig` file (in `.gitignore`) with dev client ID
- Template `OAuth.local.xcconfig.example` committed for reference

### Google OAuth Verification

- Current status: Testing mode (100 user limit)
- For public release: must pass Google verification (privacy policy, domain, scope description)
- Timeline: days to weeks
- Start verification process in parallel with technical setup

## CI/CD Workflows

### 1. `test.yml` — on push/PR to main

- Runs on `macos-14` or `macos-15` runner
- Executes `xcodebuild test`

### 2. `release.yml` — on tag `v*`

Steps:
1. Checkout + extract version from tag
2. Inject OAuth credentials from Secrets
3. Set version in project (`agvtool` or `PlistBuddy`)
4. `xcodebuild archive` — Release build
5. Export `.app` from archive
6. Code sign + notarize + staple
7. Package into `.dmg`
8. Create GitHub Release, attach `.dmg`
9. Compute SHA256 of `.dmg`
10. Update Cask formula in `VerusK/homebrew-aerio` (SHA + version)

## Homebrew Tap

### Repository: `VerusK/homebrew-aerio`

Structure:
```
homebrew-aerio/
  Casks/
    aerio.rb
```

### Cask Formula (`aerio.rb`)

```ruby
cask "aerio" do
  version "1.0.0"
  sha256 "abc123..."

  url "https://github.com/VerusK/aerio/releases/download/v#{version}/Aerio-#{version}.dmg"
  name "Aerio"
  desc "Gmail client for macOS"
  homepage "https://github.com/VerusK/aerio"

  app "Aerio.app"

  # Bundle ID: com.aerio.Aerio — verify data paths before first release
  zap trash: [
    "~/Library/Application Support/Aerio",
    "~/Library/Preferences/com.aerio.Aerio.plist",
    "~/Library/Caches/com.aerio.Aerio",
  ]
end
```

## Implementation Order

Dependencies determine the order:

1. **Apple Developer setup** — certificates, notarization credentials (blocker for signing)
2. **OAuth refactor** — extract credentials to build-time config (blocker for safe CI)
3. **CI: test workflow** — `test.yml` on push/PR (parallel with step 2)
4. **CI: release workflow** — `release.yml` on tag (depends on steps 1, 2)
5. **Homebrew tap** — create repo and Cask formula (depends on step 4, needs first release)
6. **Google OAuth verification** — start in parallel (not a blocker, works for 100 users meanwhile)

### Parallelism

- Steps 2 + 3 + 6 can run in parallel
- Steps 1 → 4 → 5 are strictly sequential
