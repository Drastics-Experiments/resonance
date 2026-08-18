# Android provider playlist downloads

- Android already had Spotify and SoundCloud playlist metadata matching plus a shared sequential batch importer that catches download and upload failures per item. Keep the final `NO_AUDIO_MATCH` error only for playlists with zero matched candidates; per-track misses belong in `LinkImportPlaylist.skippedItems` or the batch failure summary.
- YouTube playlist URLs now resolve through `YouTubePlaylistParser`, which parses bounded `ytInitialData`/continuation payloads into direct video candidates and routes them through the same playlist importer. The parser caps metadata at 500 rows and 10 continuation pages, validates provider hosts and playlist IDs, and marks malformed/unplayable rows unavailable.
- Full verification passed with `JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home" ANDROID_HOME="/Users/lilydietrich/Library/Android/sdk" ./gradlew --no-daemon lintDebug testDebugUnitTest assembleDebug`.
