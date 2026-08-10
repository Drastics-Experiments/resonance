# Resonance for iPhone and iPad

Native SwiftUI client with local file import, AVFoundation playback, background audio, lock-screen controls, playlists, favorites, search, storage management, and authenticated offline server sync.

Open `Resonance.xcodeproj` in Xcode 16 or newer, select your Apple development team, and run on iOS 17 or newer. A physical device or Apple signing identity is required to create an installable `.ipa`; signing credentials are intentionally not included.

The default server is `https://resonance-core.blithe-haven-9710.chatgpt.site`. Clerk account sessions and synced songs are kept in the app's private Application Support directory; the credential file uses iOS file protection and user-only permissions.

Users upgrading from a build that did not use this private credential file must sign in once after updating.
