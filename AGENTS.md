# Resonance project guide

This file is the working context for agents modifying Resonance. Read it before making changes. It records the current source locations, platform architecture, shared product behavior, build commands, deployment expectations, and infrastructure boundaries as of 2026-08-04. do not edit the main resonance file, only edit the project directory or worktrees.

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
- GitHub releases: <https://github.com/Drastics-Experiments/resonance/releases>
- Public music-server base URL: <https://resonance-core.blithe-haven-9710.chatgpt.site>

The public domain provides access to the user's self-hosted music server. It is not intended to become third-party song storage.

## Infrastructure boundary

The production music server runs on a ChatGPT site. Do not start a second production server on the local Mac. The source code for the server is accessible via the ChatGPT Sites workflow. Do not make changes to clients without also ensuring the server supports those changes.

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

Some internal target and source names still say `LikedSongsMobile`, `LikedSongsFocus`, or `LikedSongsFocusApp`. These are legacy implementation names. The user-facing product is **Resonance**. Do not casually rename internal targets, bundle identifiers, or storage directories because installed apps depend on those identities for upgrades and data preservation.

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

Before changing an endpoint shape, update and test every client and coordinate the server deployment on the ChatGPT Site.


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
