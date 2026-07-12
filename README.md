# Resonance

Resonance is a cross-platform music player. Platform implementations and their installers live in separate folders so Windows, macOS, and iOS can evolve independently.

## Repository layout

| Path | Purpose |
| --- | --- |
| `windows/` | Electron-based Windows application source |
| `mac/` | Native SwiftUI macOS application, updater, tests, and release tooling |
| `ios/` | Reserved for the future iOS application |
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

Tags matching `v*` run the Windows and macOS release workflows. They publish the NSIS and PKG installers plus platform update manifests to GitHub Releases. Installed builds check those release feeds and can download newer versions.

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

The packaged app checks `latest-mac.json` on GitHub Releases, verifies the downloaded app archive with SHA-256, validates its bundle identity and code signature, replaces the installed app atomically, and relaunches it. Tagged releases publish both Windows and macOS update assets.
