# Windows playlist link downloads

- `windows/local-import-core.cjs` parses Spotify and YouTube playlist metadata; `windows/local-soundcloud.cjs` parses SoundCloud playlist hydration. The Windows UI resolves a playlist into selectable candidates, then `confirmPlaylistImport` downloads each selected item sequentially and preserves a partially imported playlist after failures or cancellation.
- Spotify playlist embeds are bounded to 500 items and expose `truncated`; Spotify per-item source lookup keeps up to two ordered fallback candidates so one failed YouTube match does not discard the item.
- Spotify playlist embeds filter unavailable/malformed provider rows before applying the 500-playable-item cap, so skipped rows do not hide later playable tracks or incorrectly produce an empty playlist.
- SoundCloud direct renditions remain auto-selectable; YouTube metadata-only fallbacks must stay review-required and are never auto-selected. The complete Windows suite passed with 252 tests after installing the locked dependencies.
- YouTube playlist parsing carries a monotonic source-row position cursor across continuation pages. Legacy and modern lockup rows, including unavailable rows, advance the cursor; explicit indices are normalized against it so page-local fallback numbering cannot restart or move backward.
