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

1. Increase `windows/package.json`'s version.
2. Commit and merge the change.
3. Push a matching tag such as `v1.1.0`.
4. The Windows workflow publishes `Resonance-Setup-1.1.0.exe`, its block map, and `latest.yml` to GitHub Releases.

The current installer is unsigned. Windows SmartScreen may display a warning until a code-signing certificate is configured in the release workflow.
