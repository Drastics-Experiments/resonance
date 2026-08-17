# Video companion synchronization

- The audible audio player is always authoritative. Installed video uses a separate permanently muted companion player.
- Cross-platform parity requires a live controller driven by the authoritative playback clock, not only equivalent rate formulas or view-update callbacks.
- Normal drift is corrected with an exponential playback-rate multiplier and no seek. Hard seeks are reserved for opening alignment and real timeline discontinuities.
- macOS and iOS companion controllers must outlive transient full-player/mini-player or SwiftUI representable refreshes. Android must wait for and re-read the MediaController instead of permanently returning when it is initially unavailable.
- On macOS, begin initial alignment and muted playback in the video-open action, before mounting the full-screen view. A zero-tolerance seek that waits for completion before requesting playback creates visible lag behind the already-playing audio.
- Validate both the pure correction policy and the concrete native controller lifecycle on macOS, Windows, iOS, and Android.
