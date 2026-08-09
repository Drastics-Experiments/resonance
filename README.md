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

## Git worktrees and development instances

This directory is the primary Git checkout. Additional agent checkouts should be
created with `git worktree`; each one remains attached to the same GitHub
repository while keeping its branch and working files independent.

The launch and test actions in `t3.json` are worktree-aware:

```text
Launch macOS Preview
Launch Windows Preview
Launch iOS Simulator
Launch Android Emulator
Test macOS
Test Windows
Test iOS
Test Android
Show Resonance Instance Names
```

Each action verifies that it runs at a Git worktree root, derives a stable
identity from that root's canonical path, and includes the readable directory
name plus the first 12 digits of the path's SHA-256 hash in every instance name.
The same worktree path always produces the same names and selectors; moving the
worktree deliberately gives it a new identity. Runtime paths, desktop bundle
IDs and state, mobile app IDs, simulator devices, Android emulator IDs, test
terminal titles, and test parent-process names are all scoped to that identity.
Parallel agents can therefore identify and control their own Resonance instance
without replacing or terminating another worktree's instance.

Run `Show Resonance Instance Names` from T3 to print the complete
credential-free selector registry. It is also written to the deterministic path
`/private/tmp/resonance-dev-launchers-<uid>/<worktree-id>/instances.json` and
contains the exact app or window-owner name, bundle/application ID, runtime path,
simulator or emulator name, and test process name for that worktree. Agents
should resolve targets through this registry instead of guessing a PID, dynamic
Simulator UUID, emulator serial, or generic `Electron` process.

`Test iOS` uses its own `Resonance iOS Tests <worktree-id>` Simulator, so a test
run cannot replace the normal `Launch iOS Simulator` Preview instance.

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

From a clean branch containing the latest committed app updates, one command runs the complete release. It resolves the repository from its own installed path, so it can be invoked from any working directory:

```bash
/path/to/Resonance/app/scripts/release-now.mjs
```

It automatically increments the patch version and build number, creates one `release/v<version>` PR from the current commit, waits for Android, iOS, macOS, and Windows to build in parallel, merges only after the complete candidate passes, publishes the already-built artifacts, and downloads the public release for final validation. Use explicit metadata when needed:

```bash
/path/to/Resonance/app/scripts/release-now.mjs --version 1.2.0 --build 20
```

Use `--dry-run` for a read-only preflight. If a network interruption or fixable Actions failure stops the command, rerun it from the existing release branch; add `--retry-failed` to rerun failed jobs. The command refuses a dirty tree and never stages arbitrary app changes.

Release PRs remain the publication approval boundary. Trusted `main` builds warm the Gradle, Swift, Xcode DerivedData, pnpm, and Electron packaging caches; release PRs restore those caches read-only. The candidate validator checks the complete asset set and provenance, while the publisher downloads the four validated platform artifacts directly instead of rebuilding or re-uploading a combined binary bundle. Do not manually push the version tag. Installed builds continue to use the GitHub Release update feeds.

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
