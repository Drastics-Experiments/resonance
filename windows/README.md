# Resonance Desktop

Windows and macOS share this Electron application and renderer. It provides local playback, ordered playlists, search and filters, authenticated song and playlist sync, platform-appropriate credential persistence, and GitHub Release updates.

Custom playlists use the same revisioned server document as the macOS and iOS clients. They sync at launch, when the window returns to the foreground, every 60 seconds while open, and shortly after local edits. Liked Songs remains device-local, local-only tracks stay in their playlists, and hosted-song memberships hydrate as those songs are downloaded.

## Commands

```powershell
pnpm install --frozen-lockfile
pnpm test
pnpm start
pnpm preview:tailscale
pnpm run package:win
pnpm run installer:win
```

The renderer requires Electron's preload bridge and is not served as a browser
application. `pnpm preview:tailscale` starts only the remote-preview v1 source
export on the machine's Tailscale IPv4 address. Other devices on the same
tailnet can request the printed manifest URL, subject to the tailnet ACLs. The
server binds only to that Tailscale address: wildcard and ordinary LAN bindings
are rejected. Set `RESONANCE_REMOTE_PREVIEW_PORT` or pass `-- --port <port>` to
choose another port. Stop the export server with Ctrl+C.

The export is a short-lived, buildable snapshot of the current worktree for a
trusted Mac preview launcher on the same tailnet:

```text
GET /__resonance/preview/v1/manifest.json
GET /__resonance/preview/v1/source/<sha256>.zip
```

The versioned JSON manifest identifies project `resonance`, target
`macos-electron-preview`, the Git branch and full commit, whether the worktree
is dirty, a human-readable revision label, and the source ZIP's content-addressed
URL, byte size, and SHA-256. The launcher must reject an expired manifest,
require the archive URL to remain on the manifest origin, verify its size and
lowercase SHA-256 before extraction, and extract it into a new isolated
directory.

One snapshot is held for 24 hours so a manifest and its subsequent archive
download cannot silently refer to different working-tree versions. The archive
contains tracked files plus non-ignored uncommitted source files. It filters
repository internals, environment files, credential/session files, signing-key
formats, dependency trees, generated build directories, local application
state, and audio/video library payloads; symbolic links are rejected. Its root
contains `.launcher-terminal.zsh`, `windows/package.json`, and
`windows/pnpm-lock.yaml`. The receiving Mac creates a local Git repository,
then invokes the snapshot's standard `res_launch_macos` path to install locked
dependencies, clone and ad-hoc sign Electron under a unique Preview bundle
identity, and launch with isolated app data. The manifest never supplies a
remote command or credentials. Tailnet ACLs and Tailscale are the transport
authorization boundary; do not expose the preview address outside the trusted
tailnet.

`package:win` creates a portable x64 folder in `windows/dist/`. `installer:win` creates the per-user NSIS installer under `installers/windows/dist/`.

Update checks are normally disabled when running from source. Packaged builds use the `Drastics-Experiments/resonance` GitHub Releases feed. Stable mode selects the newest non-draft stable release containing the platform manifest. The persisted Developer Mode setting forces automatic scanning in development and Preview builds, selects the newest non-draft prerelease containing `latest.yml` on Windows or `latest-mac.json` on macOS, and never falls back to stable. An unpackaged source build reports availability without downloading or installing; Developer Mode never bypasses package, checksum, identity, or signing verification. Production-signed Windows packages verify the downloaded NSIS executable with Authenticode and require the same valid signer subject, issuer, and certificate thumbprint as the currently installed executable; the release manifest checksum remains an additional integrity check. This intentionally fails closed across signing-certificate rotation, which requires a manually installed build before in-app updates can resume. An explicitly unsigned package can update to another explicitly unsigned package. Moving to a signed package additionally requires the candidate to match the production publisher pinned in the installed package's `resonanceUpdatePublisher` metadata; missing pins require a manual trusted installation. On macOS, development-to-production upgrades likewise require the installed bundle's pinned team and designated requirement. A signed app cannot be downgraded into an unsigned channel by changing runtime state. All packaged builds require a recognized embedded policy, and non-packaged tests can opt out only when `NODE_ENV=test` and `RESONANCE_ALLOW_UNSIGNED_UPDATE_TESTS=1` are both set. Short-lived provider media URLs remain usable for the current upload or playback request, but are removed from library state, retry records, metadata caches, and recovery backups; canonical source pages and legitimate server links are retained.

Unsigned/ad-hoc channels still trust the release feed and its checksums for
unsigned/ad-hoc updates. Publisher pins protect transitions to signed production
identities; they do not make the unsigned channel resistant to compromise of
the release feed. See the platform installer READMEs for build-time pin setup.

Authenticated server requests use one manual-redirect gate. It follows at most five redirects and only when each target remains on the configured server origin, so bearer and admin credentials are never sent to a cross-origin, private, or otherwise untrusted redirect target. JSON and error bodies remain bounded after the redirect gate returns the final response.
