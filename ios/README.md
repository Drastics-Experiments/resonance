# Resonance for iPhone and iPad

Native SwiftUI client with local file import, AVFoundation playback, background audio, lock-screen controls, playlists, favorites, search, storage management, and authenticated offline server sync.

Open `LikedSongsMobile.xcodeproj` in Xcode 16 or newer, select your Apple development team, and run on iOS 17 or newer. A physical device or Apple signing identity is required to create an installable `.ipa`; signing credentials are intentionally not included.

The default server is `https://music.unblocked.mov`. Client and admin keys are stored separately in the iOS Keychain, and synced songs are kept in the app's private Application Support directory.
