# Resonance macOS installer

Download `Resonance-Installer.pkg` from the latest GitHub release and open it.
That single installer downloads the newest verified Resonance build and installs
it into `/Applications` using the standard macOS Installer experience.

Tagged releases publish these macOS assets:

- `Resonance-Installer.pkg` — the only user-facing installation download
- `Resonance-macOS.zip` — app archive consumed by the installer and in-app updater
- `Resonance-macOS.zip.sha256` — archive checksum
- `latest-mac.json` — version, download URL, and archive SHA-256

The installer accepts only HTTPS release URLs from this repository, verifies the
archive checksum and application bundle identity, validates the code signature,
and replaces an existing installation atomically.

Release builds are ad-hoc signed unless Developer ID identities are supplied through `MACOS_APP_IDENTITY` and `MACOS_INSTALLER_IDENTITY`. Production releases should also set `NOTARY_PROFILE` so the package is notarized and stapled.
