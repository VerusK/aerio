# AgMail: Homebrew Distribution & CI/CD

## Goal

Distribute AgMail via Homebrew Cask so users can install with `brew install --cask agmail` without needing to configure Google Console credentials themselves. Set up CI/CD that builds, signs, notarizes, and publishes releases automatically on git tag push.

## Decisions

- **Distribution format:** Homebrew Cask (`.dmg` with signed `.app`)
- **Versioning:** Git tags (`v1.x.x`) trigger releases; CI injects version into build
- **Tap:** Own repository `VerusK/homebrew-agmail` (can migrate to main homebrew-cask later)
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
   - Updates Cask formula in `VerusK/homebrew-agmail`
3. User installs:
   ```bash
   brew tap VerusK/agmail
   brew install --cask agmail
   ```

### Components

- **GitHub Actions workflows** — in `VerusK/agapp` repo
- **Homebrew tap repo** — `VerusK/homebrew-agmail` with Cask formula
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

## OAuth Credentials

### Build-time Injection

- OAuth constants passed as environment variables in CI
- Xcode project uses `.xcconfig` or build settings with `$(OAUTH_CLIENT_ID)`
- Code reads via `Bundle.main.infoDictionary` or generated Swift file
- Secrets stored in GitHub Secrets

### Local Development

- `.xcconfig.local` file (in `.gitignore`) with dev credentials
- Or environment variables in Xcode scheme

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
10. Update Cask formula in `VerusK/homebrew-agmail` (SHA + version)

## Homebrew Tap

### Repository: `VerusK/homebrew-agmail`

Structure:
```
homebrew-agmail/
  Casks/
    agmail.rb
```

### Cask Formula (`agmail.rb`)

```ruby
cask "agmail" do
  version "1.0.0"
  sha256 "abc123..."

  url "https://github.com/VerusK/agapp/releases/download/v#{version}/AgMail-#{version}.dmg"
  name "AgMail"
  desc "Gmail client for macOS"
  homepage "https://github.com/VerusK/agapp"

  app "AgMail.app"

  zap trash: [
    "~/Library/Application Support/default.store",
    "~/Library/Preferences/com.agmail.*",
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
