# iOS provider playlist downloads

- iOS Import from Link now accepts Spotify, SoundCloud, and YouTube playlist kinds. YouTube playlist links are canonicalized to an allowlisted `https://www.youtube.com/playlist?list=...` URL before metadata resolution.
- YouTube metadata parsing supports `playlistVideoRenderer`, modern `lockupViewModel`, bounded continuation requests (500 playable videos, 10 pages), playlist-ID validation, unavailable-item diagnostics, and partial metadata when continuation loading stops. Unavailable rows remain visible but do not consume the playable-video cap or prevent later downloadable continuations from loading.
- YouTube playlist items use direct watch URLs and the existing sequential playlist importer, so each selected item keeps independent download failure/partial-success semantics. Playlist positions remain aligned with skipped rows.
- Every `LOCKUP_CONTENT_TYPE_VIDEO` source row consumes a playlist position, including malformed rows without a valid `contentId`; malformed rows become skipped diagnostics so later playable rows retain provider order.
- Playlist selection is keyed by the position-qualified `LocalImportPlaylistItem.id`, not provider `trackID`, so repeated occurrences can be toggled independently while download deduplication remains track-based.
- The unsigned generic-device app build and `build-for-testing` both pass, including compilation/linking of `MobileLocalImportTests.swift`. Runtime XCTest execution still needs an available iOS Simulator runtime or physical device.
