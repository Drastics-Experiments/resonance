# Resonance Desktop

Windows and macOS share this Electron application and renderer. It provides local playback, ordered playlists, search and filters, authenticated song and playlist sync, platform-appropriate credential persistence, and GitHub Release updates.

Custom playlists use the same revisioned server document as the macOS and iOS clients. They sync at launch, when the window returns to the foreground, every 60 seconds while open, and shortly after local edits. Liked Songs remains device-local, local-only tracks stay in their playlists, and hosted-song memberships hydrate as those songs are downloaded.

## Commands

```powershell
pnpm install --frozen-lockfile
pnpm test
pnpm start
pnpm ui:browser
pnpm ui:tailscale
pnpm run package:win
pnpm run installer:win
```

`pnpm ui:browser` starts the browser client at `http://127.0.0.1:4173/ui/`.
It keeps the renderer CSP active and exposes only allowlisted, same-origin
relays for Clerk account state, the Resonance API, and opaque streaming media
capabilities. Browser playback is always stream-only; bearer tokens remain in
memory and are never included in media URLs or browser persistence. Set
`RESONANCE_UI_BROWSER_PORT` or pass `-- --port <port>` to choose another local
port. Stop the app with Ctrl+C.

`pnpm ui:tailscale` starts the same browser client on the machine's Tailscale
IPv4 address. Other devices on the same tailnet can open
the printed `http://100.x.y.z:4173/ui/` URL, subject to the tailnet ACLs. The
server binds only to that Tailscale address: wildcard and ordinary LAN
bindings are rejected. Set `RESONANCE_UI_BROWSER_PORT` or pass
`-- --port <port>` to choose another port. Production Clerk browser sessions
require a stable approved HTTPS `unblocked.mov` origin; a raw Tailscale HTTP
address intentionally cannot bypass that identity-provider restriction.

`package:win` creates a portable x64 folder in `windows/dist/`. `installer:win` creates the per-user NSIS installer under `installers/windows/dist/`.

Update checks are disabled when running from source. Packaged builds use `electron-updater` and the `Drastics-Experiments/resonance` GitHub Releases feed. Production-signed packages verify the downloaded NSIS executable with Authenticode and require the same valid signer subject, issuer, and certificate thumbprint as the currently installed executable; the release manifest checksum remains an additional integrity check. This intentionally fails closed across signing-certificate rotation, which requires a manually installed build before in-app updates can resume. The Release Studio's explicit unsigned-desktop option embeds an `unsigned` authenticity policy in that package, allowing subsequent manifest-verified updates only when both the installed app and downloaded installer report `NotSigned`. A signed app therefore cannot be downgraded into the unsigned channel by changing runtime state. All other packaged builds require a recognized embedded policy, and non-packaged tests can opt out only when `NODE_ENV=test` and `RESONANCE_ALLOW_UNSIGNED_UPDATE_TESTS=1` are both set. Short-lived provider media URLs remain usable for the current upload or playback request, but are removed from library state, retry records, metadata caches, and recovery backups; canonical source pages and legitimate server links are retained.

Authenticated server requests use one manual-redirect gate. It follows at most five redirects and only when each target remains on the configured server origin, so bearer and admin credentials are never sent to a cross-origin, private, or otherwise untrusted redirect target. JSON and error bodies remain bounded after the redirect gate returns the final response.
