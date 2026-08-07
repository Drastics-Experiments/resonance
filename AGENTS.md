# Resonance project guide

This file is the working context for agents modifying Resonance. Read it before making changes. It records the current source locations, platform architecture, shared product behavior, build commands, deployment expectations, and infrastructure boundaries as of 2026-08-04.

## Source of truth

The outer T3 project directory is also the sole authoritative Git checkout for the multi-platform Resonance application:

```text
/Users/lilydietrich/Documents/Resonance
```

Perform all app and release work there. Always verify it before editing:

```bash
git -C /Users/lilydietrich/Documents/Resonance status --short
git -C /Users/lilydietrich/Documents/Resonance remote -v
```

Do not recreate app checkouts under dated Codex work directories or Downloads. Distinct local Sites/API and prototype projects live under the outer project directory's `local-projects/` folder; migration recovery patches and non-source artifacts live under `local-artifacts/`. Neither folder is inside the GitHub app repository.

## Links and services

- GitHub repository: <https://github.com/Drastics-Experiments/resonance>
- Pull request used during the original cross-platform work: <https://github.com/Drastics-Experiments/resonance/pull/4>
- GitHub releases: <https://github.com/Drastics-Experiments/resonance/releases>
- Public music-server base URL: <https://music.unblocked.mov>
- Current desktop UI reference/audit site: <https://resonance-ui-audit.blithe-haven-9710.chatgpt.site>
- Original early UI reference: <https://liked-songs-focus.blithe-haven-9710.chatgpt.site>

The public domain provides access to the user's self-hosted music server. It is not intended to become third-party song storage.

## Infrastructure boundary

The production music server runs on the Windows machine named `daz-pc`. It is intended to run from the CLI and start automatically when that device starts. Do not start a second production server on the local Mac.

Server source/configuration and its music files are managed on `daz-pc`, not in the app worktree described above. If a change requires server endpoints, reverse-proxy configuration, startup tasks, storage paths, or production logs, create or use a Codex task on `daz-pc` and make the change there. Do not silently patch only the clients when the server contract is actually missing.

Never write the server access token or admin key into this file, source control, screenshots, logs, test fixtures, or release assets. The two credentials have different purposes:

- Access token: catalog reads, audio download/stream access, and playlist synchronization.
- Admin key: song upload and server-side song deletion.

Both are sent as `Authorization: Bearer <value>`. Read them from each app's secure credential store or ask the user when they are not already configured.

## Repository layout

```text
Resonance/
├── android/                 Kotlin + Jetpack Compose Android app
├── ios/                     SwiftUI iPhone/iPad app and Xcode project
├── mac/                     SwiftUI macOS app, updater, tests, scripts
├── windows/                 Electron Windows app
├── release/version.json     Shared release version and build number
├── scripts/                 Release metadata and artifact validators
├── installers/macos/        macOS PKG/ZIP/update-manifest assets
├── installers/windows/      Windows NSIS/bootstrap installer assets
└── .github/workflows/       Platform CI plus centralized candidate/publish workflows
```

Some internal target and source names still say `LikedSongsMobile`, `LikedSongsFocus`, or `LikedSongsFocusApp`. These are legacy implementation names. The user-facing product is **Resonance**. Do not casually rename internal targets, bundle identifiers, storage directories, or keychain accounts because installed apps depend on those identities for upgrades and data preservation.

## Product behavior shared by all clients

Resonance is a normal local-first music app, not merely a server browser.

- Import and play local audio and supported video/audio files.
- Play, pause, seek, skip, shuffle, repeat, change volume, and change playback speed.
- Maintain a deterministic queue. With shuffle off, a playlist advances in playlist order. With shuffle on, the play/pause control must only toggle playback; it must not choose a new random song or disable shuffle.
- Continue playing in the background where the platform supports it.
- Display metadata and embedded artwork when available. Preserve title, artist, album, duration, and artwork through server upload/download whenever the server provides them.
- Keep downloaded songs in the library but do not automatically mark every downloaded song as liked.
- `Liked Songs` is a system/device-local playlist driven by the favorite state.
- Custom playlists can be created, deleted, reordered, and edited. Removing a song from a playlist must not remove it from the library.
- Deleting a local song removes it from local playlists. Deleting a server copy is a separate admin action.
- If Download is pressed with no explicit server-song selection, download every server track not already present on the device.
- Server pages should attempt to connect automatically when opened if an access token is configured.
- Song and playlist sync should happen automatically in addition to explicit refresh actions.
- Transfer progress must remain visible when navigating away from the server page.

