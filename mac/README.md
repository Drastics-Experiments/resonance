# Resonance for macOS

The native SwiftUI Resonance client supports local music import and playback, playlists, favorites, metadata and cover art, authenticated server catalog/sync/upload/delete, persistent credentials, and GitHub Release updates.

## Develop

```bash
swift test
swift run Resonance
```

## Build distributable assets

From the repository root:

```bash
APP_VERSION=1.0.1 BUILD_NUMBER=1 mac/scripts/build-release.sh
```

Outputs are written to `installers/macos/dist/`:

- `Resonance-macOS.zip` and its SHA-256 file
- `Resonance-macOS.pkg` and its SHA-256 file
- `latest-mac.json`, consumed by the in-app updater

The app retains the original external bundle identifier so existing installations update in place. On first launch, it migrates old Application Support data and preferences to Resonance names, verifies the replacement, and removes obsolete filesystem artifacts without losing the library. Account sessions and legacy server secrets are kept in the app-private `server-credentials.json` file with user-only permissions.

Users upgrading from a build that did not use this private credential file must sign in once after updating.

For signed production builds, provide `MACOS_APP_IDENTITY`, `MACOS_INSTALLER_IDENTITY`, `NOTARY_KEY_PATH`, `NOTARY_KEY_ID`, and `NOTARY_ISSUER_ID`. The release script derives the signing Team ID and embeds a canonical designated requirement that pins the bundle identifier and certificate Team ID. `RESONANCE_MACOS_UPDATE_TEAM_ID` may be supplied to assert the expected Team ID; a supplied `RESONANCE_MACOS_UPDATE_DESIGNATED_REQUIREMENT` must exactly equal that canonical requirement. Production updates fail closed if either identity is missing or mismatched. Ad-hoc updates are available only for a DEBUG development build with `RESONANCE_ALLOW_UNVERIFIED_UPDATES=1` explicitly set.
