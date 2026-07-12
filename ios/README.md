# Resonance for iOS

Native SwiftUI iPhone and iPad client with local audio import/playback, playlists, favorites, storage management, authenticated server sync, uploads, and deletion.

## Simulator preview

The `iOS Simulator Preview` GitHub Actions workflow builds the real Xcode project for the latest available iPhone simulator, installs and launches it with isolated preview data, captures a screenshot through `simctl`, and uploads both the screenshot and simulator `.app` as workflow artifacts.

The preview-only sample library is enabled with the process environment variable `RESONANCE_PREVIEW_DATA=1`; normal builds continue to load the real persisted library.