## Playlist synchronization contract

The shared playlist endpoint is revisioned:

```text
GET /api/v1/playlists
PUT /api/v1/playlists
```

The payload uses a document containing a revision and custom playlists. Playlist sync is a merge, not a blind replacement button:

- Pull remote playlists and remote memberships that are not locally dirty.
- Preserve local-only tracks and device-local `Liked Songs` behavior.
- Push locally created, edited, reordered, or deleted custom playlists.
- Resolve conflicts through the server revision rather than overwriting newer state unknowingly.
- Hydrate remote song memberships as those songs become available locally.

The main catalog/admin endpoints currently used by the clients are:

```text
GET    /api/v1/songs
GET    /api/v1/playlists
PUT    /api/v1/playlists
PUT    /api/v1/admin/songs?filename=...
DELETE /api/v1/admin/songs/{songID}
```

Before changing an endpoint shape, update and test every client and coordinate the server deployment on `daz-pc`.

## Current visual direction

The current theme is near-black rather than blue-gradient-heavy:

- Main background: almost black/navy.
- Raised surfaces: subtly lighter black with thin low-opacity borders.
- Primary accent: violet/purple.
- Secondary action/accent: coral where already used.
- Connected/downloaded state: green.
- Primary text: white; metadata: muted gray.
- Artwork uses rounded corners and embedded cover art when available.

The desktop/macOS layout uses a left navigation sidebar, a single scrollable center content area, and a persistent bottom player. Do not restore the removed right-side Now Playing panel or the removed decorative corner branding/status labels.

The mobile apps use four main tabs:

1. Library
2. Playlists
3. Storage
4. Server

The mini-player stays directly above the tab bar and opens the full-screen player when tapped. It must not jump based on the position of a focused text field. The keyboard may cover it; do not move it with the keyboard unless the user explicitly requests a new behavior.

### Current server-page design

- Large `Music Server` title.
- Connected pill plus hostname and connection settings affordance.
- Compact inline song, playlist, and on-device counts.
- One dark unified action strip containing `Download`, `Upload`, selection, and refresh.
- In selection mode, the selection icon becomes the number selected. Pressing it again cancels selection mode and clears the selection.
- Refresh performs a full rotation while refreshing; do not show a separate refresh popup.
- Search is followed by one filter/sort menu. `All`, `On Device`, and `Not Downloaded` belong inside this menu, not in a second segmented row.
- Do not show a redundant `SERVER LIBRARY 0 songs` heading.
- Show a compact `# / Title / Size or Time` list header and artwork-based rows.
- Download/upload progress uses a persistent frosted card above the mini-player/tab bar and remains visible on other tabs.

### Current storage-page design

- Storage summary card with local/server/available usage.
- Search and sort controls.
- `Songs`, `Downloads`, and `Files` scopes.
- Group downloaded server songs separately from files imported on the device.
- Editing supports local deletion without confusing it with server deletion.

## macOS app

Important paths:

```text
mac/Package.swift
mac/Sources/LikedSongsFocus/LikedSongsFocusApp.swift
mac/Sources/LikedSongsFocus/ContentView.swift
mac/Sources/LikedSongsFocus/MainContentView.swift
mac/Sources/LikedSongsFocus/SidebarView.swift
mac/Sources/LikedSongsFocus/Components.swift
mac/Sources/LikedSongsFocus/PlayerBarView.swift
mac/Sources/LikedSongsFocus/NowPlayingView.swift
mac/Sources/LikedSongsFocus/Theme.swift
mac/Sources/LikedSongsFocus/Models.swift
mac/Sources/LikedSongsFocus/PlayerModel.swift
mac/Sources/LikedSongsFocus/UpdateManager.swift
mac/Tests/LikedSongsFocusTests/LikedSongsFocusTests.swift
mac/scripts/test.sh
mac/scripts/build-release.sh
```

`PlayerModel.swift` owns the library, playback queue, playlists, server state, automatic playlist sync, credentials, transfer progress, and persistence. Keep UI views render-focused where practical.

Build and test:

```bash
cd /Users/lilydietrich/Documents/Resonance
mac/scripts/test.sh
swift run --package-path mac LikedSongsFocus
APP_VERSION=1.0.4 BUILD_NUMBER=1 mac/scripts/build-release.sh
```

