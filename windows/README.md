# Resonance for Windows

The Windows client is an Electron application with local playback, playlists, search and filters, authenticated server sync, encrypted server credentials, and GitHub Release updates.

## Commands

```powershell
pnpm install --frozen-lockfile
pnpm test
pnpm start
pnpm run package:win
pnpm run installer:win
```

`package:win` creates a portable x64 folder in `windows/dist/`. `installer:win` creates the per-user NSIS installer under `installers/windows/dist/`.

Update checks are disabled when running from source. Packaged builds use `electron-updater` and the `Drastics-Experiments/resonance` GitHub Releases feed.
