# Resonance

Resonance is a cross-platform music player. Platform implementations and their installers live in separate folders so Windows, macOS, and iOS can evolve independently.

## Repository layout

| Path | Purpose |
| --- | --- |
| `windows/` | Electron-based Windows application source |
| `mac/` | Reserved for the future macOS application |
| `ios/` | Reserved for the future iOS application |
| `installers/windows/` | Windows NSIS installer output and release documentation |

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

## Releases and updates

Tags matching `v*` run the Windows release workflow. The workflow builds and publishes the NSIS installer, block map, and `latest.yml` update manifest to GitHub Releases. Installed builds check that release feed and download newer versions in the background.

