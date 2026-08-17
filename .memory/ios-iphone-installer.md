# Resonance iPhone installer

## Product decision

The free iPhone distribution path is a separate Windows-first companion under
`installers/windows/iphone-installer/`. It must not be folded into the Windows
music player. The companion builds around the MIT-licensed `isideload` engine,
uses the user's Apple Account locally, signs an unsigned device IPA, and
installs it over Apple's device connection.

## Important constraints

- The existing iOS release ZIP is Simulator-only and cannot be installed on an
  iPhone. Build an arm64 `iphoneos` IPA with signing disabled for later
  user-side signing.
- Free Personal Team profiles expire after seven days. The installer can
  refresh by signing and installing again, but it cannot remove Apple's limit.
- `isideload` appends the user's Apple Team ID to the source bundle identifier.
  Reinstalls by the same Apple Account preserve that installed identity; moving
  from an older differently signed build may require a one-time reinstall.
- Apple passwords and 2FA codes must never reach Resonance Core, logs, GitHub
  Actions, release artifacts, Keychain, or Windows Credential Manager. Apple
  authentication, anisette, and certificate state are memory-only.
- The installer depends on Apple Mobile Device support on Windows and requires
  real Windows/iPhone validation. macOS compilation is not runtime proof.
- Every install must query GitHub's latest public release and require the exact
  versioned device IPA and SHA-256 sidecar from that release. There is no
  bundled IPA, persistent cache, file picker, or local fallback.
- The public release contract is now fourteen assets: the previous twelve plus
  `Resonance-iOS-Device-<version>.ipa` and its SHA-256 sidecar. The local Release
  Studio project outside this worktree still has twelve-file wording and an
  expected-assets list that must be updated before it can publish this expanded
  contract.
- Successful installs are tracked locally by iPhone UDID. Keep one current
  metadata-only record per device with its display name, Resonance version,
  install time, and refresh deadline. This ledger must not contain Apple
  credentials, signing state, or downloaded app bytes.

## Upstream pins

- `isideload`: `0f4ffaf22212781810491156113f6160504880cc` on the
  `apple-codesign-quick` branch, MIT license.
- The implementation pattern was reviewed against `nab138/iloader`, MIT
  licensed. Preserve third-party notices when distributing the companion.
