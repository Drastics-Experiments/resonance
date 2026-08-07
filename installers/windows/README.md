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

## Signing policy

Local builds and ordinary pull-request/main CI artifacts remain unsigned so they
can be produced without release credentials. They are development artifacts and
cannot be promoted by the release-candidate workflow.

A production candidate fails closed unless electron-builder signs both the app
executable and NSIS installer with the configured Authenticode certificate. The
Windows runner requires a trusted chain, the exact configured certificate
thumbprint, and a timestamp, then records hash-bound verification evidence. The
candidate bundler and publisher both require that evidence.

Configure these GitHub Actions repository secrets before starting a release. The
values themselves must never be committed:

- `RESONANCE_WINDOWS_CERTIFICATE_BASE64` — base64-encoded code-signing PFX
- `RESONANCE_WINDOWS_CERTIFICATE_PASSWORD` — password for that PFX
- `RESONANCE_WINDOWS_CERTIFICATE_SHA1` — expected signer-certificate thumbprint

This PFX path is only for an existing publicly trusted certificate whose issuer
and key-custody rules permit its private key to be exported and used on a
GitHub-hosted runner. Do not assume that a newly issued certificate can be
converted to PFX: current CA/Browser Forum requirements keep newly issued public
code-signing keys in qualifying hardware or cloud HSM custody. If Resonance uses
a hardware- or cloud-backed certificate (for example, Azure Artifact Signing),
select and review that provider integration before releasing; the current
workflow does not implement it. Never copy a non-exportable hardware-backed key
into a repository secret.
