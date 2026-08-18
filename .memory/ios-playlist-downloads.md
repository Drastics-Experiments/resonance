# iOS provider playlist downloads

- iOS Import from Link now accepts Spotify, SoundCloud, and YouTube playlist kinds. YouTube playlist links are canonicalized to an allowlisted `https://www.youtube.com/playlist?list=...` URL before metadata resolution.
- YouTube metadata parsing supports `playlistVideoRenderer`, modern `lockupViewModel`, bounded continuation requests (500 combined available/skipped rows, 10 pages), playlist-ID validation, unavailable-item diagnostics, and partial metadata when continuation loading stops.
- YouTube playlist items use direct watch URLs and the existing sequential playlist importer, so each selected item keeps independent download failure/partial-success semantics. Playlist positions remain aligned with skipped rows.
- The unsigned generic-device app build and `build-for-testing` both pass, including compilation/linking of `MobileLocalImportTests.swift`. Runtime XCTest execution still needs an available iOS Simulator runtime or physical device.
