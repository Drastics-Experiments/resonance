# Mobile UX simplification

This pass makes the iOS and Android apps feel like the same product while keeping each implementation native. It changes presentation and navigation only; playback, imports, storage behavior, account state, and server synchronization keep their existing contracts.

## Design principles

1. **Three primary destinations.** Library, Playlists, and Server stay in bottom navigation. Storage is a Library utility, opened from the drive button in the Library header.
2. **Search before browsing.** Library search appears directly under the title, ahead of playback controls and Recently Added.
3. **One clear hierarchy.** Screen titles describe the destination; redundant product-name and section eyebrow labels are removed.
4. **Mobile lists, not desktop tables.** Library, playlist, picker, and server lists no longer show column-heading rows. Each song row remains self-contained and accessible.
5. **Progressive disclosure for server tools.** Download and Select stay visible. Upload variants and connection settings move into one overflow menu. Refresh moves to the Server header and pull-to-refresh remains available.
6. **Compact utility screens.** Storage uses a single used/available progress summary instead of a large multi-metric ring, with import and edit actions in overflow.
7. **Cross-platform parity.** Labels, information order, navigation depth, and action priority match on iOS and Android; controls retain native SwiftUI and Material behavior.

## Implemented screen changes

### Library

- Replaced the redundant “Music Library / Resonance” stack with “Library” and a device-song count.
- Added a visible Storage shortcut beside the profile control.
- Moved search above playback and discovery content.
- Replaced the table header with a simple “All Songs” label and result count.

### Playlists

- Replaced “Your Collections” with a quiet collection count.
- Removed table headings from playlist details and the add-songs picker.
- Kept creation, deletion, reordering, and playback behavior unchanged.

### Server

- Shortened the title to “Server” and moved refresh into the header.
- Collapsed three illustrated metrics into one summary sentence.
- Reduced the visible action strip to Download, Select, and More.
- Moved upload variants and account/connection settings into More.
- Removed the always-visible transfer-mode strip; those settings remain in Account & Connection.
- Removed the song-table heading while retaining search, filter, sort, selection, pull-to-refresh, and transfer feedback.

### Storage

- Moved Storage out of bottom navigation and added an explicit back affordance.
- Shortened the title from “Song Storage” to “Storage.”
- Moved Import and Select Songs into one overflow menu.
- Replaced the ring chart and three narrow columns with a compact usage bar, used/available values, and local/downloaded counts.
- Kept search, sorting, scopes, batch selection, import, and deletion behavior unchanged.

## Visual reference

The implementation direction was generated with the built-in ImageGen workflow and saved as [mobile-ux-simplification-concept.png](design/mobile-ux-simplification-concept.png).

Prompt summary: a high-fidelity four-screen Resonance mobile concept board with a nearly black theme, violet accents, three primary tabs, Library-first Storage access, immediate search, simplified list hierarchy, compact server actions, and a compact Storage usage summary.
