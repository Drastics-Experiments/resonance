# Resonance macOS installer

Download `Resonance-Installer.pkg` from the latest GitHub release and open it.
That single installer downloads the newest verified Resonance build and installs
it into `/Applications` using the standard macOS Installer experience.

The centralized release workflow publishes these macOS assets:

- `Resonance-Installer.pkg` — the only user-facing installation download
- `Resonance-macOS.zip` — app archive consumed by the installer and in-app updater
- `Resonance-macOS.zip.sha256` — archive checksum
- `latest-mac.json` — version, download URL, and archive SHA-256

The installer accepts only HTTPS release URLs from this repository, verifies the
archive checksum and application bundle identity, validates the code signature,
and replaces an existing installation atomically.

## Signing policy

Local builds and ordinary pull-request/main CI artifacts remain ad-hoc signed so
contributors can build without Apple credentials. They are development artifacts
and cannot be promoted by the release-candidate workflow. Their embedded
development updater policy allows in-app updates to another verified ad-hoc build
or to a valid production-signed build. Production installations never accept an
ad-hoc downgrade.

A production candidate fails closed unless the Electron app has a timestamped
Developer ID Application signature with hardened runtime, the PKG has a trusted
Developer ID Installer signature, and Apple notarization is stapled and validated
on both. The macOS Electron job records hash-bound verification evidence; the
candidate bundler and publisher both require that evidence.

Configure these GitHub Actions repository secrets before starting a release. The
values themselves must never be committed:

- `RESONANCE_MACOS_APP_CERTIFICATE_BASE64` — base64-encoded Developer ID Application P12
- `RESONANCE_MACOS_APP_CERTIFICATE_PASSWORD` — password for that P12
- `RESONANCE_MACOS_APP_IDENTITY` — full `Developer ID Application: ...` identity
- `RESONANCE_MACOS_INSTALLER_CERTIFICATE_BASE64` — base64-encoded Developer ID Installer P12
- `RESONANCE_MACOS_INSTALLER_CERTIFICATE_PASSWORD` — password for that P12
- `RESONANCE_MACOS_INSTALLER_IDENTITY` — full `Developer ID Installer: ...` identity
- `RESONANCE_MACOS_NOTARY_KEY_BASE64` — base64-encoded App Store Connect API `.p8` key
- `RESONANCE_MACOS_NOTARY_KEY_ID` — API key ID
- `RESONANCE_MACOS_NOTARY_ISSUER_ID` — API issuer ID

The local packaging command is run from `windows/` with Electron-builder:

```bash
pnpm install --frozen-lockfile
MAC_ARCH=universal APP_VERSION=1.0.1 BUILD_NUMBER=1 \
  bash ../mac/scripts/build-electron.sh
```
