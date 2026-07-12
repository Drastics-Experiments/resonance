# Resonance for macOS

The native SwiftUI Resonance client supports local music import and playback, playlists, favorites, metadata and cover art, authenticated server catalog/sync/upload/delete, persistent credentials, and GitHub Release updates.

## Develop

```bash
swift test
swift run LikedSongsFocus
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

The app retains the original bundle identifier, application-support paths, and credential store so installing this build upgrades the existing macOS client without losing the library or server keys.

For signed production builds, provide `MACOS_APP_IDENTITY`, `MACOS_INSTALLER_IDENTITY`, and optionally a `NOTARY_PROFILE` configured for `xcrun notarytool`.
