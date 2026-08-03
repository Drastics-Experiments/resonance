# Resonance

Resonance is a cross-platform music player. Platform implementations and their installers live in separate folders so Windows, macOS, iOS, and Android can evolve independently.

## Repository layout

| Path | Purpose |
| --- | --- |
| `windows/` | Electron-based Windows application source |
| `mac/` | Native SwiftUI macOS application, updater, tests, and release tooling |
| `ios/` | Native SwiftUI iOS application |
| `android/` | Native Kotlin and Jetpack Compose Android application |
| `release/version.json` | Shared release version and build number |
| `scripts/` | Release metadata and asset validation tools |
| `installers/windows/` | Windows NSIS installer output and release documentation |
| `installers/macos/` | macOS package installer, bootstrap installer, and release assets |

## Windows development

```powershell
cd windows
pnpm install --frozen-lockfile
pnpm test
pnpm start
```

Build the per-user Windows installer with:

```powershell
pnpm run installer:win
```

The installer is written to `installers/windows/dist/` and preserves Resonance's per-user library and encrypted credentials during upgrades.

`installers/windows/Install-Resonance.ps1` is the bootstrap downloader. It fetches the latest GitHub Release and verifies the NSIS installer against the published update manifest before installing or saving it.

## Releases and updates

Release PRs use branches named `release/v<version>`. Run `node scripts/release-version.mjs --set <version> <build>` to synchronize every platform, then let the centralized release-candidate workflow build all four apps once. Merging a successful release PR publishes those exact artifacts through the single publish workflow; do not manually push the version tag. Installed builds continue to use the GitHub Release update feeds.

## macOS development

```bash
cd mac
swift test
swift run LikedSongsFocus
```

Build the packaged application, `/Applications` installer, checksums, and updater manifest with:

```bash
mac/scripts/build-release.sh
```

The packaged app checks `latest-mac.json` on GitHub Releases, verifies the downloaded app archive with SHA-256, validates its bundle identity and code signature, replaces the installed app atomically, and relaunches it. The centralized publish workflow releases both Windows and macOS update assets together with Android and iOS Simulator artifacts.

## Android development

See [`android/README.md`](android/README.md) for Android Studio, Gradle, APK installation, and emulator instructions. Pull requests that change `android/**` run lint, unit tests, and a debug APK build; the APK is uploaded as a workflow artifact.
