# Resonance for macOS

The macOS desktop client uses the shared Electron implementation in `windows/`.
It supports local music import and playback, playlists, favorites, metadata and
cover art, authenticated server catalog/sync/upload/delete, persistent
credentials, and GitHub Release updates. The macOS workflow packages that same
client with Electron-builder, so the UI can be exercised in the browser preview
without compiling a native Swift target.

## Develop

```bash
cd windows
pnpm install --frozen-lockfile
pnpm test
pnpm start
```

## Build distributable assets

From the repository root:

```bash
cd windows
MAC_ARCH=universal APP_VERSION=1.0.1 BUILD_NUMBER=1 \
  bash ../mac/scripts/build-electron.sh
```

Outputs are written to `installers/macos/dist/`:

- `Resonance-macOS.zip` and its SHA-256 file
- `Resonance-Installer.pkg`
- `latest-mac.json`, consumed by the in-app updater

For a checked local build, use `mac/scripts/build-electron.sh` from the
repository root. It prepares architecture-specific `ffmpeg-static` binaries,
combines arm64 and x64 slices for `MAC_ARCH=universal`, carries the updater
helper into `Contents/Resources`, and validates the final ZIP before returning.
Set `MAC_UPDATE_AUTHENTICITY=production`, `MAC_UPDATE_TEAM_ID`, and
`MAC_UPDATE_DESIGNATED_REQUIREMENT` only when packaging with a production
signing identity; local builds default to the development update policy.

The app retains the original external bundle identifier so existing installations update in place. On first launch, it migrates old Application Support data and preferences to Resonance names, verifies the replacement, and removes obsolete filesystem artifacts without losing the library. Account sessions and legacy server secrets are kept in the app-private `server-credentials.json` file with user-only permissions.

Users upgrading from a build that did not use this private credential file must sign in once after updating.

For signed production builds, Electron-builder consumes the app and installer
certificate secrets documented in `installers/macos/README.md` plus the
App Store Connect API key. Local builds remain ad-hoc and do not require those
credentials.