Release outputs are under `installers/macos/dist/`, including the app ZIP, checksum, `Resonance-Installer.pkg`, and `latest-mac.json`.

The updater reads the GitHub Release feed, verifies SHA-256, validates bundle identity and code signature, replaces the installed app, and relaunches it. A production installer should be Developer ID signed and notarized; otherwise Gatekeeper will report that Apple cannot verify it is free of malware.

## iOS app

Important paths:

```text
ios/LikedSongsMobile.xcodeproj
ios/LikedSongsMobile/LikedSongsMobileApp.swift
ios/LikedSongsMobile/RootView.swift
ios/LikedSongsMobile/MusicLibrary.swift
ios/LikedSongsMobile/MusicModels.swift
ios/LikedSongsMobile/Info.plist
ios/LikedSongsMobile/Assets.xcassets/
```

`MusicLibrary.swift` owns AVFoundation playback, queue state, metadata/artwork, local persistence, remote catalog transfers, Now Playing information, and playlist sync. `RootView.swift` contains most SwiftUI screens and shared mobile presentation.

Build for Simulator:

```bash
cd /Users/lilydietrich/Documents/Resonance
xcodebuild \
  -project ios/LikedSongsMobile.xcodeproj \
  -scheme LikedSongsMobile \
  -configuration Debug \
  -sdk iphonesimulator \
  -derivedDataPath /tmp/ResonanceDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For a physical iPhone, use the configured Apple development team in Xcode, run the `LikedSongsMobile` scheme on the paired device, and allow/trust the developer profile in iPhone Settings when necessary. The user generally expects an iOS UI fix to be installed on their iPhone after verification when the paired device is reachable.

Important iOS interaction requirements:

- Search and credential fields use an explicit Done/Next flow and release focus reliably.
- The full-screen player can be dismissed by dragging downward and should reveal the actual screen behind it, not black filler.
- Scrolling must not freeze the playback progress indicator.
- Lock-screen/Dynamic Island Now Playing artwork should use real artwork or a valid fallback, never an empty black image.
- Do not remove the keyboard's Done accessory solely to avoid overlap; fix layout/focus behavior instead.

## Android app

Important paths:

```text
android/app/src/main/java/mov/unblocked/resonance/ResonanceViewModel.kt
android/app/src/main/java/mov/unblocked/resonance/data/Models.kt
android/app/src/main/java/mov/unblocked/resonance/data/ServerClient.kt
android/app/src/main/java/mov/unblocked/resonance/data/LibraryRepository.kt
android/app/src/main/java/mov/unblocked/resonance/data/CredentialStore.kt
android/app/src/main/java/mov/unblocked/resonance/playback/PlaybackService.kt
android/app/src/main/java/mov/unblocked/resonance/playback/QueuePolicy.kt
android/app/src/main/java/mov/unblocked/resonance/playback/DownloadPolicy.kt
android/app/src/main/java/mov/unblocked/resonance/ui/ResonanceApp.kt
android/app/src/main/java/mov/unblocked/resonance/ui/ResonanceTheme.kt
android/app/src/main/java/mov/unblocked/resonance/ui/Components.kt
android/app/src/main/java/mov/unblocked/resonance/ui/LibraryScreen.kt
android/app/src/main/java/mov/unblocked/resonance/ui/PlaylistsScreen.kt
android/app/src/main/java/mov/unblocked/resonance/ui/StorageScreen.kt
android/app/src/main/java/mov/unblocked/resonance/ui/ServerScreen.kt
android/app/src/main/java/mov/unblocked/resonance/ui/Player.kt
android/app/src/main/AndroidManifest.xml
```

The Android app uses Kotlin, Jetpack Compose, Media3, API 36, and JDK 17. `ResonanceViewModel.kt` owns app state and coordinates repository, server, playback, and sync behavior. UI events flow through `ResonanceActions.kt` and immutable `ResonanceUiState.kt`.

Build and test:

```bash
cd /Users/lilydietrich/Documents/Resonance/android
./gradlew --no-daemon lintDebug testDebugUnitTest assembleDebug
```

Debug APK:

```text
android/app/build/outputs/apk/debug/app-debug.apk
```

The configured Android Virtual Device is named `Resonance_API_36`. Avoid leaving a terminal command attached to the emulator forever. Use short, bounded commands. One dependable detached launch pattern on this Mac is:

```bash
launchctl remove codex.resonance-emulator 2>/dev/null || true
launchctl submit -l codex.resonance-emulator -- "$(command -v emulator)" @Resonance_API_36 -no-audio -no-boot-anim
```

Then use bounded readiness checks, install, and launch:

```bash
adb devices -l
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n mov.unblocked.resonance/.MainActivity
```

Stop it when finished:

```bash
adb emu kill || true
launchctl remove codex.resonance-emulator 2>/dev/null || true
```

`AndroidManifest.xml` currently uses `windowSoftInputMode="adjustNothing"` so the keyboard overlays the bottom UI instead of moving the mini-player.

## Windows app

Important paths:

```text
windows/main.cjs
windows/preload.cjs
windows/metadata.cjs
windows/ui/index.html
windows/ui/app.js
windows/ui/core.js
windows/ui/styles.css
windows/test/core.test.js
windows/package.json
installers/windows/Install-Resonance.ps1
```

The Windows client is Electron-based. `main.cjs` owns native filesystem, metadata, credentials, server, updater, and IPC operations. `ui/app.js` owns page behavior and state synchronization. Shared pure logic belongs in `ui/core.js` when practical so it can be unit tested.

Build and test on Windows or a compatible CI runner:

```powershell
cd windows
pnpm install --frozen-lockfile
pnpm test
pnpm start
pnpm run installer:win
```

The NSIS installer and update metadata are written under `installers/windows/dist/`. Packaged builds use `electron-updater`; update checks are intentionally disabled when running from source.

For work that must be installed or validated on `daz-pc`, use a Codex task on that machine rather than claiming local macOS validation covers Windows.

## Credentials and persistence

Do not replace secure credential storage with plaintext settings just to avoid password prompts, except for the explicitly documented Preview-only local store below.

- macOS: server URL in preferences; access/admin secrets use the existing credential-store/keychain compatibility path in `PlayerModel.swift`.
- macOS Preview: launching or relaunching `/private/tmp/Resonance Preview.app` must never show a macOS password, passcode, Keychain-access, or Keychain-permission-change prompt. The Preview-only build must not read, write, migrate, or delete server credentials through Keychain or `/usr/bin/security`. It persists access/admin values in `~/Library/Application Support/Liked Songs/server-credentials.json`, with the directory restricted to mode `0700` and the file to mode `0600`. This exception applies only to the disposable native Preview app; keep the production macOS app on its secure credential-store path. Verify by rebuilding/re-signing and relaunching at least twice with different executable hashes; neither launch may show either kind of authorization prompt.
- macOS Preview must preserve the ability to switch between existing server profiles from `Switch Profile` in the top-right local-profile menu. Keep that interaction to one profile-name-or-ID field and resolve it through `/api/v1/profiles`; do not add profile creation, deletion, management lists, or a dropdown, and do not put the profile field back in the server-credentials sheet. Persist the selected profile and keep local imports visible while scoping server-backed songs, likes, and playlists to it.
- iOS: access and admin keys are stored separately in Keychain; library files live in the app's private Application Support directory.
- Android: `CredentialStore.kt` owns credential persistence; library data is managed by `LibraryRepository.kt`.
- Windows: credentials are handled through Electron main-process IPC and encrypted OS-backed storage; state lives under Electron's per-user `userData` directory.

Preserve existing bundle/application IDs and persistence paths so updates do not wipe libraries, playlists, downloaded music, or credentials.

## CI, installers, and releases

Current workflows:

```text
.github/workflows/macos.yml
.github/workflows/ios.yml
.github/workflows/windows.yml
.github/workflows/android.yml
.github/workflows/release-candidate.yml
.github/workflows/publish-release.yml
```

- The four platform workflows remain independent native builds. They run normal path-filtered PR CI and can also be called by `release-candidate.yml`; they do not publish GitHub Releases and no longer rebuild on a pushed tag.
- Relevant pushes to `main` also run the platform workflows to populate trusted Gradle, Swift, Xcode DerivedData, pnpm, and Electron packaging caches. Pull requests restore these default-branch caches but do not update the shared cache. Do not remove this warm-cache path when optimizing CI.
- macOS PRs run Swift tests and build the app ZIP, checksum, installer PKG, and updater manifest.
- Windows PRs install with pnpm, run tests, and build the NSIS EXE, blockmap, and `latest.yml`.
- iOS PRs build an unsigned Simulator `.app`; the candidate workflow packages it as a Simulator ZIP. This is not an installable App Store, Ad Hoc, or physical-device release.
- Android PRs run lint/tests/build. The candidate workflow packages the release-signed APK and its Android updater manifest; it is not a Play Store bundle.

### Fast GitHub Release workflow

The release pipeline is build-once and promote-on-merge. Do not restore per-platform tag publishing or let multiple platform jobs write to one public release.

The authoritative release version is `release/version.json`. It contains the semantic version and monotonically increasing cross-platform build number. The version synchronization tool updates and validates Windows, Android, iOS, and macOS metadata:

```bash
node scripts/release-version.mjs --check
node scripts/release-version.mjs --set 1.1.2 13
```

From a clean committed branch containing the desired app updates, the canonical one-command release is:

```bash
/Users/lilydietrich/Documents/Resonance/scripts/release-now.mjs
```

The command increments the patch version and build number, creates exactly one `release/v<version>` PR, waits for all four platform builds in parallel, merges only after the bundled candidate passes, publishes the already-built artifacts without a second build, and verifies the exact public release. It can be run from any working directory because it resolves the repository relative to the script. Use `--dry-run` for a mutation-free preflight or `--version <version> --build <number>` for explicit metadata. Rerun it on an existing release branch to resume an interrupted release; add `--retry-failed` to rerun failed jobs.

Executing this command is publication approval. Agents must still wait for an explicit user request before running it without `--dry-run`. A failed or incomplete platform build must never create a tag or GitHub Release. Do not manually create or push the version tag, and do not rebuild after merge.

The expected public release contains exactly these twelve assets:

```text
Resonance-macOS.zip
Resonance-macOS.zip.sha256
Resonance-Installer.pkg
latest-mac.json
Resonance-Setup-<version>.exe
Resonance-Setup-<version>.exe.blockmap
latest.yml
Resonance-Android-<version>.apk
Resonance-Android-<version>.apk.sha256
latest-android.json
Resonance-iOS-Simulator-<version>.zip
Resonance-iOS-Simulator-<version>.zip.sha256
```

Candidate workflow artifacts are retained for 14 days. If candidate packaging fails, rerun the candidate workflow before merging. If automatic publication misses the merged event, manually dispatch `publish-release.yml` with the exact tag, candidate SHA, and merge SHA. Never substitute a newer commit, a different run's artifacts, or a manually rebuilt binary. If publication fails after GitHub has created a draft or tag, inspect the remote state and ask the user before deleting, retagging, clobbering, or replacing anything. If the release is already public, diagnose first rather than modifying its assets.

Before merging or releasing, verify the checks for every platform changed. Do not create, merge, tag, push, publish, or make a GitHub Release unless the user explicitly requests it.

## Current worktree state

The canonical app checkout is `/Users/lilydietrich/Documents/Resonance`. Run `git status --short` there for the authoritative current list. Older app worktrees were retired after their unique changes were preserved as recovery patches. Recent work includes:

- Near-black cross-platform theme and refreshed desktop/mobile layouts.
- macOS server-library and storage page redesigns.
- iOS server-page action strip, filtering, transfer overlay, selection behavior, keyboard focus fixes, and full-screen player refinements.
- Android parity with the iOS theme, server layout, persistent frosted transfer overlay, selection count, refresh animation, storage screen, playlists, and fixed keyboard/mini-player behavior.
- Playlist synchronization, automatic syncing, ordered playback, shuffle/play-pause fixes, playlist deletion, track removal, and reordering.
- Windows installer/updater support and cross-platform release workflows.

Do not assume a screenshot complaint applies to only one list or one platform. The user often expects a reported pattern—scroll padding, overlays, focus behavior, metadata, playlist actions, or server layout—to be audited across all similar screens and then mirrored to the other clients when requested.

## Working style for future agents

1. Start from `/Users/lilydietrich/Documents/Resonance` and inspect its dirty state.
2. Read the relevant platform README and the owning model/state files before changing UI.
3. Diagnose against the real runtime path; do not fix screenshots with static mockups.
4. Preserve shared behavior even when each platform uses native UI conventions.
5. Do not expose tokens, admin keys, signing identities, or private music files.
6. Use bounded emulator/simulator commands and shut them down after validation.
7. Build and test every platform touched. Report exactly what was and was not run.
8. When changing server behavior, coordinate with `daz-pc` and validate the live public endpoint.
9. Do not silently create a PR or release. Wait for explicit authorization.
10. Prefer small focused changes over broad rewrites of the already-working playback and sync logic.
