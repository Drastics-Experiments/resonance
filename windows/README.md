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

Update checks are disabled when running from source. Packaged builds use `electron-updater` and the `Drastics-Experiments/resonance` GitHub Releases feed. Before an update can be installed, Resonance verifies the downloaded NSIS executable with Authenticode and requires the same valid signer subject, issuer, and certificate thumbprint as the currently installed executable; the release manifest checksum remains an additional integrity check. This intentionally fails closed across signing-certificate rotation, which requires a manually installed build before in-app updates can resume. Unsigned-update bypasses are available only to non-packaged Node test processes when `NODE_ENV=test` and `RESONANCE_ALLOW_UNSIGNED_UPDATE_TESTS=1` are both set. Short-lived provider media URLs remain usable for the current upload or playback request, but are removed from library state, retry records, metadata caches, and recovery backups; canonical source pages and legitimate server links are retained.

Authenticated server requests use one manual-redirect gate. It follows at most five redirects and only when each target remains on the configured server origin, so bearer and admin credentials are never sent to a cross-origin, private, or otherwise untrusted redirect target. JSON and error bodies remain bounded after the redirect gate returns the final response.
