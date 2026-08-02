import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  applyRemotePlaylistDocument,
  createEmptyState,
  filterPlaylists,
  filterTracks,
  formatHistoryWindowLabel,
  formatTime,
  mergeListeningHistory,
  mergePlaylistDocument,
  mergeSyncedTracks,
  nextIndex,
  niceChartMaximum,
  normalizedVolume,
  normalizeState,
  resolveSyncProfile,
  summarizeListeningHistory,
  summarizeListeningStats,
  tracksForPlaylist,
  updatePlaylistRemoteSongIDs,
} from "../ui/core.js";
import metadata from "../metadata.cjs";
import updaterFeed from "../updater-feed.cjs";

const { conciseUpdaterError, resolveWindowsUpdateFeed } = updaterFeed;

test("keeps contextual search and sorting in the persistent top bar", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const preloadSource = readFileSync(new URL("../preload.cjs", import.meta.url), "utf8");
  assert.match(htmlSource, /id="searchSort"/);
  assert.match(htmlSource, /id="searchSortMenu"[\s\S]+role="listbox"/);
  assert.doesNotMatch(htmlSource, /<select id="searchSort"/);
  assert.doesNotMatch(appSource, /id="(?:storageSearch|serverSearch)"/);
  assert.match(appSource, /section === "storage"[\s\S]+updateSearchSort\([\s\S]+storageSort/);
  assert.match(appSource, /section === "server"[\s\S]+updateSearchSort\([\s\S]+serverSort/);
  assert.match(appSource, /class="server-status-line"/);
  assert.match(appSource, /class="server-library-bar"/);
  assert.match(appSource, /class="server-table-head/);
  assert.doesNotMatch(appSource, /class="server-sync-detail"/);
  assert.match(appSource, /class="server-selection-icon"/);
  assert.match(appSource, /class="server-playlist-sync-icon"/);
  assert.match(htmlSource, /id="serverTransferToast"/);
  assert.match(htmlSource, /id="dismissServerTransfer"/);
  assert.doesNotMatch(htmlSource, /img-src[^"]*https:/);
  assert.doesNotMatch(appSource, /<div id="serverTransferToast"/);
  assert.match(appSource, /function hideServerTransfer\(owner = null\)/);
  assert.match(appSource, /#dismissServerTransfer"\)\.onclick = cancelServerTransfer/);
  assert.match(preloadSource, /cancelServerTransfer:[\s\S]+server:cancel-transfer/);
  assert.match(preloadSource, /fetchServerArtwork:[\s\S]+server:artwork/);
  assert.match(mainSource, /ipcMain\.handle\("server:artwork"/);
  assert.match(mainSource, /responseBytesWithLimit\(response, MAX_SERVER_ARTWORK_BYTES\)/);
  assert.match(appSource, /hydrateServerCatalogArtwork\(serverCatalog\)/);
  assert.match(mainSource, /new AbortController\(\)/);
  assert.match(mainSource, /server:cancel-transfer/);
  assert.match(mainSource, /signal\.throwIfAborted\(\)/);
  assert.doesNotMatch(appSource, /class="connection-card"/);
  assert.match(appSource, /class="now-playing-icon"/);
  assert.doesNotMatch(appSource, /[Ⅱ▥]/);
  assert.match(mainSource, /autoUpdater\.logger\s*=\s*null/);
  assert.match(mainSource, /protectDetachedOutput\(process\.stdout\)/);
  assert.match(mainSource, /protectDetachedOutput\(process\.stderr\)/);
  assert.match(mainSource, /error\?\.code === "EPIPE" \|\| error\?\.code === "EIO"/);
  assert.match(mainSource, /contentType\.includes\("html"\)/);
  assert.match(mainSource, /configured server URL is not serving this Resonance API route/);
});

test("avoids macOS Keychain access in the source Electron preview", () => {
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  assert.doesNotMatch(mainSource, /\{ app, BrowserWindow, dialog, ipcMain, safeStorage, shell \}/);
  assert.match(mainSource, /function usesSessionOnlyCredentialStore\(\)[\s\S]+process\.platform === "darwin" && !app\.isPackaged/);
  assert.match(mainSource, /server:credentials:load[\s\S]+usesSessionOnlyCredentialStore\(\)[\s\S]+sessionServerCredentials/);
  assert.match(mainSource, /server:credentials:save[\s\S]+usesSessionOnlyCredentialStore\(\)[\s\S]+sessionServerCredentials = credentialsValue/);
  assert.match(mainSource, /function encryptedCredentialStorage\(\)[\s\S]+require\("electron"\)\.safeStorage/);
});

test("switches to existing server profiles or falls back to Default", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.match(htmlSource, /id="profileSwitchDialog"/);
  assert.match(htmlSource, /for="profileSwitchQuery">Profile name or ID/);
  assert.match(appSource, /api\.fetchProfiles\(\{ baseURL: state\.serverURL, token: serverToken \}\)/);
  assert.match(appSource, /resolveSyncProfile\(state\.syncProfiles, query, response\.default_profile_id\)/);
  assert.match(appSource, /fellBackToDefault[\s\S]+Switched to/);
  assert.match(appSource, /track\.id === currentID \? toggle\(\) : play\(track, tracks, \{ playlistID: null \}\)/);
  assert.match(appSource, /function updateProfileControl\(\)[\s\S]+control\.hidden = false/);
  assert.match(appSource, /function renderSettings\(\)[\s\S]+Under construction/);
  assert.match(appSource, /#profileSettings"\)\.onclick = \(\) =>[\s\S]+navigate\("settings"\)/);
  assert.doesNotMatch(appSource, /#profileSettings"\)\.onclick = [\s\S]{0,160}openServerSettings/);
  assert.match(styleSource, /\.settings-placeholder-card\s*\{/);
});

test("opens a profile-menu clip editor scaffold without claiming export support", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.match(htmlSource, /id="profileClipEditor"[\s\S]+Clip Editor[\s\S]+Preview/);
  assert.match(htmlSource, /id="clipEditorDialog"[\s\S]+id="clipEditorTrack"[\s\S]+id="clipEditorStartInput"[^>]+type="text"[\s\S]+id="clipEditorEndInput"[^>]+type="text"/);
  assert.match(htmlSource, /id="clipEditorStartHandle"[^>]+role="slider"[\s\S]+id="clipEditorEndHandle"[^>]+role="slider"/);
  assert.doesNotMatch(htmlSource, /id="clipEditor(?:Start|End)" type="range"/);
  assert.match(htmlSource, /id="exportClip"[^>]+disabled/);
  assert.match(appSource, /function openClipEditor\(\)[\s\S]+clipEditorDialog[\s\S]+showModal\(\)/);
  assert.match(appSource, /#profileClipEditor"\)\.onclick = openClipEditor/);
  assert.match(appSource, /function updateClipEditorRange\(\)/);
  assert.match(appSource, /function parseClipEditorTime\(value\)/);
  assert.match(appSource, /function setClipEditorBoundary\(boundary, seconds\)/);
  assert.match(appSource, /handle\.setPointerCapture\(event\.pointerId\)/);
  assert.match(appSource, /event\.preventDefault\(\);[\s\S]+handle\.focus\(\);[\s\S]+handle\.setPointerCapture/);
  assert.match(appSource, /waveform\.getBoundingClientRect\(\)/);
  assert.doesNotMatch(styleSource, /\.clip-editor-ranges\s*\{/);
  assert.match(appSource, /Array\.from\(\{ length: 112 \}/);
  assert.match(appSource, /const defaultStart = duration > 60 \? 15 : 0/);
  assert.match(appSource, /defaultStart \+ 45/);
  assert.match(appSource, /bar\.classList\.toggle\("selected"/);
  assert.doesNotMatch(appSource, /clip-wave-height/);
  assert.match(htmlSource, /clip-editor-handle-start[›\s\S]+clip-editor-handle-end[‹\s\S]+/);
  assert.match(styleSource, /\.clip-editor-dialog\s*\{/);
  assert.match(styleSource, /\.clip-editor-waveform\s*\{/);
  assert.match(styleSource, /\.clip-editor-wave-bars i\.selected\s*\{/);
});

test("resolves a missing requested profile to the server-declared Default", () => {
  const profiles = [
    { id: "default", name: "Default", is_default: true },
    { id: "drastic-id", name: "Drastic", is_default: false },
  ];
  assert.deepEqual(resolveSyncProfile(profiles, "DRASTIC", "default"), {
    profile: profiles[1],
    fellBackToDefault: false,
  });
  assert.deepEqual(resolveSyncProfile(profiles, "missing-profile", "default"), {
    profile: profiles[0],
    fellBackToDefault: true,
  });
  assert.deepEqual(resolveSyncProfile([], "missing-profile", "default"), {
    profile: null,
    fellBackToDefault: false,
  });
});

test("fetches the profile directory without a selected-profile header", () => {
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  assert.match(mainSource, /function authorizationHeaders\(token\)/);
  assert.match(mainSource, /ipcMain\.handle\("server:profiles:get"[\s\S]+headers: authorizationHeaders\(token\)/);
});

test("keeps playlist heroes while the root Library starts with compact filter pills", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.match(appSource, /const collectionHeader = selectedPlaylistID[\s\S]+class="hero"[\s\S]+: libraryFilters/);
  assert.match(appSource, /collection-scroll">\$\{collectionHeader\}[\s\S]+recently-added/);
  assert.match(appSource, /\$\{selectedPlaylistID \? libraryFilters : ""\}/);
  assert.match(appSource, /const recentTracks = !selectedPlaylistID \? filterTracks\(tracks, "", "recent"\) : \[\]/);
  assert.match(styleSource, /\.recent-track-list\s*\{[\s\S]*?grid-auto-flow: column/);
  assert.match(styleSource, /\.recent-track-list\s*\{[\s\S]*?grid-auto-columns: minmax\(128px, calc\(\(100% - 90px\) \/ 6\)\)/);
  assert.match(styleSource, /\.recent-track-list\s*\{[\s\S]*?overflow-x: auto/);
  assert.doesNotMatch(styleSource, /\.recent-track-list\s*\{[\s\S]*?grid-template-columns: repeat\(6/);
  assert.match(appSource, /let recentlyAddedScrollLeft = 0/);
  assert.match(appSource, /const previousRecentTrackList = document\.querySelector\("\.recent-track-list"\)[\s\S]+recentlyAddedScrollLeft = previousRecentTrackList\.scrollLeft/);
  assert.match(appSource, /const recentTrackList = document\.querySelector\("\.recent-track-list"\)[\s\S]+recentTrackList\.scrollLeft = recentlyAddedScrollLeft[\s\S]+recentTrackList\.onscroll/);
  assert.doesNotMatch(appSource, /const showRecentlyAdded/);
  assert.doesNotMatch(appSource, /class="library-heading"/);
  assert.match(appSource, /if \(\$\("#playCollection"\)\)/);
  assert.match(appSource, /class="playlist-action-cluster"[\s\S]+id="heroShuffle"[\s\S]+id="heroAdd"/);
  assert.match(appSource, /class="playlist-more"[\s\S]+class="playlist-menu"/);
  assert.match(appSource, /data-hero-import[\s\S]+data-hero-next[\s\S]+data-hero-sync[\s\S]+data-hero-delete/);
  assert.match(appSource, /function openAddSongsDialog\(playlist\)/);
  assert.match(htmlSource, /id="addSongsDialog"[\s\S]+id="addSongsSearch"[\s\S]+id="addSongsList"/);
  assert.match(styleSource, /\.playlist-action-cluster\s*\{/);
  assert.match(styleSource, /\.playlist-menu\s*\{/);
  assert.match(styleSource, /\.add-songs-dialog\s*\{/);
  assert.match(styleSource, /\.filters\.library-top-filters button\s*\{[\s\S]*?font-size: 10px/);
  assert.match(styleSource, /\.library-top-filters \+ \.recently-added\s*\{[\s\S]*?border-top: 0/);
});

test("uses the macOS-inspired ambient, artwork, and action gradients", () => {
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.match(styleSource, /--gradient-accent: linear-gradient\(135deg, #536bff 0%, #7547ff 50%, #8a42eb 100%\)/);
  assert.match(styleSource, /--gradient-artwork: linear-gradient\(145deg, #3349c9 0%, #6857ff 52%, #f18cb2 100%\)/);
  assert.match(styleSource, /--gradient-ambient:[\s\S]*?radial-gradient\(circle at 74% 4%, #6540f524[\s\S]*?linear-gradient\(180deg, #080910ad, #020305 76%\)/);
  assert.match(styleSource, /\.hero\s*\{[\s\S]*?radial-gradient\(circle at 12% 20%, #6540f533[\s\S]*?linear-gradient\(90deg, #08090e, #09080f, #07070b\)/);
  assert.match(styleSource, /\.hero-art\s*\{[\s\S]*?var\(--gradient-artwork\)/);
  assert.match(styleSource, /\.primary\s*\{[\s\S]*?background: var\(--gradient-accent\)/);
  assert.match(styleSource, /\.playerbar\s*\{[\s\S]*?linear-gradient\(180deg, #080910f7, #040509fc\)/);
});

test("keeps playlist row controls and supports animated drag reordering", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.match(appSource, /data-playlist-draggable="true"/);
  assert.match(appSource, /trackTable\.ondrop\s*=\s*async/);
  assert.match(appSource, /row\.ondragstart\s*=/);
  assert.match(appSource, /drag-preview-up/);
  assert.match(appSource, /data-reorder-track="-1"/);
  assert.match(appSource, /data-reorder-track="1"/);
  assert.match(appSource, /data-remove-playlist-track/);
  assert.match(appSource, /row\.oncontextmenu\s*=\s*\(event\) => openTrackContextMenu/);
  assert.match(appSource, /data-context-remove-playlist-track/);
  assert.match(appSource, /ADD TO ANOTHER PLAYLIST/);
  assert.match(appSource, /No other playlists yet/);
  assert.match(appSource, /activePlaybackPlaylistID === activePlaylist\.id/);
  assert.doesNotMatch(appSource, /data-playlist-sync-status/);
  assert.doesNotMatch(appSource, /Synced \$\{(?:remoteDocument|result\.document)\.playlists\.length/);
  assert.match(styleSource, /\.track-row\.playlist-draggable\s*\{/);
  assert.match(styleSource, /\.track-row\.playlist-drag-floating\s*\{/);
  assert.match(styleSource, /\.track-context-menu\s*\{/);
  assert.match(styleSource, /\.track-context-menu \.context-danger/);
});

test("ports playback reliability, recovery notices, and keyboard operation into the current UI", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.match(appSource, /function activePlaybackTracks\(\)/);
  assert.match(appSource, /state\.playbackQueueIDs = \[\.\.\.activePlaybackQueueIDs\]/);
  assert.match(appSource, /function previous\(\)[\s\S]+audio\.currentTime > 3[\s\S]+recordHistory: false/);
  assert.match(appSource, /pendingRestorePosition[\s\S]+audio\.currentTime = Math\.min/);
  assert.match(appSource, /audio\.volume = normalizedVolume\(state\.volume\)/);
  assert.match(appSource, /function showNotice\(message, kind = "error"\)/);
  assert.match(appSource, /function friendlyIPCError\(error, fallback\)/);
  assert.match(appSource, /replace\(\/\^Error invoking remote method/);
  assert.match(appSource, /const deleted = \[\];[\s\S]+const failed = \[\];[\s\S]+The files remain in your library/);
  assert.match(appSource, /Alt\+Up or Alt\+Down/);
  assert.match(appSource, /row\.onkeydown = async[\s\S]+CSS\.escape\(trackID\)/);
  assert.match(appSource, /menu\.onkeydown = \(keyEvent\)[\s\S]+ArrowDown[\s\S]+Home[\s\S]+End/);
  assert.match(mainSource, /\.corrupt-\$\{Date\.now\(\)\}/);
  assert.match(mainSource, /playbackQueueIDs:[\s\S]+playbackPlaylistID:/);
  assert.match(htmlSource, /id="appNotice"[^>]+aria-live="polite"/);
  assert.match(htmlSource, /id="seek"[^>]+aria-label="Playback position"/);
  assert.match(htmlSource, /id="volume"[^>]+aria-label="Volume"/);
  assert.match(styleSource, /button:focus-visible,[\s\S]+\[tabindex\]:focus-visible/);
  assert.match(styleSource, /\.app-notice\s*\{/);
  assert.match(htmlSource, /id="profileHistory"/);
  assert.match(appSource, /function bindListeningHistoryChartInteractions/);
});

test("animates server artwork placeholders until each image loads", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.match(appSource, /artwork\(song, \{ animateLoading: true \}\)/);
  assert.match(appSource, /function updateServerArtworkNode\(song\)/);
  assert.match(appSource, /data-server-artwork-id/);
  assert.doesNotMatch(appSource, /scheduleServerArtworkRender/);
  assert.match(appSource, /function bindServerArtworkLoadStates\(\)/);
  assert.match(appSource, /image\.addEventListener\("load", reveal/);
  assert.match(styleSource, /@keyframes server-artwork-shimmer/);
  assert.match(styleSource, /@keyframes server-artwork-pulse/);
  assert.match(styleSource, /\.server-artwork-loading\.failed::before/);
  assert.match(styleSource, /@media \(prefers-reduced-motion: reduce\)/);
});

test("keeps link import local-first with explicit candidate confirmation and optional profile upload", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const debridSource = readFileSync(new URL("../local-debrid.cjs", import.meta.url), "utf8");
  const preloadSource = readFileSync(new URL("../preload.cjs", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  const packageSource = readFileSync(new URL("../package.json", import.meta.url), "utf8");

  assert.match(mainSource, /RESONANCE_LOCAL_DEVICE_IMPORT === "1" \|\| !app\.isPackaged/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:resolve"/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:artwork"/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:start"/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:start-external"/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:cancel"/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:upload"/);
  assert.match(mainSource, /destinationDirectory: paths\.local/);
  assert.match(mainSource, /Only a song already saved in the local Resonance library can be uploaded/);
  assert.match(mainSource, /profileHeaders\(String\(adminToken\), profileID\)/);
  assert.match(mainSource, /cleanupLocalImportTemporaryFiles[\s\S]+startsWith\("resonance-local-import-"\)/);
  assert.match(preloadSource, /resolveLocalImport:[\s\S]+local-import:resolve/);
  assert.match(preloadSource, /fetchLocalImportArtwork:[\s\S]+local-import:artwork/);
  assert.match(preloadSource, /startLocalImport:[\s\S]+local-import:start/);
  assert.match(preloadSource, /startExternalImport:[\s\S]+local-import:start-external/);
  assert.match(preloadSource, /cancelLocalImport:[\s\S]+local-import:cancel/);
  assert.match(preloadSource, /uploadLocalImport:[\s\S]+local-import:upload/);
  assert.match(preloadSource, /onLocalImportProgress:[\s\S]+local-import:progress/);
  assert.match(htmlSource, /id="localImportDialog"/);
  assert.match(htmlSource, /id="localImportTitle">Import from link/);
  assert.doesNotMatch(htmlSource, /Spotify tracks are matched against/);
  assert.match(htmlSource, /id="localImportStage"[^>]*hidden/);
  assert.doesNotMatch(htmlSource, /Choose a source|Confirm the match before/);
  assert.doesNotMatch(styleSource, /\.local-import-stage/);
  assert.match(htmlSource, /id="localImportSource"/);
  assert.doesNotMatch(htmlSource, /id="resolveLocalImport"|>Find (?:audio|video)</);
  assert.match(htmlSource, /id="localImportMediaKind"[\s\S]+value="audio"[\s\S]+value="video"/);
  assert.match(htmlSource, /<header>[\s\S]+id="localImportMediaKind"[\s\S]+id="closeLocalImport"[\s\S]+<\/header>/);
  assert.doesNotMatch(htmlSource, /MP4 with audio/);
  assert.match(htmlSource, /id="localImportCandidates"/);
  assert.match(htmlSource, /id="localImportPreview"/);
  assert.match(htmlSource, /id="localImportSync"/);
  assert.match(htmlSource, /<footer>[\s\S]+id="localImportSyncRow"[\s\S]+Upload to server/);
  assert.match(appSource, /sync\.checked = true/);
  assert.match(appSource, /sync\.disabled = serverBacked/);
  assert.doesNotMatch(appSource, /sync\.disabled = serverBacked \|\| !canSync/);
  assert.doesNotMatch(htmlSource, /localImportSyncTitle|localImportSyncHelp|Upload after saving locally/);
  assert.match(htmlSource, /id="chooseLocalFiles"[^>]+aria-label="Choose files"[\s\S]+<svg/);
  assert.match(htmlSource, /id="confirmLocalImport"[^>]+aria-label="Download audio"[\s\S]+<svg/);
  assert.doesNotMatch(htmlSource, /Choose files instead|>Import selected</);
  assert.match(htmlSource, /connect-src 'none'/);
  assert.match(appSource, /function resolveLinkImport\(\)/);
  assert.match(appSource, /const LOCAL_IMPORT_AUTO_RESOLVE_DELAY = 450/);
  assert.match(appSource, /function localImportSourceIsReady\(value\)/);
  assert.match(appSource, /function scheduleLocalImportResolution/);
  assert.match(appSource, /\$\("#localImportSource"\)\.oninput = \(\) => \{[\s\S]+scheduleLocalImportResolution\(\)/);
  assert.doesNotMatch(appSource, /\$\("#resolveLocalImport"\)/);
  assert.match(styleSource, /\.local-import-source\.searching \.local-import-source-spinner/);
  assert.match(appSource, /renderLocalImportArtwork\(track, candidates, mediaKind\)/);
  assert.match(appSource, /candidates\.length > 1/);
  assert.match(appSource, /data-local-import-preview/);
  assert.match(appSource, /function toggleLocalImportPreview\(index\)/);
  assert.match(appSource, /localImportPreviewAudio\.ontimeupdate/);
  assert.match(appSource, /api\.previewLocalImport\(candidate\.sourceURL\)/);
  assert.match(preloadSource, /previewLocalImport: \(sourceURL\) => ipcRenderer\.invoke\("local-import:preview"/);
  assert.match(preloadSource, /cancelLocalImportPreview: \(\) => ipcRenderer\.invoke\("local-import:preview:cancel"\)/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:preview"/);
  assert.match(mainSource, /resolveYouTubeAudio\(source, controller\.signal\)/);
  assert.match(mainSource, /downloadResolvedAudio\(resolved, filePath, controller\.signal\)/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:preview:cancel"/);
  assert.match(appSource, /\$\("#localImportStage"\)\.dataset\.stage = value\.stage \|\| "idle"/);
  assert.doesNotMatch(appSource, /node\.hidden = stage === "idle"/);
  assert.match(appSource, /function confirmLinkImport\(\)/);
  assert.match(appSource, /updateLocalImportTransfer\(\{ stage: "inspecting_source" \}\);[\s\S]+\$\("#localImportDialog"\)\.close\(\)/);
  assert.match(appSource, /localImportKeepStateOnClose = true;[\s\S]+\$\("#localImportDialog"\)\.close\(\)/);
  assert.match(appSource, /addEventListener\("close", \(\) => \{[\s\S]+if \(localImportKeepStateOnClose\)/);
  assert.match(appSource, /function updateLocalImportTransfer\(value = \{\}\)/);
  assert.match(appSource, /owner: "local-import"/);
  assert.match(appSource, /owner === "local-import"\) await api\.cancelLocalImport\(\)/);
  assert.match(appSource, /api\.onLocalImportProgress\(\(value\) => \{[\s\S]+updateLocalImportTransfer\(value\)/);
  assert.match(appSource, /sourceURL: candidate\.sourceURL/);
  assert.match(appSource, /state\.tracks\.push\(importedTrack\)[\s\S]+await persist\(\)/);
  assert.match(appSource, /if \(!response\.result\.serverBacked && \$\("#localImportSync"\)\.checked[\s\S]+api\.uploadLocalImport/);
  assert.doesNotMatch(appSource, /A failed upload will not remove or alter the local media file/);
  assert.match(appSource, /mediaKind: localImportResolution\.mediaKind|mediaKind,/);
  assert.match(mainSource, /outputFormats: \{ audio: "m4a", video: "mp4" \}/);
  assert.match(mainSource, /mediaKind: value\.mediaKind/);
  assert.match(mainSource, /body\.on\("data", \(chunk\) => \{[\s\S]+publishUploadProgress\(\)/);
  assert.match(mainSource, /currentFile: filename,[\s\S]+completed,[\s\S]+total: information\.size/);
  assert.match(appSource, /sourceProvider === "debrid_vault"[\s\S]+return "Debrid Vault"/);
  assert.match(appSource, /api\.startExternalImport\(/);
  assert.match(appSource, /response\.result\.kind === "selection_required"/);
  assert.match(mainSource, /searchFileBackedSources\(track, \{ baseURL, adminToken, profileID \}, signal\)/);
  assert.match(debridSource, /api\/v1\/admin\/debrid\/resolve/);
  assert.match(debridSource, /api\/v1\/admin\/debrid\/import/);
  assert.match(debridSource, /temporary_download_url/);
  assert.match(debridSource, /duplicateTrack\(input\.existing, sha256, sha256\)/);
  assert.match(appSource, /id="storageImportMenuButton"/);
  assert.match(appSource, /id="storageImportMenu" role="menu"/);
  assert.match(appSource, /data-storage-import="link"/);
  assert.match(appSource, /data-storage-import="files"/);
  assert.match(appSource, /if \(type === "link"\) openLocalImport\(\);[\s\S]+else importAudio\(\);/);
  assert.doesNotMatch(appSource, /id="storageLinkImport"/);
  assert.doesNotMatch(appSource, /id="storageImport"/);
  assert.match(styleSource, /\.local-import-dialog\s*\{/);
  assert.match(styleSource, /\.local-import-media-kind\s*\{/);
  assert.match(styleSource, /\.local-import-sync input:checked\s*\{/);
  assert.match(styleSource, /\.local-import-preview-button\s*\{/);
  assert.match(styleSource, /\.local-import-preview-button\.playing/);
  assert.match(styleSource, /@keyframes local-import-preview-spin/);
  assert.match(styleSource, /\.local-import-sync input:checked::before/);
  assert.match(styleSource, /\.local-import-sync:has\(input:checked\)/);
  assert.match(styleSource, /\.local-import-icon-action\s*\{/);
  assert.match(styleSource, /\.local-import-art img[\s\S]+object-fit: cover/);
  assert.match(styleSource, /\.storage-import-menu\s*\{/);
  assert.match(styleSource, /\.local-import-candidates\s*\{[\s\S]*?overflow-y: auto/);
  assert.match(styleSource, /\.local-import-resolved\[hidden\],[\s\S]*?display: none/);
  assert.match(packageSource, /"ffmpeg-static": "\^5\.3\.0"/);
  assert.match(packageSource, /"local-debrid\.cjs"/);
  assert.match(packageSource, /"node_modules\/ffmpeg-static\/\*\*"/);
});

test("opens a listening-history analytics dialog and records real playback time", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const preloadSource = readFileSync(new URL("../preload.cjs", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.match(htmlSource, /id="profileHistory"[\s\S]+Listening History/);
  assert.match(htmlSource, /id="listeningHistoryDialog"/);
  assert.match(htmlSource, /id="listeningHistoryRange"/);
  assert.match(htmlSource, /<option value="1">Last 1 day<\/option>/);
  assert.match(htmlSource, /id="historyPreviousWindow"[\s\S]+id="historyNextWindow"[\s\S]+disabled/);
  assert.match(htmlSource, /<\/header>\s*<div id="listeningHistoryToolbar" class="history-content-toolbar">[\s\S]+class="history-window-controls"/);
  assert.match(htmlSource, /id="historyWindowLabel" class="history-window-label"/);
  assert.match(htmlSource, /id="listeningHistoryToolbar" class="history-content-toolbar"/);
  assert.match(htmlSource, /id="listeningHistoryDayDetails"[\s\S]+aria-live="polite"/);
  assert.match(htmlSource, /aria-label="Listening history view"[\s\S]+data-history-mode="overall"[\s\S]+data-history-mode="stats"/);
  assert.doesNotMatch(htmlSource, /data-history-mode="songs"|>By song</);
  assert.match(htmlSource, /id="listeningHistoryChartSection"/);
  assert.doesNotMatch(htmlSource, /id="listeningHistorySummary"/);
  assert.match(appSource, /function renderListeningHistory\(\)/);
  assert.match(appSource, /historyWindowLabel"\)\.textContent = formatHistoryWindowLabel\(summary\)/);
  assert.match(appSource, /function currentListeningHistorySummary\(\)[\s\S]+summarizeListeningHistory\(state, range, new Date\(\), listeningHistoryWindowOffset\)/);
  assert.match(appSource, /function ensureListeningHistorySelection\(summary = currentListeningHistorySummary\(\)\)[\s\S]+preferredListeningHistoryBucket\(summary\)/);
  assert.match(appSource, /function shiftListeningHistoryWindow\(offsetChange\)[\s\S]+selectedIndex[\s\S]+listeningHistoryWindowOffset = Math\.max\(0,[\s\S]+nextSummary\.days/);
  assert.match(appSource, /const selectedBucketExists = summary\.days\.some[\s\S]+const hasSelectedDay = listeningHistoryMode === "overall" && selectedBucketExists/);
  assert.match(appSource, /listeningHistoryRange"\)\.onchange[\s\S]+listeningHistoryWindowOffset = 0[\s\S]+ensureListeningHistorySelection\(\)/);
  assert.match(appSource, /historyPreviousWindow"\)\.onclick = \(\) => shiftListeningHistoryWindow\(1\)/);
  assert.match(appSource, /historyNextWindow"\)\.onclick = \(\) => shiftListeningHistoryWindow\(-1\)/);
  assert.match(appSource, /listeningHistoryMode"\)\.onclick[\s\S]+listeningHistoryMode = button\.dataset\.historyMode[\s\S]+ensureListeningHistorySelection\(\)/);
  assert.match(appSource, /function openListeningHistory\(\)[\s\S]+listeningHistoryMode = "overall"[\s\S]+listeningHistoryWindowOffset = 0[\s\S]+ensureListeningHistorySelection\(\)/);
  assert.match(appSource, /function beginListeningSession\(\)/);
  assert.match(appSource, /entry\.listenedSeconds \+= delta/);
  assert.match(appSource, /api\.onPrepareToClose\(async \(\) =>[\s\S]+updateListeningSession\(\)[\s\S]+await persist\(\{ refreshSidebar: false \}\)[\s\S]+api\.readyToClose\(\)/);
  assert.match(preloadSource, /onPrepareToClose:[\s\S]+app:prepare-close/);
  assert.match(preloadSource, /readyToClose:[\s\S]+app:close-ready/);
  assert.match(preloadSource, /postListeningHistory:[\s\S]+server:listening-history:post/);
  assert.match(preloadSource, /fetchListeningHistory:[\s\S]+server:listening-history:get/);
  assert.match(mainSource, /function safeListeningHistory\(value\)/);
  assert.match(mainSource, /listeningHistory: safeListeningHistory\(state\.listeningHistory\)/);
  assert.match(mainSource, /ipcMain\.handle\("server:listening-history:post"/);
  assert.match(mainSource, /ipcMain\.handle\("server:listening-history:get"/);
  assert.match(mainSource, /api\/v1\/listening-history/);
  assert.match(mainSource, /JSON\.stringify\(\{ client: "windows", entries \}\)/);
  assert.match(mainSource, /response\.status === 404[\s\S]+supported: false/);
  assert.match(appSource, /const LISTENING_HISTORY_BATCH_SIZE = 500/);
  assert.match(appSource, /profileID: activeProfileID\(\)/);
  assert.match(appSource, /function pendingListeningHistoryBatches\(\)/);
  assert.match(appSource, /api\.postListeningHistory\(\{/);
  assert.match(appSource, /api\.fetchListeningHistory\(\{/);
  assert.match(appSource, /mergeListeningHistory\(state, pullProfileID/);
  assert.match(appSource, /result\?\.supported === false/);
  assert.match(appSource, /scheduleListeningHistorySync\(\)/);
  assert.match(appSource, /syncListeningHistoryNow\(\{ force: true \}\)/);
  assert.match(mainSource, /librarySaveQueue[\s\S]+\.catch\(\(\) => \{\}\)[\s\S]+fs\.writeFile/);
  assert.match(mainSource, /window\.webContents\.send\("app:prepare-close"\)/);
  assert.match(mainSource, /ipcMain\.on\("app:close-ready"/);
  assert.match(appSource, /const allTimeStats = summarizeListeningStats\(state, new Date\(\)\)/);
  assert.match(appSource, /toolbar\.hidden = statsMode/);
  assert.match(appSource, /"Total Time Listened"[\s\S]+"Total Plays"[\s\S]+"Total Songs Heard"[\s\S]+"Most Popular Artist"/);
  assert.doesNotMatch(appSource, /"Average Play"[\s\S]+"Today"[\s\S]+"Top Song"[\s\S]+"Library Size"/);
  assert.match(appSource, /id="historyTopSongToggle"[\s\S]+aria-controls="historySongRanking"[\s\S]+aria-expanded=/);
  assert.match(appSource, /class="history-ranked-song"[\s\S]+id="historySongRanking"/);
  assert.match(appSource, /listeningHistorySongsExpanded = !listeningHistorySongsExpanded[\s\S]+renderListeningHistory\(\)/);
  assert.match(appSource, /function openListeningHistory\(\)[\s\S]+listeningHistorySongsExpanded = false/);
  assert.doesNotMatch(appSource, /listeningHistorySummary/);
  assert.match(appSource, /summary\.songSeries[\s\S]+\.map\(\(series\) =>/);
  assert.match(appSource, /const statsMode = listeningHistoryMode === "stats"/);
  assert.match(appSource, /stats\.hidden = !statsMode[\s\S]+chartSection\.hidden = statsMode/);
  assert.match(appSource, /if \(statsMode\) \{[\s\S]+listeningHistoryChart"\)\.innerHTML = ""/);
  assert.doesNotMatch(appSource, /tickIndexes/);
  assert.doesNotMatch(appSource, /history-day-tick/);
  assert.match(appSource, /class="history-y-axis"/);
  assert.doesNotMatch(appSource, /class="history-y-axis-line"/);
  assert.match(appSource, /const height = 250/);
  assert.match(appSource, /const right = 40[\s\S]+const top = 8[\s\S]+const bottom = 8/);
  assert.match(appSource, /const axisMaximum = summary\.granularity === "hour" \? 60 : niceChartMaximum\(peak\)/);
  assert.match(appSource, /const yTicks = Array\.from\(\{ length: 5 \}[\s\S]+axisMaximum \* \(1 - index \/ 4\)/);
  assert.match(appSource, /Math\.min\(day\.seconds \/ 60, axisMaximum\)/);
  assert.match(appSource, /function historyAxisLabel\(value\)/);
  assert.match(appSource, /absolute === 0\) return "0m"/);
  assert.match(appSource, /absolute >= 60[\s\S]+hours[\s\S]+h`/);
  assert.match(appSource, /return `<text x="10"[\s\S]+text-anchor="start"/);
  assert.match(appSource, /function historyBucketLabel\(summary, date, options = \{\}\)/);
  assert.match(appSource, /summary\.granularity === "hour"[\s\S]+hour: "numeric"/);
  assert.match(appSource, /\$\{hourly \? "HOUR" : "DAY"\} BREAKDOWN/);
  assert.doesNotMatch(appSource, /Math\.max\(30, Math\.ceil\(peak \/ 30\) \* 30\)/);
  assert.match(appSource, /function bindListeningHistoryChartInteractions\(summary\)/);
  assert.match(appSource, /addEventListener\("pointermove"/);
  assert.match(appSource, /class="history-chart-tooltip"/);
  assert.match(appSource, /class="history-chart-viewport" data-day-count="\$\{summary\.days\.length\}"/);
  assert.match(appSource, /const width = 732/);
  assert.match(appSource, /preserveAspectRatio="none"/);
  assert.doesNotMatch(appSource, /daySpacing|scrollWidth|focusLatest/);
  assert.match(appSource, /const bars = points\.map/);
  assert.match(appSource, /function historyDayDetailsMarkup\(summary, dayKey\)/);
  assert.match(appSource, /data-history-day="\$\{escapeHTML\(point\.day\.key\)\}"[\s\S]+role="button" tabindex="0"/);
  assert.match(appSource, /class="history-day-song-header"[\s\S]+Title[\s\S]+Album[\s\S]+Listening time[\s\S]+Plays/);
  assert.match(appSource, /class="history-day-song-number"[\s\S]+artwork\(track\)[\s\S]+class="history-day-song-copy"[\s\S]+class="history-day-song-album"/);
  assert.match(appSource, /class="history-day-song-time"[\s\S]+historyListenedTime\(activity\.seconds\)[\s\S]+class="history-day-song-plays"/);
  assert.match(appSource, /viewport\.addEventListener\("click"[\s\S]+expandDay/);
  assert.match(appSource, /viewport\.addEventListener\("keydown"[\s\S]+event\.key !== "Enter"[\s\S]+event\.key !== " "/);
  assert.match(appSource, /classList\.toggle\("day-expanded", hasSelectedDay\)/);
  assert.match(appSource, /closeHistoryDayDetails[\s\S]+selectedListeningHistoryDayKey = null/);
  assert.match(appSource, /previousDialogScroll[\s\S]+dialog\.scrollTop = previousDialogScroll/);
  assert.doesNotMatch(appSource, /previousDetailsScroll/);
  assert.match(appSource, /const barDensity = Math\.max\(0\.28, Math\.min\(0\.72, 0\.78 - summary\.days\.length \/ 180\)\)/);
  assert.match(appSource, /const barWidth = Math\.max\(5, Math\.min\(38, plotWidth \/ summary\.days\.length \* barDensity\)\)/);
  assert.match(appSource, /<g class="history-grid">\$\{grid\}<\/g>/);
  assert.match(appSource, /<rect class="history-bar\$\{peakClass\}\$\{selectedClass\}"/);
  assert.match(appSource, /Math\.floor\(dayProgress \* summary\.days\.length\)/);
  assert.doesNotMatch(appSource, /mode === "songs"|historySeriesColor|history-highlight-label|history-song-line|history-song-legend/);
  assert.doesNotMatch(appSource, /class="history-area"/);
  assert.doesNotMatch(appSource, /class="history-line"/);
  assert.match(styleSource, /\.listening-history-stats/);
  assert.match(styleSource, /\.listening-history-panel\s*\{[\s\S]*?--history-ambient-surface:[\s\S]*?radial-gradient\(circle at 16% 12%, #536bff24[\s\S]*?radial-gradient\(circle at 76% 20%, #7547ff20[\s\S]*?radial-gradient\(circle at 88% 100%, #ff806c10/);
  assert.match(styleSource, /\.history-content-toolbar\s*\{[\s\S]*?background: transparent/);
  assert.match(styleSource, /\.listening-history-stats\s*\{[\s\S]*?background: transparent/);
  assert.match(styleSource, /\.listening-history-chart\s*\{[\s\S]*?background: transparent/);
  assert.match(styleSource, /\.listening-history-day-details\s*\{[\s\S]*?background: transparent/);
  assert.doesNotMatch(styleSource, /\.listening-history-day-details\s*\{[^}]*border-top/);
  assert.match(styleSource, /\.history-window-button\s*\{[\s\S]+\.history-window-button:disabled/);
  assert.match(styleSource, /\.history-window-button\s*\{[\s\S]*?height: 32px[\s\S]*?border-radius: 999px/);
  assert.match(styleSource, /\.history-range\s*\{[\s\S]*?height: 32px[\s\S]*?border-radius: 999px/);
  assert.match(styleSource, /\.history-content-toolbar\s*\{[\s\S]+justify-content: flex-end/);
  assert.match(styleSource, /\.history-window-label\s*\{[\s\S]+margin-right: auto/);
  assert.match(styleSource, /\.history-content-toolbar\[hidden\]\s*\{\s*display: none/);
  assert.match(styleSource, /\.history-stats-summary\s*\{[\s\S]*?grid-template-columns: repeat\(4, minmax\(0, 1fr\)\)/);
  assert.match(styleSource, /\.history-top-song-cover\s*\{[\s\S]*?width: 78px[\s\S]*?height: 78px/);
  assert.match(styleSource, /\.listening-history-panel\s*\{[\s\S]*?overflow-x: hidden[\s\S]*?overflow-y: auto/);
  assert.match(styleSource, /\.listening-history-stats\s*\{[\s\S]*?max-width: 100%[\s\S]*?overflow: hidden/);
  assert.match(styleSource, /\.history-top-song-section\s*\{[\s\S]*?max-width: 100%[\s\S]*?overflow: hidden/);
  assert.match(styleSource, /\.history-song-ranking\s*\{[\s\S]*?grid-auto-flow: column[\s\S]*?max-width: 100%[\s\S]*?overflow-x: auto/);
  assert.match(styleSource, /\.history-ranked-song \.row-art\s*\{[\s\S]*?width: 146px[\s\S]*?height: 146px/);
  assert.match(styleSource, /\.listening-history-stats\[hidden\],[\s\S]+\.listening-history-chart\[hidden\][\s\S]+display: none/);
  assert.match(styleSource, /\.history-bar\s*\{[\s\S]*?fill: url\("#historyBarGradient"\)/);
  assert.match(styleSource, /\.history-bar\.peak\s*\{[\s\S]*?fill: url\("#historyPeakBarGradient"\)/);
  assert.match(styleSource, /\.history-bar\.selected[\s\S]*?stroke: #e1d8ff/);
  assert.doesNotMatch(styleSource, /\.history-song-line|\.history-song-legend|\.history-highlight-label|\.song-mode/);
  assert.match(styleSource, /\.history-chart-viewport\s*\{[\s\S]*?overflow: hidden/);
  assert.match(styleSource, /\.history-chart-svg\s*\{[\s\S]*?width: 100%[\s\S]*?min-width: 0/);
  assert.doesNotMatch(styleSource, /\.history-chart-scroll/);
  assert.match(styleSource, /#listeningHistoryChart\s*\{[\s\S]*?height: 258px/);
  assert.match(styleSource, /\.history-chart-frame\s*\{[\s\S]*?height: 258px/);
  assert.doesNotMatch(styleSource, /\.history-chart-frame\s*\{[^}]*grid-template-columns/);
  assert.match(styleSource, /\.history-y-axis\s*\{[\s\S]*?position: absolute[\s\S]*?right: 0[\s\S]*?background: transparent[\s\S]*?pointer-events: none/);
  assert.match(styleSource, /\.history-y-axis text\s*\{[\s\S]*?font-weight: 650/);
  assert.match(styleSource, /\.history-grid line\s*\{[\s\S]*?stroke: #ffffff24[\s\S]*?stroke-width: 1/);
  assert.doesNotMatch(styleSource, /\.history-axis-title/);
  assert.doesNotMatch(htmlSource, /class="history-axis-title"/);
  assert.match(styleSource, /\.history-hover-guide/);
  assert.match(styleSource, /\.history-chart-tooltip/);
  assert.match(styleSource, /\.listening-history-dialog\s*\{[\s\S]*?max-width: calc\(100vw - 48px\)/);
  assert.match(styleSource, /\.listening-history-dialog\.day-expanded\s*\{[\s\S]*?width: min\(980px[\s\S]*?overflow-y: auto/);
  assert.match(styleSource, /\.listening-history-dialog\.day-expanded \.listening-history-panel\s*\{[\s\S]*?max-height: none[\s\S]*?overflow: visible/);
  assert.match(styleSource, /\.listening-history-dialog\.day-expanded \.history-day-song-list\s*\{[\s\S]*?max-height: none[\s\S]*?overflow: visible/);
  assert.match(styleSource, /\.history-day-song-list\s*\{[\s\S]*?background: transparent/);
  assert.match(styleSource, /\.history-day-song-header,[\s\S]*?\.history-day-song\s*\{[\s\S]*?grid-template-columns: 28px 46px minmax\(190px, 1fr\) minmax\(110px, \.55fr\) 86px 52px/);
  assert.match(styleSource, /\.history-day-song-header\s*\{[\s\S]*?text-transform: uppercase/);
  assert.match(styleSource, /\.history-day-song\s*\{[\s\S]*?padding: 9px 12px[\s\S]*?border-bottom: 1px solid var\(--line\)[\s\S]*?border-radius: 8px/);
  assert.match(styleSource, /\.history-day-song:hover\s*\{\s*background: #ffffff0a/);
  assert.match(styleSource, /\.history-day-song-copy strong\s*\{[\s\S]*?font-size: 12px/);
  assert.match(styleSource, /\.history-day-song-time\s*\{[\s\S]*?color: #bba7ff/);
  assert.match(styleSource, /\.history-chart-viewport\s*\{[\s\S]*?max-width: 100%/);
  assert.match(styleSource, /#listeningHistoryChart\s*\{[\s\S]*?min-width: 0/);
});

test("summarizes persisted listening history by local day", () => {
  const now = new Date(2026, 6, 30, 12, 0, 0);
  const state = normalizeState({
    syncProfileID: "music-room",
    listeningHistory: [
      { id: "first", trackID: "a", profileID: "music-room", startedAt: new Date(2026, 6, 30, 8, 0, 0).toISOString(), listenedSeconds: 600 },
      { id: "second", trackID: "b", startedAt: new Date(2026, 6, 29, 8, 0, 0).toISOString(), listenedSeconds: 300 },
      { id: "old", trackID: "c", startedAt: new Date(2026, 5, 1, 8, 0, 0).toISOString(), listenedSeconds: 900 },
    ],
  });
  const summary = summarizeListeningHistory(state, 7, now);
  assert.equal(summary.totalSeconds, 600);
  assert.equal(summary.plays, 1);
  assert.equal(summary.todaySeconds, 600);
  assert.equal(summary.todayPlays, 1);
  assert.equal(summary.songs, 1);
  assert.equal(summary.days.at(-1).seconds, 600);
  assert.equal(summary.songSeries.length, 1);
  assert.equal(summary.songSeries[0].trackID, "a");
  assert.equal(state.listeningHistory[0].profileID, "music-room");
  assert.equal(state.listeningHistory[1].profileID, "default");
  assert.equal(summary.songSeries[0].days.at(-1).seconds, 600);
  const restored = normalizeState(JSON.parse(JSON.stringify(state)));
  assert.deepEqual(restored.listeningHistory, state.listeningHistory);
  assert.equal(summarizeListeningHistory(restored, 7, now).totalSeconds, 600);
  const defaultState = normalizeState({ ...JSON.parse(JSON.stringify(state)), syncProfileID: "default" });
  const defaultSummary = summarizeListeningHistory(defaultState, 7, now);
  assert.equal(defaultSummary.totalSeconds, 300);
  assert.equal(defaultSummary.plays, 1);
  assert.equal(defaultSummary.todaySeconds, 0);
  assert.equal(defaultSummary.songs, 1);
  assert.equal(defaultSummary.songSeries[0].trackID, "b");
  assert.equal(summarizeListeningHistory(state, 30, now).days.length, 30);
  assert.equal(summarizeListeningHistory(state, 90, now).days.length, 90);
  const previousWindow = summarizeListeningHistory(state, 7, now, 1);
  assert.equal(previousWindow.days.at(-1).date.getDate(), 23);
  assert.equal(previousWindow.totalSeconds, 0);
});

test("merges downloaded listening history only into its profile and maps shared songs locally", () => {
  const state = normalizeState({
    syncProfileID: "alpha",
    tracks: [
      { id: "local-song", remoteID: "server-song", syncProfileID: "alpha", title: "Local title", artist: "Local artist" },
    ],
    listeningHistory: [
      { id: "same-event", trackID: "local-song", profileID: "alpha", startedAt: "2026-07-30T17:00:00Z", listenedSeconds: 20 },
      { id: "default-event", trackID: "default-song", profileID: "default", startedAt: "2026-07-30T18:00:00Z", listenedSeconds: 15 },
    ],
  });
  state.listeningHistory = mergeListeningHistory(state, "alpha", [
    {
      id: "same-event",
      track_id: "other-device-track",
      song_id: "server-song",
      started_at: "2026-07-30T17:00:00Z",
      listened_seconds: 45,
      title: "Server title",
      artist: "Server artist",
    },
    {
      id: "remote-event",
      track_id: "remote-only-track",
      started_at: "2026-07-30T19:00:00Z",
      listened_seconds: 30,
      title: "Remote only",
      artist: "Remote artist",
    },
  ]);

  assert.equal(state.listeningHistory.length, 3);
  const merged = state.listeningHistory.find((entry) => entry.id === "same-event");
  assert.equal(merged.profileID, "alpha");
  assert.equal(merged.trackID, "local-song");
  assert.equal(merged.listenedSeconds, 45);
  assert.equal(state.listeningHistory.find((entry) => entry.id === "default-event").profileID, "default");
  const stats = summarizeListeningStats(state, new Date("2026-07-30T20:00:00Z"));
  assert.equal(stats.totalSeconds, 75);
  assert.equal(stats.plays, 2);
  assert.equal(stats.topArtist, "Local artist");
  assert.equal(stats.songRanking.find((song) => song.trackID === "remote-only-track").title, "Remote only");
});

test("summarizes all-time listening stats independently of the graph window", () => {
  const now = new Date(2026, 6, 30, 12, 0, 0);
  const result = summarizeListeningStats({
    syncProfileID: "alpha-room",
    tracks: [
      { id: "a", title: "First", artist: "Alpha" },
      { id: "b", title: "Second", artist: "Beta" },
      { id: "c", title: "Other profile", artist: "Gamma" },
    ],
    listeningHistory: [
      { trackID: "a", profileID: "alpha-room", startedAt: new Date(2026, 6, 29, 10, 0, 0).toISOString(), listenedSeconds: 120 },
      { trackID: "a", profileID: "alpha-room", startedAt: new Date(2026, 6, 30, 8, 0, 0).toISOString(), listenedSeconds: 60 },
      { trackID: "b", profileID: "alpha-room", startedAt: new Date(2026, 6, 30, 9, 0, 0).toISOString(), listenedSeconds: 30 },
      { trackID: "c", profileID: "other-room", startedAt: new Date(2026, 6, 30, 10, 0, 0).toISOString(), listenedSeconds: 900 },
    ],
  }, now);
  assert.equal(result.totalSeconds, 210);
  assert.equal(result.plays, 3);
  assert.equal(result.songs, 2);
  assert.equal(result.averageSeconds, 70);
  assert.equal(result.todaySeconds, 90);
  assert.equal(result.topTrackID, "a");
  assert.equal(result.topArtist, "Alpha");
  assert.deepEqual(result.songRanking.map((song) => song.trackID), ["a", "b"]);
});

test("summarizes one-day windows into calendar hours", () => {
  const now = new Date(2026, 6, 30, 12, 35, 0);
  const state = normalizeState({
    listeningHistory: [
      { id: "current-day", trackID: "a", startedAt: new Date(2026, 6, 30, 11, 10, 0).toISOString(), listenedSeconds: 120 },
      { id: "current-morning", trackID: "b", startedAt: new Date(2026, 6, 30, 1, 30, 0).toISOString(), listenedSeconds: 180 },
      { id: "previous-day", trackID: "c", startedAt: new Date(2026, 6, 29, 23, 15, 0).toISOString(), listenedSeconds: 300 },
    ],
  });
  const summary = summarizeListeningHistory(state, 1, now);
  assert.equal(summary.granularity, "hour");
  assert.equal(summary.days.length, 24);
  assert.equal(summary.days[0].date.getHours(), 0);
  assert.equal(summary.days.at(-1).date.getHours(), 23);
  assert.equal(summary.days[1].seconds, 180);
  assert.equal(summary.days[11].seconds, 120);
  assert.equal(summary.totalSeconds, 300);
  assert.equal(summary.plays, 2);
  assert.equal(summary.todaySeconds, 300);
  assert.equal(summary.songSeries.length, 2);
  const yesterday = summarizeListeningHistory(state, 1, now, 1);
  assert.equal(yesterday.days[0].date.getDate(), 29);
  assert.equal(yesterday.days[23].seconds, 300);
  assert.equal(yesterday.totalSeconds, 300);
  assert.equal(yesterday.todaySeconds, 300);
});

test("formats compact listening-history window labels", () => {
  const now = new Date(2026, 6, 30, 12, 0, 0);
  assert.equal(formatHistoryWindowLabel({
    days: [{ date: new Date(2026, 6, 1) }, { date: new Date(2026, 6, 7) }],
  }, now, "en-US"), "July 1–7");
  assert.equal(formatHistoryWindowLabel({
    days: [{ date: new Date(2026, 6, 30) }],
  }, now, "en-US"), "July 30");
  assert.equal(formatHistoryWindowLabel({
    days: [{ date: new Date(2026, 5, 25) }, { date: new Date(2026, 6, 1) }],
  }, now, "en-US"), "June 25–July 1");
  assert.equal(formatHistoryWindowLabel({
    days: [{ date: new Date(2025, 11, 30) }, { date: new Date(2026, 0, 5) }],
  }, now, "en-US"), "December 30, 2025–January 5, 2026");
});

test("scales listening-history axes from the visible peak", () => {
  assert.equal(niceChartMaximum(0), 1);
  assert.equal(niceChartMaximum(0.5), 0.6);
  assert.equal(niceChartMaximum(4), 5);
  assert.equal(niceChartMaximum(17), 20);
  assert.equal(niceChartMaximum(20), 25);
  assert.equal(niceChartMaximum(55), 60);
  assert.equal(niceChartMaximum(325), 400);
});

test("selects the newest stable release that actually has a Windows update feed", async () => {
  const fetchImpl = async () => ({
    ok: true,
    json: async () => [
      {
        tag_name: "android-v1.0.4",
        draft: false,
        prerelease: false,
        assets: [{ name: "Resonance-Android.apk", browser_download_url: "https://github.com/Drastics-Experiments/resonance/releases/download/android-v1.0.4/Resonance-Android.apk" }],
      },
      {
        tag_name: "v1.0.3",
        draft: false,
        prerelease: false,
        assets: [{ name: "latest.yml", browser_download_url: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.0.3/latest.yml" }],
      },
    ],
  });

  assert.deepEqual(await resolveWindowsUpdateFeed(fetchImpl), {
    tag: "v1.0.3",
    feedURL: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.0.3/",
  });
});

test("rejects release lists without a Windows manifest and shortens updater errors", async () => {
  const fetchImpl = async () => ({
    ok: true,
    json: async () => [{ tag_name: "android-v1.0.4", assets: [] }],
  });
  await assert.rejects(resolveWindowsUpdateFeed(fetchImpl), /No published Windows release/);
  assert.equal(
    conciseUpdaterError(new Error("Cannot find latest.yml: 404 Not Found\nvery long response headers and stack")),
    "The Windows update feed is temporarily unavailable.",
  );
});

test("converts embedded cover art into a renderable data URL", () => {
  assert.equal(metadata.pictureDataURL({ format: "image/png", data: Buffer.from([1, 2, 3]) }), "data:image/png;base64,AQID");
  assert.equal(metadata.pictureDataURL(null), null);
});

test("normalizes Liked Songs from favorites only", () => {
  const state = normalizeState({ tracks: [{ id: "a" }, { id: "b" }], playlists: [], favorites: ["b"] });
  assert.deepEqual(state.playlists[0].trackIDs, ["b"]);
  assert.equal(state.playlists[0].isSystem, true);
});

test("search, queue movement, playlists, and time formatting work", () => {
  const tracks = [
    { id: "a", title: "Glass", artist: "Local", album: "Sounds", filePath: "C:\\Music\\glass.mp3", dateAdded: "2026-01-01T00:00:00Z" },
    { id: "b", title: "Ping", artist: "Server", album: "Remote", filePath: "C:\\Music\\ping.mp4", dateAdded: "2026-02-01T00:00:00Z" },
  ];
  assert.deepEqual(filterTracks(tracks, "remote").map((track) => track.id), ["b"]);
  assert.deepEqual(filterTracks(tracks, "glass.mp3").map((track) => track.id), ["a"]);
  assert.deepEqual(filterTracks(tracks, "", "audio").map((track) => track.id), ["a"]);
  assert.deepEqual(filterTracks(tracks, "", "recent").map((track) => track.id), ["b", "a"]);
  assert.equal(nextIndex(tracks, "a", 1), 1);
  assert.equal(nextIndex(tracks, "a", -1), 1);
  assert.equal(nextIndex(tracks, "a", 1, true, () => 0), 1);
  assert.equal(formatTime(222), "3:42");
  assert.equal(normalizedVolume(0), 0);
  assert.equal(normalizedVolume(2), 1);
  assert.equal(normalizedVolume("invalid"), 0.78);
  const state = createEmptyState();
  state.tracks = tracks;
  state.playlists.push({ id: "p", name: "Test", trackIDs: ["b"], isSystem: false });
  assert.deepEqual(tracksForPlaylist(state, "p").map((track) => track.id), ["b"]);
  assert.deepEqual(filterPlaylists(state.playlists, tracks, "ping").map((playlist) => playlist.id), ["p"]);
});

test("normalizes persisted playback context against the current library", () => {
  const state = normalizeState({
    tracks: [{ id: "a" }, { id: "b" }],
    playlists: [],
    favorites: [],
    playbackQueueIDs: ["b", "missing", "a", "b"],
    playbackPlaylistID: "playlist-1",
  });
  assert.deepEqual(state.playbackQueueIDs, ["b", "a"]);
  assert.equal(state.playbackPlaylistID, "playlist-1");
});

test("replaces stale synced tracks instead of discarding the fresh download", () => {
  const state = normalizeState({
    ...createEmptyState(),
    tracks: [{ id: "stale", remoteID: "remote-1" }, { id: "local" }],
    favorites: ["stale"],
    remoteLikedSongIDs: ["remote-1"],
  });
  state.playlists.push({ id: "mix", name: "Mix", trackIDs: ["stale", "local"], isSystem: false });
  mergeSyncedTracks(state, {
    replacedTrackIDs: ["stale"],
    downloaded: [{ id: "stale", remoteID: "remote-1", title: "Fresh copy" }],
  });
  assert.deepEqual(state.tracks.map((track) => track.id), ["local", "stale"]);
  assert.deepEqual(state.favorites, ["stale"]);
  assert.deepEqual(state.playlists.find((playlist) => playlist.id === "mix").trackIDs, ["stale", "local"]);
});

test("merges dirty local playlists over the server without deleting unrelated playlists", () => {
  const state = createEmptyState();
  state.tracks = [
    { id: "local-a", remoteID: "a".repeat(24) },
    { id: "local-only", remoteID: null },
  ];
  state.playlists.push({
    id: "12345678-1234-ABCD-9876-ABCDEF123456",
    name: "Windows order",
    trackIDs: ["local-a", "local-only"],
    remoteSongIDs: [],
    isSystem: false,
  });
  state.dirtyPlaylistIDs = ["12345678-1234-abcd-9876-abcdef123456"];
  const remote = {
    revision: 4,
    playlists: [{ id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", name: "Other device", song_ids: ["b".repeat(24)] }],
  };

  const merge = mergePlaylistDocument(state, remote);
  assert.equal(merge.needsUpload, true);
  assert.equal(merge.document.revision, 4);
  assert.deepEqual(merge.document.playlists.map((playlist) => playlist.name), ["Other device", "Windows order"]);
  assert.equal(merge.document.playlists[1].id, "12345678-1234-abcd-9876-abcdef123456");
  assert.deepEqual(merge.document.playlists[1].song_ids, ["a".repeat(24)]);
});

test("applies remote ordering, preserves local-only songs, and hydrates later downloads", () => {
  const playlistID = "12345678-1234-abcd-9876-abcdef123456";
  const firstRemoteID = "a".repeat(24);
  const secondRemoteID = "b".repeat(24);
  const state = createEmptyState();
  state.tracks = [
    { id: "downloaded-a", remoteID: firstRemoteID },
    { id: "local-only", remoteID: null },
  ];
  state.playlists.push({ id: playlistID, name: "Old", trackIDs: ["local-only"], remoteSongIDs: [], isSystem: false });

  applyRemotePlaylistDocument(state, {
    revision: 7,
    playlists: [{ id: playlistID.toUpperCase(), name: "Shared", song_ids: [secondRemoteID, firstRemoteID] }],
  });
  assert.equal(state.playlistRevision, 7);
  assert.deepEqual(state.playlists[1].trackIDs, ["downloaded-a", "local-only"]);
  assert.deepEqual(state.playlists[1].remoteSongIDs, [secondRemoteID, firstRemoteID]);

  mergeSyncedTracks(state, { downloaded: [{ id: "downloaded-b", remoteID: secondRemoteID }], replacedTrackIDs: [] });
  assert.deepEqual(state.playlists[1].trackIDs, ["downloaded-b", "downloaded-a", "local-only"]);
});

test("deletions remove only the matching known server playlist", () => {
  const removedID = "12345678-1234-abcd-9876-abcdef123456";
  const retainedID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
  const state = createEmptyState();
  state.knownRemotePlaylistIDs = [removedID, retainedID];
  state.deletedPlaylistIDs = [removedID];
  const merge = mergePlaylistDocument(state, {
    revision: 2,
    playlists: [
      { id: removedID, name: "Delete me", song_ids: [] },
      { id: retainedID, name: "Keep me", song_ids: [] },
    ],
  });
  assert.equal(merge.needsUpload, true);
  assert.deepEqual(merge.document.playlists.map((playlist) => playlist.id), [retainedID]);
});

test("removing a downloaded song updates remote membership while keeping unresolved songs", () => {
  const state = createEmptyState();
  state.tracks = [{ id: "downloaded", remoteID: "a".repeat(24) }];
  const playlist = {
    id: "12345678-1234-abcd-9876-abcdef123456",
    name: "Membership",
    trackIDs: [],
    remoteSongIDs: ["a".repeat(24), "b".repeat(24)],
    isSystem: false,
  };
  updatePlaylistRemoteSongIDs(state, playlist);
  assert.deepEqual(playlist.remoteSongIDs, ["b".repeat(24)]);
});

test("profile playlist documents include remote likes and apply them without touching local likes", () => {
  const state = normalizeState({
    tracks: [
      { id: "local", remoteID: null },
      { id: "remote-a", remoteID: "song-a" },
      { id: "remote-b", remoteID: "song-b" },
    ],
    playlists: [{ id: "liked", name: "Liked Songs", trackIDs: [], isSystem: true }],
    favorites: ["local", "remote-a"],
    likesDirty: true,
  });

  const merge = mergePlaylistDocument(state, { revision: 3, playlists: [], liked_song_ids: [] });
  assert.deepEqual(merge.document.liked_song_ids, ["song-a"]);
  assert.equal(merge.needsUpload, true);

  state.dirtyRemoteLikeSongIDs = [];
  state.likesDirty = false;
  applyRemotePlaylistDocument(state, {
    revision: 4,
    playlists: [],
    liked_song_ids: ["song-b"],
  });
  assert.deepEqual(state.favorites.sort(), ["local", "remote-b"]);
  assert.equal(state.likesDirty, false);
});

test("keeps unavailable server likes and hydrates them after download", () => {
  const state = normalizeState({
    ...createEmptyState(),
    tracks: [{ id: "local", remoteID: null }],
    favorites: ["local"],
  });

  applyRemotePlaylistDocument(state, {
    revision: 8,
    playlists: [],
    liked_song_ids: ["not-downloaded-yet"],
  });
  assert.deepEqual(state.remoteLikedSongIDs, ["not-downloaded-yet"]);
  assert.deepEqual(state.favorites, ["local"]);

  mergeSyncedTracks(state, {
    downloaded: [{ id: "downloaded", remoteID: "not-downloaded-yet", syncProfileID: "default" }],
    replacedTrackIDs: [],
  });
  assert.deepEqual(state.favorites.sort(), ["downloaded", "local"]);
});

test("merges only locally changed likes over concurrent server likes", () => {
  const state = normalizeState({
    ...createEmptyState(),
    tracks: [
      { id: "remote-a", remoteID: "song-a", syncProfileID: "default" },
      { id: "remote-b", remoteID: "song-b", syncProfileID: "default" },
    ],
    favorites: ["remote-a"],
    remoteLikedSongIDs: ["song-a"],
    dirtyRemoteLikeSongIDs: ["song-a"],
    likesDirty: true,
  });
  state.remoteLikedSongIDs = [];

  const merge = mergePlaylistDocument(state, {
    revision: 11,
    playlists: [],
    liked_song_ids: ["song-a", "song-b", "song-c"],
  });
  assert.deepEqual(merge.document.liked_song_ids.sort(), ["song-b", "song-c"]);
});
