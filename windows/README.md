# Resonance for Windows

The Windows client is an Electron application with local playback, ordered playlists, search and filters, authenticated song and playlist sync, encrypted server credentials, and GitHub Release updates.

Custom playlists use the same revisioned server document as the macOS and iOS clients. They sync at launch, when the window returns to the foreground, every 60 seconds while open, and shortly after local edits. Liked Songs remains device-local, local-only tracks stay in their playlists, and hosted-song memberships hydrate as those songs are downloaded.

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
