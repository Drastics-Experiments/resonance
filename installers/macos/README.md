# Resonance macOS installer

Tagged releases publish four macOS update assets:

- `Resonance-macOS.pkg` — standard `/Applications` installer
- `Resonance-macOS.pkg.sha256` — installer checksum
- `Resonance-macOS.zip` — app archive consumed by the in-app updater
- `latest-mac.json` — version, download URL, and archive SHA-256

To install the latest release from Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Drastics-Experiments/resonance/main/installers/macos/Install-Resonance.sh | bash
```

Release builds are ad-hoc signed unless Developer ID identities are supplied through `MACOS_APP_IDENTITY` and `MACOS_INSTALLER_IDENTITY`. Production releases should also set `NOTARY_PROFILE` so the package is notarized and stapled.
