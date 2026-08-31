# Resonance iPhone Installer

This is a separate Windows companion that installs the native Resonance iOS
app using the device owner's Apple Account and a free Personal Team profile.
It does not require a Mac on the user's computer and does not install AltStore.

## User requirements

- Windows 10 or newer (64-bit)
- Apple Mobile Device support (installed by Apple Devices or iTunes)
- An unlocked iPhone connected over USB and trusted by the PC
- Developer Mode enabled on iOS 16 or newer
- An Apple Account with two-factor authentication

Apple's free provisioning profile expires after seven days. Running the
installer again refreshes the installation. The same Apple Account should be
used for each refresh so the installed bundle identity stays stable.

## Security model

- Apple Account passwords are sent only through the local signing engine's
  encrypted Apple authentication exchange.
- Passwords and 2FA codes are never written to logs or sent to Resonance Core.
- Apple credentials, certificate material, and anisette state are kept only in
  memory and discarded when the installer closes. The installer does not use
  Keychain or Windows Credential Manager.
- The remote anisette service supplies Apple device-authentication headers; it
  does not receive the user's Apple password or 2FA code.

## Installation tracking

After a successful install, the webview stores a local metadata-only ledger
containing the iPhone name and UDID, Resonance release version, installation
time, and seven-day refresh deadline. One current record is retained per phone
and expired or soon-due installations are surfaced when the installer opens.
The ledger never contains Apple credentials, signing state, or an IPA.

## Release source

Every installation requests GitHub's latest public release and requires its
version-matched `Resonance-iOS-Device-<version>.ipa` and SHA-256 sidecar. The
installer has no bundled IPA, persistent download cache, local-file picker, or
fallback build. It downloads into a unique temporary directory, verifies both
the sidecar and GitHub asset digest, and deletes the download when the install
attempt ends.

The standard iOS release-candidate workflow builds both the Simulator archive
and unsigned arm64 device IPA. The centralized release workflows validate and
publish both iOS artifacts together with versioned Windows and macOS companion
installers, each with a SHA-256 sidecar. The reusable `iPhone Installer`
workflow packages those companions; it never embeds an app build.

For UI-only tests:

```powershell
node --test tests/*.test.mjs
```

For backend tests after installing Rust:

```powershell
cargo test --manifest-path src-tauri/Cargo.toml
```

## Third-party software

The signing backend uses `isideload`, pinned to a reviewed Git commit. See
`THIRD_PARTY_NOTICES.md` for license and attribution details.
