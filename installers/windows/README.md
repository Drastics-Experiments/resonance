# Windows installer

The Windows installer is built with electron-builder and NSIS.

## Local build

From `windows/`:

```powershell
pnpm install --frozen-lockfile
pnpm run installer:win
```

Generated artifacts are placed in `installers/windows/dist/` and are intentionally ignored by Git.

The installer is per-user, supports choosing an installation directory, and creates Start Menu and Desktop shortcuts. Application data remains under Electron's per-user application-data directory and is not removed during upgrades.

After the first installation, Resonance checks and downloads updates inside the app. Choosing **Restart & update** runs the verified NSIS update silently against the existing installation and relaunches Resonance; it does not show the setup wizard or ask the user to choose an installation directory again.

## Download or install the latest release

`Install-Resonance.ps1` downloads the latest published installer from GitHub Releases and verifies its SHA-512 value against electron-builder's `latest.yml` manifest before running it.

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Resonance.ps1
```

Save a verified installer without running it:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-Resonance.ps1 -DownloadOnly
```

Use `-Silent` for an unattended per-user installation.

## Publishing an update

1. Create a release branch named `release/v<version>` from current `main`.
2. Run `node scripts/release-version.mjs --set <version> <build>` from the repository root.
3. Open the release PR and wait for the centralized `Bundle release candidate` job, including the Windows tests and NSIS build.
4. Merge the release PR. The single publish workflow attaches `Resonance-Setup-<version>.exe`, its block map, and `latest.yml` alongside the other platform assets. Do not push a version tag manually.

The current installer is unsigned. Windows SmartScreen may display a warning until a code-signing certificate is configured in the release workflow.
