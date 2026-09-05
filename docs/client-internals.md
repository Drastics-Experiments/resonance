# Client internals

Resonance keeps its existing native mobile screens and shared Electron renderer.
The clients continue to exchange the same server documents. These boundaries
keep collection work, persistence, and transfer cleanup independently testable
without changing the presentation layer.

## Desktop

- `windows/async-work.cjs` owns bounded asynchronous mapping and serialization of
  replacement snapshots. Library loading, metadata refresh, and storage scans
  use four workers per collection. Results retain input order; failed work waits
  for active workers before returning so callers can clean up safely.
- The library save writer retains one active snapshot and one pending snapshot.
  Snapshots are normalized and encoded before acceptance, so malformed input
  cannot discard an accepted save. New pending snapshots replace older pending
  values before disk I/O. All superseded callers wait for the replacement write, and a
  failed write rejects its callers without stranding subsequent saves. This is
  suitable for whole library snapshots, not individual edits or server requests.
- `createRendererModel` in `windows/ui/core.js` builds shared playlist lookup maps
  for a rendering operation.
  The ordered arrays remain authoritative. Duplicate identifiers preserve the
  first matching record, and server lookups remain scoped to the active profile.
  Mutable renderer state must not be hidden behind a cache that survives edits
  without invalidation.
- Playlist membership and search use lookup maps instead of scanning the entire
  track array for each playlist entry. Neither operation changes playlist order.
- History calculations share an index and resolved metadata within each render
  or sync batch. Local metadata matching still rejects ambiguous matches, and
  new calculations observe library edits and profile changes. Sidebar renders
  reuse playlist results without normalizing the entire saved state.
- Volume controls update playback immediately, then save once after 350 ms of
  inactivity or on a committed slider change. The existing close handshake saves
  the latest volume before acknowledging shutdown.
- Library rows, Storage, Add Songs, Music Server, Recently Added cards, and the full-player queue mount items near
  the viewport. Row blocks retain their measured heights when unloaded; focused
  rows and active playlist drags stay mounted. Hidden queue panels do no rendering.
  Server artwork loads as rows approach the viewport.
- `windows/metadata.cjs` deduplicates concurrent parses and caches unchanged file
  metadata with limits of 128 entries and 8 MiB of artwork strings. File identity,
  size, and modification/change timestamps invalidate cached results; failed
  reads are retried. This cache is process-local and changes no saved schema.
- Fetch readers release their locks on completion and failure. Download
  cancellation interrupts a waiting read, closes the destination, and removes
  partial output. Stream relays ignore late chunks after cancellation.

`main.cjs` continues to own Electron IPC and filesystem authorization. Renderer
selectors do not gain filesystem or credential access. Whole snapshot
coalescing does not apply to the revisioned server playlist protocol.

## Android

`LibraryMutationPolicy` owns pure bulk collection changes, while
`LibraryRepository` owns file operations and persistence. Deleting a selection
updates tracks, favorites, and playlists in one transformation. Frequent saves
normalize state without checking every media file; loading still reconciles file
availability. Completed writes flush the temporary file before replacement.
The persistence gate skips snapshots equal to the last successful write while
retaining the existing mutex cancellation and failure behavior.

`TrackIndexPolicy` provides first-match indexes for playlist and like hydration.
Remote indexes include the server and profile context before considering a song
identifier. Import cancellation propagates through batch operations, and
concurrent imports reserve distinct destination files.

## iOS

`MusicLibrary` invalidates derived collection data when tracks or the active
context change. Track indexes are rebuilt on demand so a batch of element edits
does not repeatedly rebuild the entire index. Queue and playlist resolution
preserve their ordered identifier lists.

Model policies handle duplicate legacy identifiers without trapping, and date
formatters are reused under a lock. The asynchronous serial gate advances a queue
cursor instead of shifting every waiting continuation on each release.
Artwork uses `NSCache` with entry and image-cost budgets so the system can evict
decoded images under memory pressure. Remote artwork is invalidated when the
server or profile changes.

## Validation

Run the shared desktop suite and the reproducible synthetic benchmark:

```sh
cd windows
pnpm install --frozen-lockfile
pnpm test
pnpm run benchmark:library
pnpm run package:win
```

The benchmark checks result equivalence before measuring a 10,000-track library.
It reports median selector timings and the number of writes for a burst of
1,001 save requests. These are diagnostics rather than CI timing thresholds or
measurements of end-to-end app startup.

`pnpm run benchmark:renderer 10000` runs the real Electron renderer with synthetic
downloaded songs, an isolated temporary profile, and a fixture IPC backend. It
blocks HTTP requests and never reads the user's library or account credentials.
The run records redraw and scrolling timings, captures a screenshot, and checks
offscreen access, search, likes, playback, keyboard reordering, focus, and queue
and Recently Added scrolling. It also checks Storage selection and menu cleanup,
plus Add Songs search, membership toggles, and keyboard focus. Server selection,
history rankings/day details, and volume saves (including shutdown) are checked
as well. Results and screenshots are written to the printed
temporary directory. A working graphical Electron runtime is required. These
measurements cover renderer behavior, not native file scanning or a real music
server; compare runs on the same machine and graphics configuration.

Run Android lint, unit tests, and the debug build with the Android SDK and JDK:

```sh
cd android
./gradlew --no-daemon lintDebug testDebugUnitTest assembleDebug
```

Use the repository's iOS test action on a Mac with Xcode, and
`mac/scripts/build-electron.sh` for the native macOS package. Platform builds and
visual checks remain necessary before release; portable Node tests cannot
validate UIKit, SwiftUI, Compose, signing, or native installer behavior.
