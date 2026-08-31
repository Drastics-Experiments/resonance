import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import {
  applyDownloadedSongMetadataRefresh,
  applyRemotePlaylistDocument,
  APP_THEMES,
  buildLocalImportSourceIdentity,
  catalogRequestCanApply,
  createEmptyState,
  downloadedSongMetadataRefreshSource,
  filterPlaylists,
  filterTracks,
  formatServerDownloadFailureNotice,
  formatServerUploadFailureNotice,
  formatHistoryWindowLabel,
  formatTime,
  hydrateListeningHistoryFromCatalog,
  isInstalledVideoTrack,
  installedVideoCatchUpRate,
  installedVideoSyncDecision,
  listeningHistoryEntryQualifiesAsPlay,
  localImportCandidateCanAutoSelect,
  localImportOperationFingerprint,
  localImportOperationIsCurrent,
  localImportNeedsServerContext,
  localImportPlaylistTransferKey,
  mergeListeningHistoryDocument,
  mergePlaylistOrderWithPreservedItems,
  mergePlaylistDocument,
  mergeSyncedTracks,
  mergeTrackSourceIdentity,
  mergeUploadedSongsIntoCatalog,
  migrateProfileContext,
  nextIndex,
  niceChartMaximum,
  normalizedAppPreferences,
  normalizedAppTheme,
  normalizedCrossfadeSeconds,
  crossfadeProgress,
  normalizedRemoteSongMetadataCache,
  normalizedVolume,
  playbackGainForVolume,
  playableMediaDuration,
  normalizeState,
  playbackRangeForTrack,
  planMissingDownloadedUploads,
  playlistArtworkTrackIDs,
  playlistInsertionIndex,
  preservedUploadSourceURL,
  remoteAssociationConflictFilePaths,
  remoteAssociationConflictMessage,
  remoteMediaDuration,
  remoteSongMetadataCacheKey,
  serverSongMetadataMatches,
  serverCatalogAuthorityIsCurrent,
  serverCatalogAuthoritySnapshot,
  reconcileServerBackedTrackDuplicates,
  reconcileUploadedTrack,
  reorderPlaylistEntries,
  reorderPlaylistTrackIDs,
  removeClipRangeForTrack,
  removeLibraryTracksFromPlaylists,
  restoreProfileState,
  resolveSyncProfile,
  serverUploadBlockedByActivity,
  serverUploadConfigurationError,
  serverTrackRemoteIDBelongsToContext,
  serverSongRequiresDownload,
  serverSongHasCatalogMetadata,
  serverSourceDisplayFallback,
  serverSourceNeedsOriginalPage,
  serverTransferProgressPresentation,
  shuffledTrackIDs,
  storeActiveProfileState,
  setClipRangeForTrack,
  squareArtworkCropRect,
  summarizeListeningHistory,
  summarizeListeningStats,
  titleMarqueeMetrics,
  tracksForActiveProfile,
  tracksForPlaylist,
  uniqueLocalImportPlaylistCandidates,
  updatePlaylistRemoteSongIDs,
} from "../ui/core.js";
import metadata from "../metadata.cjs";
import libraryPaths from "../library-paths.cjs";
import serverDownload from "../server-download.cjs";
import updaterFeed from "../updater-feed.cjs";
import discordRPC from "../discord-rpc.cjs";

const {
  conciseUpdaterError,
  fetchWindowsUpdateVersion,
  installDownloadedWindowsUpdate,
  parseWindowsReleaseTag,
  resolveMacUpdateManifest,
  resolveWindowsUpdateFeed,
  selectNewestWindowsRelease,
} = updaterFeed;
const { isManagedLibraryFile } = libraryPaths;
const {
  SERVER_DOWNLOAD_ATTEMPTS,
  createServerCatalogSnapshotStore,
  createServerDownloadProgressPublisher,
  retryServerDownload,
  serverDownloadDisplayName,
  serverDownloadImportedMetadata,
  serverDownloadMetadata,
  serverDownloadMetadataContextMatches,
  serverDownloadMetadataIsResolved,
  serverDownloadMetadataSnapshot,
  serverDownloadProgressEvent,
} = serverDownload;
const { discordArtworkURL, sanitizeDiscordActivity } = discordRPC;

test("playlist artwork uses only the first four custom-playlist songs", () => {
  const trackIDs = ["one", "two", "three", "four", "five"];
  assert.deepEqual(playlistArtworkTrackIDs({ trackIDs, isSystem: false }), trackIDs.slice(0, 4));
  assert.deepEqual(playlistArtworkTrackIDs({ trackIDs, isSystem: true }), []);
});

test("playlist artwork hydrates from remote-only playlist entries", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  assert.match(appSource, /tracksForPlaylist\(state, playlist\?\.id, serverCatalog\)\.slice\(0, 4\)/);
  assert.match(appSource, /data-playlist-artwork-remote-id/);
  assert.match(appSource, /function updatePlaylistArtworkNodes\(song\)[\s\S]+squareArtworkImageMarkup\(source\)/);
  assert.match(appSource, /hydrateServerArtwork\(song\)[\s\S]+updatePlaylistArtworkNodes\(song\)/);
  assert.match(appSource, /function playlistArtworkCatalogSongs\(songs = serverCatalog\)[\s\S]+tracksForPlaylist\(state, playlist\.id, songs\)\.slice\(0, 4\)/);
  assert.match(appSource, /function renderSidebar\(\)[\s\S]+hydratePlaylistArtwork\(serverCatalog\)/);
});

test("starts catalog and metadata loading without opening the server page", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  assert.match(appSource, /render\(\); updateChrome\(\);\s*if \(state\.serverURL && serverToken\) \{\s*serverAutoAttempted = true;\s*void serverAction\("catalog", \{ background: true, artworkScope: "playlists" \}\);/);
  assert.match(appSource, /function replaceServerCatalog\(songs\)[\s\S]+hydrateServerCatalogMetadataArtwork\(serverCatalog, context, generation\);\s*hydrateServerCatalogMetadata\(serverCatalog\);/);
  assert.match(appSource, /async function serverAction\(mode, \{ background = false, artworkScope = "catalog" \} = \{\}\)[\s\S]+if \(!serverTransferCancelRequested && !background\) showNotice\(serverConnectionText\)/);
});

test("playable media duration overrides stale stored and mismatched video timelines", () => {
  assert.equal(playableMediaDuration({ storedDuration: 7_200, audioDuration: 217.4 }), 217.4);
  assert.equal(playableMediaDuration({ storedDuration: 7_200, audioDuration: 217.4, videoDuration: 216.9 }), 216.9);
  assert.equal(playableMediaDuration({ storedDuration: 245, audioDuration: Number.NaN }), 245);
  assert.equal(playableMediaDuration({ storedDuration: -1 }), 0);
  assert.equal(remoteMediaDuration(1_686), 1_686);
  assert.equal(remoteMediaDuration(172_000), null);
});

test("migrates the legacy production server without losing saved profile state", () => {
  const state = normalizeState({
    ...createEmptyState(),
    serverURL: "https://music.unblocked.mov",
    syncProfileID: "active-profile",
    playlistSyncServerURL: "https://music.unblocked.mov#profile=active-profile",
    profileStates: {
      "https://music.unblocked.mov#profile=clerk-profile": {
        playlists: [{ id: "saved", name: "Saved", trackIDs: [], isSystem: false }],
      },
    },
  });
  assert.equal(state.serverURL, "https://resonance-core.blithe-haven-9710.chatgpt.site");
  assert.equal(
    state.playlistSyncServerURL,
    "https://resonance-core.blithe-haven-9710.chatgpt.site#profile=active-profile",
  );
  assert.equal(
    state.profileStates["https://resonance-core.blithe-haven-9710.chatgpt.site#profile=clerk-profile"]
      .playlists[0].name,
    "Saved",
  );
});

test("keeps audio authoritative without steady-state installed-video reseeking", () => {
  assert.equal(installedVideoCatchUpRate({
    audioRate: 1.5,
    audioPosition: 10,
    videoPosition: 10.02,
  }), 1.5);
  assert.ok(installedVideoCatchUpRate({
    audioRate: 1,
    audioPosition: 10,
    videoPosition: 9.5,
  }) > 1);
  assert.ok(installedVideoCatchUpRate({
    audioRate: 1,
    audioPosition: 10,
    videoPosition: 10.5,
  }) < 1);
  assert.equal(installedVideoCatchUpRate({
    audioRate: 1,
    audioPosition: 10,
    videoPosition: 5,
  }), 1.2);
  assert.equal(installedVideoSyncDecision({ audioPlaying: true, videoPlaying: false }), "play");
  assert.equal(installedVideoSyncDecision({
    audioPlaying: true,
    videoPlaying: true,
    driftSeconds: 0.4,
  }), "none");
  assert.equal(installedVideoSyncDecision({
    audioPlaying: true,
    videoPlaying: true,
    driftSeconds: 5,
  }), "none");
  assert.equal(installedVideoSyncDecision({
    audioPlaying: true,
    videoPlaying: true,
    driftSeconds: 0.01,
  }), "none");
  assert.equal(installedVideoSyncDecision({
    audioPlaying: false,
    videoPlaying: true,
    driftSeconds: 0.01,
  }), "pause");
  assert.equal(installedVideoSyncDecision({
    audioPlaying: true,
    videoPlaying: true,
    driftSeconds: 0.01,
    forceSeek: true,
  }), "seek");
  assert.equal(installedVideoSyncDecision({
    audioPlaying: true,
    videoPlaying: false,
    syncInFlight: true,
  }), "none");
});

test("uses a custom fullscreen video player with queue, repeat, controls, and shared volume", () => {
  assert.equal(isInstalledVideoTrack({ filePath: "C:\\Music\\clip.mp4", fileUrl: "file:///C:/Music/clip.mp4" }), true);
  assert.equal(isInstalledVideoTrack({ filePath: "C:\\Music\\clip.MOV", fileUrl: "file:///C:/Music/clip.MOV" }), true);
  assert.equal(isInstalledVideoTrack({ filePath: "C:\\Music\\song.m4a", fileUrl: "file:///C:/Music/song.m4a" }), false);
  assert.equal(isInstalledVideoTrack({ filePath: null, fileUrl: "https://music.example.com/clip.mp4" }), false);
  assert.equal(isInstalledVideoTrack({ filePath: "C:\\Music\\clip.mp4", fileUrl: null }), false);

  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  const firstFrameObserver = appSource.slice(
    appSource.indexOf("function observeInstalledVideoFirstFrame"),
    appSource.indexOf("function configureInstalledVideoSource"),
  );
  const videoSynchronizer = appSource.slice(
    appSource.indexOf("function synchronizeInstalledVideoWithAudio"),
    appSource.indexOf("function startInstalledVideoPlayback"),
  );
  const synchronizationCompleter = appSource.slice(
    appSource.indexOf("function completeInstalledVideoSynchronization"),
    appSource.indexOf("function synchronizeInstalledVideoWithAudio"),
  );
  const primaryAudioTimeUpdate = appSource.slice(
    appSource.indexOf("media.ontimeupdate = () =>"),
    appSource.indexOf("media.onplay = () =>"),
  );
  const openVideo = appSource.slice(
    appSource.indexOf("function openInstalledVideo"),
    appSource.indexOf("function playInstalledVideoTrack"),
  );
  const closeVideo = appSource.slice(
    appSource.indexOf("function closeInstalledVideo"),
    appSource.indexOf("function renderFullPlayer"),
  );
  assert.doesNotMatch(appSource, /ON DEVICE|fullPlayerMediaBadge/);
  assert.match(appSource, /data-library-filter="video"[^>]*>Video<\/button>/);
  assert.doesNotMatch(htmlSource, /VIDEO • ON DEVICE|fullPlayerMediaBadge/);
  assert.match(htmlSource, /id="fullPlayerArtwork"[\s\S]+id="installedVideoArtwork"[\s\S]+id="installedVideoPlayer"/);
  assert.match(htmlSource, /id="fullPlayerArtworkContent"[\s\S]+id="fullPlayerVideoLaunch"[^>]+hidden disabled/);
  assert.match(appSource, /const videoAvailable = isInstalledVideoTrack\(track\)[\s\S]+classList\.toggle\("video-available", videoAvailable\)[\s\S]+videoLaunch\.hidden = !videoAvailable/);
  assert.match(appSource, /#fullPlayerVideoLaunch"\)\.onclick = \(\) => \{[\s\S]+openInstalledVideo\(track\)/);
  assert.match(styleSource, /\.full-player-artwork\.video-available:hover \.full-player-video-launch[\s\S]+opacity: 1/);
  assert.match(htmlSource, /id="installedVideoPlayer"[^>]*preload="auto"[^>]*\smuted(?:\s|>)/);
  assert.doesNotMatch(htmlSource, /id="installedVideoPlayer"[^>]*\scontrols(?:\s|>|=)/);
  assert.match(htmlSource, /id="installedVideoControls"[\s\S]+id="installedVideoSeek"[\s\S]+id="installedVideoPrevious"[\s\S]+id="installedVideoToggle"[\s\S]+id="installedVideoNext"[\s\S]+id="installedVideoRepeat"[\s\S]+id="installedVideoVolume"/);
  assert.match(htmlSource, /id="minimizeInstalledVideo"[\s\S]+id="restoreInstalledVideo"[\s\S]+id="dismissMiniVideo"/);
  assert.match(appSource, /function minimizeInstalledVideo\(\)[\s\S]+session\.mini = true[\s\S]+dialog\.show\(\)/);
  assert.match(appSource, /function restoreInstalledVideo\(\)[\s\S]+session\?\.mini[\s\S]+dialog\.showModal\(\)/);
  assert.match(appSource, /function hasBlockingDialog\(\)[\s\S]+#installedVideoDialog\.video-mini/);
  assert.match(styleSource, /\.installed-video-dialog\.video-mini\s*\{[\s\S]+inset: auto 18px 101px auto[\s\S]+width: min\(390px/);
  assert.match(appSource, /function setInstalledVideoSourceGeometry\(sourceRect, targetRect\)[\s\S]+--video-source-translate-x[\s\S]+--video-source-scale-x[\s\S]+--video-source-radius-x[\s\S]+--video-source-border-color[\s\S]+--video-source-shadow/);
  assert.match(appSource, /INSTALLED_VIDEO_TRANSITION_MS = 400[\s\S]+INSTALLED_VIDEO_EXIT_ARTWORK_LEAD_MS = 190[\s\S]+INSTALLED_VIDEO_CHROME_RESTORE_LEAD_MS = 120/);
  assert.doesNotMatch(appSource, /INSTALLED_VIDEO_REVEAL_MS/);
  assert.doesNotMatch(appSource, /INSTALLED_VIDEO_LEAD_IN_MS/);
  assert.match(appSource, /function openInstalledVideo\([\s\S]+video-from-art[\s\S]+video-expanded[\s\S]+video-revealed/);
  assert.match(appSource, /function activePlaybackMedia\(\) \{\s+return audio;\s+\}/);
  assert.doesNotMatch(openVideo, /audio\.pause\(\)|audio\.muted\s*=/);
  assert.match(videoSynchronizer, /installedVideoPlayer\.muted = true[\s\S]+installedVideoPlayer\.volume = 0/);
  assert.match(videoSynchronizer, /installedVideoSyncDecision\([\s\S]+installedVideoPlayer\.currentTime = audioTime/);
  assert.doesNotMatch(videoSynchronizer, /audio\.pause\(\)|audio\.muted\s*=|audio\.currentTime\s*=/);
  assert.doesNotMatch(synchronizationCompleter, /synchronizeInstalledVideoWithAudio/);
  assert.match(primaryAudioTimeUpdate, /synchronizeInstalledVideoWithAudio\(\)/);
  assert.doesNotMatch(primaryAudioTimeUpdate, /forceSeek/);
  assert.doesNotMatch(appSource, /installedVideoOwnsPlayback|videoOwnsPlayback|handOffInstalledVideoToAudio|audioHandoffPending/);
  assert.match(appSource, /async function requestPlayback\(\)[\s\S]+const media = activePlaybackMedia\(\)[\s\S]+await media\.play\(\)/);
  assert.match(appSource, /function animateInstalledVideoStage\(from, to, onFinish\)[\s\S]+classList\.add\("video-geometry-animating"\)[\s\S]+applyInstalledVideoStageGeometry\(from\)[\s\S]+\.animate\(\[from, to\],[\s\S]+animation\.cancel\(\)[\s\S]+clearInstalledVideoStageGeometry\(\)[\s\S]+classList\.remove\("video-geometry-animating"\)/);
  assert.match(appSource, /function revealInstalledVideoFirstFrame\([\s\S]+firstFrameReady = true[\s\S]+classList\.add\("video-revealed", "video-frame-ready"\)/);
  assert.match(appSource, /installedVideoPlayer\.onloadeddata = \(\) => \{[^]*?requestVideoFrameCallback[^]*?observeInstalledVideoFirstFrame\(track\.id\)/);
  assert.match(firstFrameObserver, /installedVideoPlayer\.seeking\) return;[^]*?requestVideoFrameCallback/);
  assert.match(appSource, /installedVideoPlayer\.onseeked = \(\) => \{[\s\S]+completeInstalledVideoSynchronization\(session[\s\S]+observeInstalledVideoFirstFrame\(session\.trackID\)/);
  assert.match(appSource, /dialog\.classList\.add\("video-expanded", "video-revealed"\);[\s\S]+showInstalledVideoControls\(\);[\s\S]+startInstalledVideoPlayback\(\);[\s\S]+animateInstalledVideoStage\(geometry\.source, geometry\.target/);
  assert.match(appSource, /function closeInstalledVideo\([^)]*\)[\s\S]+currentGeometry = installedVideoStageGeometry\(\)[\s\S]+classList\.add\("video-revealed", "video-closing"\)[\s\S]+syncFullPlayerTitleMarquee\(\)[\s\S]+animateInstalledVideoStage\(currentGeometry, geometry\.source[\s\S]+finishInstalledVideoClose/);
  assert.doesNotMatch(closeVideo, /audio\.pause\(\)|audio\.muted\s*=|audio\.currentTime\s*=/);
  assert.match(appSource, /installedVideoArtworkTimer = setTimeout\([\s\S]+classList\.add\("video-artwork-restored"\)[\s\S]+geometryDuration - installedVideoAnimationDuration\(INSTALLED_VIDEO_EXIT_ARTWORK_LEAD_MS\)/);
  assert.match(appSource, /function advanceInstalledVideo\(direction = 1\)[\s\S]+nextIndex\(tracks, currentID, direction\)[\s\S]+selectInstalledVideoTarget/);
  assert.match(appSource, /installedVideoPlayer\.onended = handleInstalledVideoEnded/);
  assert.match(appSource, /function hideInstalledVideoControls\(\)[\s\S]+installed-video-return:focus-visible[\s\S]+#installedVideoControls :focus-visible[\s\S]+classList\.remove\("video-controls-visible"\)/);
  assert.match(appSource, /installedVideoStage\.onpointermove = \(\) => showInstalledVideoControls\(\)[\s\S]+installedVideoControls\.onpointerenter = \(\) => showInstalledVideoControls\(\)/);
  assert.doesNotMatch(appSource, /installedVideoControls\.onpointerenter = \(\) => showInstalledVideoControls\(\{ keepVisible: true \}\)/);
  assert.match(appSource, /function setPlaybackVolume\([\s\S]+audio\.volume = gain[\s\S]+installedVideoPlayer\.muted = true[\s\S]+installedVideoPlayer\.volume = 0[\s\S]+installedVideoVolume/);
  assert.match(appSource, /function toggleInstalledVideoPlayback\(\)[\s\S]+toggle\(\);[\s\S]+synchronizeInstalledVideoWithAudio\(\)/);
  assert.doesNotMatch(appSource, /function handleInstalledVideoEnded\(\) \{\s+synchronizeInstalledVideoWithAudio/);
  assert.match(styleSource, /\.full-player-dialog\.video-active \.full-player-details[\s\S]+opacity: 0/);
  assert.doesNotMatch(styleSource, /\.installed-video-dialog\.video-from-art \.installed-video-stage/);
  assert.match(styleSource, /\.installed-video-stage\s*\{[\s\S]+transform: none[\s\S]+will-change: auto[\s\S]+transition: none/);
  assert.match(styleSource, /\.installed-video-stage\.video-geometry-animating\s*\{[\s\S]+will-change: transform, border-radius/);
  assert.match(styleSource, /\.full-player-dialog\.video-active \.full-player-backdrop,[\s\S]+\.full-player-dialog\.video-active \.full-player-shade[\s\S]+visibility: hidden/);
  assert.match(styleSource, /\.installed-video-stage\s*\{[\s\S]+inset: clamp\(12px, 3\.4vw, 38px\)[\s\S]+width: auto[\s\S]+height: auto/);
  assert.match(styleSource, /\.installed-video-dialog\.video-revealed \.installed-video-stage video[\s\S]+opacity: 1/);
  assert.match(styleSource, /video-revealed:not\(\.video-frame-ready\):not\(\.video-artwork-restored\)[\s\S]+installed-video-loading-spin/);
  assert.match(styleSource, /\.installed-video-artwork,[\s\S]+\.installed-video-stage video[\s\S]+transition: opacity 140ms ease/);
  assert.match(styleSource, /\.installed-video-dialog\.video-revealed\.video-artwork-restored \.installed-video-stage video[\s\S]+opacity: 0[\s\S]+\.installed-video-dialog\.video-revealed\.video-artwork-restored \.installed-video-artwork[\s\S]+opacity: 1/);
  assert.match(styleSource, /\.installed-video-stage video\s*\{[\s\S]*?object-fit: contain;[\s\S]*?object-position: center;/);
  assert.match(styleSource, /\.installed-video-controls\s*\{[\s\S]+bottom: 0[\s\S]+opacity: 0[\s\S]+pointer-events: none/);
  assert.match(styleSource, /\.installed-video-dialog\.video-revealed\.video-controls-visible \.installed-video-controls[\s\S]+\.installed-video-dialog\.video-revealed\.video-paused \.installed-video-controls[\s\S]+opacity: 1[\s\S]+pointer-events: auto/);
  assert.match(styleSource, /video-revealed\.video-controls-visible \.installed-video-return[\s\S]+video-revealed\.video-paused \.installed-video-return/);
  assert.match(styleSource, /video-revealed\.video-controls-visible \.installed-video-window-actions[\s\S]+video-revealed\.video-paused \.installed-video-window-actions/);
  assert.doesNotMatch(styleSource, /\.installed-video-controls:focus-within/);
});

test("renders the Clerk account name and picture without local profile controls", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.match(htmlSource, /id="profileMenuName"[\s\S]+id="profileMenuEmail"/);
  assert.match(appSource, /safeAccountDisplayName\(accountSession\)/);
  assert.match(appSource, /accountSession\?\.imageURL/);
  assert.match(appSource, /profileMenuManage"\)\.onclick = \(\) => openSettings\("server"\)/);
  assert.match(appSource, /function displayedAccountEmail[\s\S]+••••••@••••••\.•••/);
  assert.match(appSource, /#profileMenuEmail"\)\.onclick = \(event\) =>[\s\S]+isAccountEmailRevealed/);
  assert.match(appSource, /id="settingsAccountEmail"[\s\S]+displayedAccountEmail\(\)/);
  assert.doesNotMatch(appSource, /Signed in as \$\{accountSession\.email\}/);
  assert.doesNotMatch(htmlSource, /id="profileSwitchDialog"|Choose profile picture|Remove profile picture/);
  assert.doesNotMatch(appSource, /api\.chooseProfilePicture|api\.removeProfilePicture/);
  assert.match(appSource, /class="clerk-sign-in-button"[\s\S]+Sign in with Clerk/);
  assert.match(styleSource, /\.clerk-sign-in-button\s*\{[\s\S]+var\(--action-background\)/);
  const accountCardStyles = styleSource.slice(
    styleSource.indexOf(".settings-account-card {"),
    styleSource.indexOf("/* Cinematic cross-platform clip editor."),
  );
  assert.match(accountCardStyles, /\.settings-account-card\s*\{[\s\S]*?width: 100%;[\s\S]*?min-width: 0;/);
  assert.match(accountCardStyles, /> div:first-child[^}]+flex: 1 1 0;[^}]+min-width: 0;/);
  assert.match(accountCardStyles, /\.settings-auth-grid\s*\{[\s\S]*?flex: 0 1 220px;[\s\S]*?width: min\(220px, 100%\);[\s\S]*?min-width: 0;[\s\S]*?max-width: 220px;/);
  assert.match(accountCardStyles, /\.clerk-sign-in-button\s*\{[\s\S]*?width: 100%;[\s\S]*?min-width: 0;[\s\S]*?max-width: 100%;/);
});

test("classifies remote video as download-required without confusing audio MP4", () => {
  assert.equal(serverSongRequiresDownload({ media_kind: "video" }), true);
  assert.equal(serverSongRequiresDownload({ media_kind: "audio", source_url: "https://example.com/watch" }), false);
  assert.equal(serverSongRequiresDownload({ content_type: "video/mp4", filename: "clip.bin" }), true);
  assert.equal(serverSongRequiresDownload({ filename: "clip.WEBM" }), true);
  assert.equal(serverSongRequiresDownload({ content_type: "audio/mp4", filename: "song.m4a" }), false);
  assert.equal(serverSongRequiresDownload({ content_type: "audio/mpeg", filename: "song.mp3" }), false);
});

test("uses honest on-device states instead of URL pathnames for saved links", () => {
  assert.deepEqual(serverSourceDisplayFallback("https://www.youtube.com/watch?v=example"), {
    title: "Resolving metadata…",
    artist: "Automatic lookup",
    album: "Link only",
  });
  assert.deepEqual(serverSourceDisplayFallback("https://www.youtube.com/watch?v=example", { failed: true }), {
    title: "Resolving metadata…",
    artist: "Automatic lookup",
    album: "Link only",
  });
  assert.equal(serverSourceNeedsOriginalPage("https://rr1.example.googlevideo.com/videoplayback?expire=1"), true);
  assert.deepEqual(serverSourceDisplayFallback("https://rr1.example.googlevideo.com/videoplayback?expire=1"), {
    title: "Original source link needed",
    artist: "Re-import on the original device",
    album: "Legacy expired link",
  });
});

test("keeps a bounded fresh device-only server metadata cache", () => {
  const now = Date.now();
  const sourceURL = "https://www.youtube.com/watch?v=jNQXAC9IVRw";
  const key = remoteSongMetadataCacheKey(sourceURL, "video");
  const cache = normalizedRemoteSongMetadataCache({
    arbitraryInputKey: {
      sourceURL,
      mediaKind: "video",
      title: "  Me at the zoo  ",
      artist: "jawed",
      album: null,
      duration: 19,
      artworkURL: "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg",
      cachedAt: new Date(now - 1_000).toISOString(),
    },
    expired: {
      sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      mediaKind: "audio",
      title: "Expired",
      artist: "Expired",
      cachedAt: new Date(now - 31 * 24 * 60 * 60 * 1_000).toISOString(),
    },
  }, now);
  assert.deepEqual(Object.keys(cache), [key]);
  assert.equal(cache[key].title, "Me at the zoo");
  assert.equal(cache[key].duration, 19);
  assert.equal(cache[key].mediaKind, "video");
});

test("refreshes downloaded metadata without changing playback or source provenance", () => {
  const track = {
    id: "downloaded",
    title: "Old title",
    artist: "Old artist",
    album: "Old album",
    duration: 217,
    artwork: "old-artwork",
    artworkURL: "https://example.com/old.jpg",
    filePath: "C:\\Resonance\\ServerCache\\song.m4a",
    available: true,
    remoteID: "remote",
    sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
    sourceIdentity: { sourcePageURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw" },
    contentSha256: "hash",
  };
  const refreshed = applyDownloadedSongMetadataRefresh(track, {
    title: " Fresh title ",
    artist: "Fresh artist",
    album: "Fresh album",
    duration: 999,
    artworkURL: "https://i.ytimg.com/vi/jNQXAC9IVRw/maxresdefault.jpg",
  }, "fresh-artwork");

  assert.equal(refreshed.title, "Fresh title");
  assert.equal(refreshed.artist, "Fresh artist");
  assert.equal(refreshed.album, "Fresh album");
  assert.equal(refreshed.artwork, "fresh-artwork");
  assert.equal(refreshed.duration, 217);
  assert.equal(refreshed.sourceIdentity, track.sourceIdentity);
  assert.equal(refreshed.contentSha256, "hash");
  assert.equal(downloadedSongMetadataRefreshSource(track), track.sourceURL);
  assert.equal(downloadedSongMetadataRefreshSource({ ...track, available: false }), null);
});

test("uses lightweight batched Windows metadata hydration and mac-like song skeletons", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const handler = mainSource.slice(
    mainSource.indexOf('ipcMain.handle("server:source-metadata"'),
    mainSource.indexOf('ipcMain.handle("local-import:start-external"'),
  );
  assert.match(handler, /resolveLocalImportMetadata\(source, signal/);
  assert.doesNotMatch(handler, /resolveLocalImportSource|searchYouTubeAudioSources/);
  assert.match(appSource, /Array\.from\(\{ length: 7 \}/);
  assert.match(appSource, /server-metadata-title[\s\S]+server-metadata-subtitle/);
  assert.match(appSource, /Math\.min\(4, queue\.length\)/);
  assert.match(appSource, /bufferedResults\.length >= 4/);
  assert.match(appSource, /SERVER_METADATA_RETRY_DELAYS_MS = \[400, 1600\]/);
  assert.match(appSource, /resolveServerMetadataWithRetry/);
  assert.match(appSource, /retryPendingServerCatalogMetadata/);
  assert.doesNotMatch(appSource, /Metadata unavailable|Refresh to retry/);
  assert.match(styleSource, /\.server-metadata-title\s*\{ width: 148px; height: 11px; \}/);
  assert.match(styleSource, /\.server-metadata-artwork \.server-artwork-placeholder[\s\S]+border-top-color/);
});

test("requires explicit review before selecting metadata-only audio matches", () => {
  assert.equal(localImportCandidateCanAutoSelect({ confidence: "direct" }), true);
  assert.equal(localImportCandidateCanAutoSelect({ requiresReview: true }), false);
  assert.equal(localImportCandidateCanAutoSelect({ requires_review: true }), false);
  assert.equal(localImportCandidateCanAutoSelect({ autoSelectable: false }), false);
  assert.equal(localImportCandidateCanAutoSelect({ auto_selectable: false }), false);
  assert.equal(localImportCandidateCanAutoSelect({ actionable: false }), false);
  assert.equal(localImportCandidateCanAutoSelect(null), false);

  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  assert.match(appSource, /localImportCandidateCanAutoSelect\(candidate\) \? "checked" : ""/);
  assert.doesNotMatch(appSource, /localImportResolution\.candidates\[Number\(selected\?\.value\) \|\| 0\]/);
});

test("deduplicates playlist transfers while preserving independent row selection", async () => {
  const selectedRows = [
    { videoID: "jNQXAC9IVRw", sourceProvider: "youtube", sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw" },
    { videoID: "jNQXAC9IVRw", sourceProvider: "youtube", sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw" },
    { videoID: "9bZkp7q19f0", sourceProvider: "youtube", sourceURL: "https://www.youtube.com/watch?v=9bZkp7q19f0" },
  ];
  const transferQueue = uniqueLocalImportPlaylistCandidates(selectedRows, "audio");
  const calls = [];
  const startLocalImport = async (candidate) => {
    calls.push(candidate.videoID);
    if (candidate.videoID === "jNQXAC9IVRw") throw new Error("deterministic transfer failure");
    return { ok: true };
  };
  for (const candidate of transferQueue) {
    try { await startLocalImport(candidate); } catch { /* one unique failure is enough */ }
  }
  assert.equal(selectedRows.length, 3);
  assert.deepEqual(transferQueue.map((candidate) => candidate.videoID), ["jNQXAC9IVRw", "9bZkp7q19f0"]);
  assert.deepEqual(calls, ["jNQXAC9IVRw", "9bZkp7q19f0"]);
  assert.equal(localImportPlaylistTransferKey(selectedRows[0]), localImportPlaylistTransferKey(selectedRows[1]));
  assert.notEqual(localImportPlaylistTransferKey(selectedRows[0]), localImportPlaylistTransferKey(selectedRows[2]));
});

test("keeps distinct provider playlist rows with the same YouTube fallback", () => {
  const selectedRows = [
    {
      videoID: "jNQXAC9IVRw",
      sourceProvider: "youtube",
      sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
      importMetadata: {
        provider: "spotify",
        trackID: "spotify-track-a",
        sourceURL: "https://open.spotify.com/track/spotify-track-a",
      },
      fallbackCandidates: [{ videoID: "dQw4w9WgXcQ" }],
    },
    {
      videoID: "jNQXAC9IVRw",
      sourceProvider: "youtube",
      sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
      importMetadata: {
        provider: "spotify",
        trackID: "spotify-track-b",
        sourceURL: "https://open.spotify.com/track/spotify-track-b",
      },
      fallbackCandidates: [{ videoID: "9bZkp7q19f0" }],
    },
    {
      videoID: "jNQXAC9IVRw",
      sourceProvider: "youtube",
      sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
      importMetadata: {
        provider: "soundcloud",
        trackID: "soundcloud-track-c",
        sourceURL: "https://soundcloud.com/artist/track-c",
      },
      fallbackCandidates: [{ videoID: "LIIDh-qI9oI" }],
    },
  ];
  const transferQueue = uniqueLocalImportPlaylistCandidates(selectedRows, "audio");
  assert.equal(transferQueue.length, 3);
  assert.deepEqual(transferQueue.map((candidate) => candidate.importMetadata.trackID), [
    "spotify-track-a",
    "spotify-track-b",
    "soundcloud-track-c",
  ]);
  assert.notEqual(localImportPlaylistTransferKey(selectedRows[0]), localImportPlaylistTransferKey(selectedRows[1]));
  assert.notEqual(localImportPlaylistTransferKey(selectedRows[1]), localImportPlaylistTransferKey(selectedRows[2]));
});

test("rejects stale link-import operations after source, media, or selection mutation", () => {
  const snapshot = {
    generation: 4,
    fingerprint: localImportOperationFingerprint({ source: "A", mediaKind: "audio", selection: [0] }),
  };
  assert.equal(localImportOperationIsCurrent(snapshot, { ...snapshot }), true);
  assert.equal(localImportOperationIsCurrent(snapshot, {
    generation: 5,
    fingerprint: localImportOperationFingerprint({ source: "B", mediaKind: "audio", selection: [0] }),
  }), false);
  assert.equal(localImportOperationIsCurrent(snapshot, {
    generation: 5,
    fingerprint: localImportOperationFingerprint({ source: "A", mediaKind: "audio", selection: [1] }),
  }), false);
  assert.equal(localImportOperationIsCurrent(snapshot, {
    generation: 4,
    fingerprint: localImportOperationFingerprint({ source: "A", mediaKind: "video", selection: [0] }),
  }), false);
  assert.notEqual(
    localImportOperationFingerprint({ source: "A", mediaKind: "audio", selection: [0], uploadRequested: false }),
    localImportOperationFingerprint({ source: "A", mediaKind: "audio", selection: [0], uploadRequested: true }),
  );
});

test("keeps metadata provenance separate from matched media aliases", () => {
  const identity = buildLocalImportSourceIdentity({
    sourceProvider: "youtube",
    videoID: "yt-video",
    sourceURL: "https://www.youtube.com/watch?v=yt-video",
    confidence: "possible",
    score: 0.89,
    evidenceStrength: "metadata_only",
    requiresReview: true,
    actionable: false,
    match: { title: 1, artist: 0.9, durationDeltaSeconds: 1 },
  }, {
    provider: "spotify",
    trackID: "spotify-track",
    sourceURL: "https://open.spotify.com/track/spotify-track",
  });
  assert.equal(identity.provider, "spotify");
  assert.equal(identity.providerID, "spotify-track");
  assert.equal(identity.sourcePageURL, "https://open.spotify.com/track/spotify-track");
  assert.equal(identity.aliases[0].provider, "youtube");
  assert.equal(identity.aliases[0].providerID, "yt-video");
  assert.equal(identity.evidence.matchedMediaProviderID, "yt-video");

  const debrid = buildLocalImportSourceIdentity({
    sourceProvider: "debrid_vault",
    candidateID: "debrid:info-hash",
    sourceURL: "magnet:?xt=urn:btih:info-hash",
  }, {
    provider: "spotify",
    trackID: "spotify-track",
    sourceURL: "https://open.spotify.com/track/spotify-track",
  });
  assert.equal(debrid.aliases[0].providerID, "debrid:info-hash");

  const track = { id: "local", sourceIdentity: identity, sourceIdentities: [identity] };
  const soundCloud = {
    provider: "soundcloud",
    providerID: "soundcloud-track",
    sourcePageURL: "https://soundcloud.com/artist/track",
  };
  assert.equal(mergeTrackSourceIdentity(track, soundCloud), true);
  assert.deepEqual(track.sourceIdentities.map((item) => item.provider), ["spotify", "youtube", "soundcloud"]);
  assert.equal(mergeTrackSourceIdentity(track, soundCloud), false);
  const enrichedSoundCloud = {
    ...soundCloud,
    confidence: "fingerprint-and-metadata",
    score: 0.98,
    evidence: { fingerprintDistance: 0.01, durationMatched: true },
  };
  assert.equal(mergeTrackSourceIdentity(track, enrichedSoundCloud), true);
  const storedSoundCloud = track.sourceIdentities.find((item) => item.provider === "soundcloud");
  assert.equal(storedSoundCloud.confidence, "fingerprint-and-metadata");
  assert.equal(storedSoundCloud.score, 0.98);
  assert.deepEqual(storedSoundCloud.evidence, { fingerprintDistance: 0.01, durationMatched: true });
  assert.equal(mergeTrackSourceIdentity(track, enrichedSoundCloud), false);
  for (let index = 0; index < 12; index += 1) {
    mergeTrackSourceIdentity(track, { provider: "provider", providerID: `alias-${index}` });
  }
  assert.equal(track.sourceIdentities.length, 8);
});

test("accepts both managed library folders for batch uploads", () => {
  const root = path.resolve("managed-library-test");
  const local = path.join(root, "LocalMusic");
  const remote = path.join(root, "ServerCache");

  assert.equal(isManagedLibraryFile(path.join(local, "local.m4a"), [local, remote]), true);
  assert.equal(isManagedLibraryFile(path.join(remote, "downloaded.m4a"), [local, remote]), true);
  assert.equal(isManagedLibraryFile(path.join(remote, "nested", "downloaded.m4a"), [local, remote]), true);
  assert.equal(isManagedLibraryFile(remote, [local, remote]), false);
  assert.equal(isManagedLibraryFile(path.join(root, "outside.m4a"), [local, remote]), false);
  assert.equal(isManagedLibraryFile(path.join(root, "ServerCache-backup", "outside.m4a"), [local, remote]), false);
});

test("requires only upload credentials and ignores unrelated synchronization activity", () => {
  assert.equal(serverUploadConfigurationError({
    serverURL: "https://music.example",
    adminToken: "admin-key",
    accessToken: "",
  }), null);
  assert.match(serverUploadConfigurationError({ serverURL: "", adminToken: "admin-key" }), /server URL/);
  assert.match(serverUploadConfigurationError({ serverURL: "ftp://music.example", adminToken: "admin-key" }), /server URL/);
  assert.match(serverUploadConfigurationError({ serverURL: "https://music.example", adminToken: "" }), /Resonance account/);
  assert.equal(serverUploadBlockedByActivity({
    playlistSyncInFlight: true,
    catalogRefreshInFlight: true,
    profileSyncInFlight: true,
    likesSyncInFlight: true,
    listeningHistorySyncInFlight: true,
  }), false);
  assert.equal(serverUploadBlockedByActivity({ uploadInFlight: true }), true);
  assert.equal(serverUploadBlockedByActivity({ transferActive: true }), true);
});

test("keeps fresh-install local-only imports independent of server context", () => {
  assert.equal(localImportNeedsServerContext({ serverBacked: false, uploadRequested: false }), false);
  assert.equal(localImportNeedsServerContext({ serverBacked: false, uploadRequested: true }), true);
  assert.equal(localImportNeedsServerContext({ serverBacked: true, uploadRequested: false }), true);
});

test("merges upload responses into the cached catalog without waiting for a refresh", () => {
  const original = [{ id: "existing", title: "Old title" }];
  assert.deepEqual(mergeUploadedSongsIntoCatalog(original, [
    { remoteSong: { id: "existing", title: "Updated title" } },
    { remoteSong: { id: "new", title: "New song" } },
    { remoteSong: null },
  ]), [
    { id: "existing", title: "Updated title" },
    { id: "new", title: "New song" },
  ]);
  assert.deepEqual(original, [{ id: "existing", title: "Old title" }]);
});

test("trusts a cached remote ID only for the exact active server and profile", () => {
  const context = { serverURL: "https://music.example/library", profileID: "profile-a" };
  assert.equal(serverTrackRemoteIDBelongsToContext({
    remoteID: "song-id",
    sourceServer: "https://music.example",
    syncProfileID: "profile-a",
  }, context), true);
  assert.equal(serverTrackRemoteIDBelongsToContext({
    remoteID: "song-id",
    sourceServer: "https://other.example",
    syncProfileID: "profile-a",
  }, context), false);
  assert.equal(serverTrackRemoteIDBelongsToContext({
    remoteID: "song-id",
    sourceServer: "https://music.example",
    syncProfileID: "profile-b",
  }, context), false);
  assert.equal(serverTrackRemoteIDBelongsToContext({ remoteID: "song-id" }, context), false);
});

test("refuses to overwrite a track association from another server or profile", () => {
  const state = createEmptyState();
  const track = {
    id: "linked",
    remoteID: "song-a",
    sourceServer: "https://one.example",
    syncProfileID: "profile-a",
  };
  state.tracks = [track];

  assert.equal(remoteAssociationConflictMessage(track, {
    serverURL: "https://one.example/library",
    profileID: "profile-a",
  }), null);
  assert.match(remoteAssociationConflictMessage(track, {
    serverURL: "https://one.example",
    profileID: "profile-b",
  }), /different server or profile/);
  assert.match(remoteAssociationConflictMessage(track, {
    serverURL: "https://two.example",
    profileID: "profile-a",
  }), /existing link unchanged/);
  assert.match(remoteAssociationConflictMessage({ ...track, sourceServer: null }, {
    serverURL: "https://one.example",
    profileID: "profile-a",
  }), /different server or profile/);

  const partialAssociation = {
    id: "partial",
    remoteID: null,
    sourceServer: "https://one.example",
    syncProfileID: "profile-a",
  };
  assert.equal(remoteAssociationConflictMessage(partialAssociation, {
    serverURL: "https://one.example",
    profileID: "profile-a",
  }), null);
  assert.match(remoteAssociationConflictMessage(partialAssociation, {
    serverURL: "https://two.example",
    profileID: "profile-a",
  }), /different server or profile/);
  assert.match(remoteAssociationConflictMessage({ id: "profile-only", syncProfileID: "profile-a" }, {
    serverURL: "https://one.example",
    profileID: "profile-a",
  }), /different server or profile/);

  assert.throws(() => reconcileUploadedTrack(state, track.id, { id: "song-b" }, {
    serverURL: "https://two.example",
    profileID: "profile-a",
  }), /different server or profile/);
  assert.deepEqual(state.tracks, [track]);
  assert.equal(track.remoteID, "song-a");
  assert.equal(track.sourceServer, "https://one.example");
  assert.equal(track.syncProfileID, "profile-a");

  state.tracks.push(partialAssociation);
  assert.throws(() => reconcileUploadedTrack(state, partialAssociation.id, { id: "song-b" }, {
    serverURL: "https://two.example",
    profileID: "profile-a",
  }), /different server or profile/);
  assert.equal(partialAssociation.remoteID, null);
  assert.equal(partialAssociation.sourceServer, "https://one.example");

  assert.deepEqual(remoteAssociationConflictFilePaths([
    track,
    { id: "local", filePath: "C:\\Music\\Local.mp3" },
    {
      id: "same-context",
      filePath: "C:\\Music\\Same.mp3",
      remoteID: "song-c",
      sourceServer: "https://two.example",
      syncProfileID: "profile-a",
    },
    { ...track, filePath: "C:\\Music\\Linked.mp3" },
  ], {
    serverURL: "https://two.example",
    profileID: "profile-a",
  }), ["C:\\Music\\Linked.mp3"]);

  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const manualUploadSource = appSource.slice(
    appSource.indexOf("async function uploadServerSongs"),
    appSource.indexOf("async function uploadMissingDownloadedSongs"),
  );
  const nativeUploadSource = mainSource.slice(
    mainSource.indexOf('ipcMain.handle("server:upload"'),
    mainSource.indexOf('ipcMain.handle("server:cancel-transfer"'),
  );
  assert.match(manualUploadSource, /associationConflictPaths: remoteAssociationConflictFilePaths\(state\.tracks, context\)/);
  assert.ok(nativeUploadSource.indexOf("normalizedAssociationConflictPaths.has") >= 0);
  assert.ok(nativeUploadSource.indexOf("normalizedAssociationConflictPaths.has") < nativeUploadSource.indexOf("beginServerTransfer(event)"));
});

test("rejects stale same-context catalog responses after an upload mutates the catalog", () => {
  assert.equal(catalogRequestCanApply({
    requestGeneration: 4,
    currentGeneration: 4,
    contextCurrent: true,
  }), true);
  assert.equal(catalogRequestCanApply({
    requestGeneration: 4,
    currentGeneration: 5,
    contextCurrent: true,
  }), false);
  assert.equal(catalogRequestCanApply({
    requestGeneration: 4,
    currentGeneration: 4,
    contextCurrent: false,
  }), false);
});

test("catalog authority is scoped to the exact catalog generation, server, profile, and token", () => {
  const context = {
    generation: 7,
    profileID: "profile-a",
    serverKey: "https://music.example/",
    token: "token-a",
  };
  const authority = serverCatalogAuthoritySnapshot(context, 11);
  assert.equal(serverCatalogAuthorityIsCurrent(authority, context, 11), true);
  assert.equal(serverCatalogAuthorityIsCurrent(authority, { ...context, generation: 8 }, 11), false);
  assert.equal(serverCatalogAuthorityIsCurrent(authority, { ...context, profileID: "profile-b" }, 11), false);
  assert.equal(serverCatalogAuthorityIsCurrent(authority, { ...context, serverKey: "https://other.example/" }, 11), false);
  assert.equal(serverCatalogAuthorityIsCurrent(authority, { ...context, token: "token-b" }, 11), false);
  assert.equal(serverCatalogAuthorityIsCurrent(authority, context, 12), false);
  assert.equal(serverCatalogAuthorityIsCurrent(null, context, 11), false);
});

test("moves fullscreen titles only by their rendered overflow", () => {
  assert.deepEqual(titleMarqueeMetrics(420, 500), { travel: 0, cycleDistance: 0, durationSeconds: 0 });
  assert.deepEqual(titleMarqueeMetrics(820, 540), { travel: 280, cycleDistance: 876, durationSeconds: 876 / 28 });
  assert.deepEqual(titleMarqueeMetrics(568, 540), { travel: 28, cycleDistance: 624, durationSeconds: 624 / 28 });
});

test("maps the volume slider to a clamped perceptual playback curve", () => {
  assert.equal(playbackGainForVolume(-.5), 0);
  assert.equal(playbackGainForVolume(.25), .0625);
  assert.equal(playbackGainForVolume(.5), .25);
  assert.equal(playbackGainForVolume(.75), .5625);
  assert.equal(playbackGainForVolume(1), 1);
  assert.equal(playbackGainForVolume(2), 1);
  assert.equal(playbackGainForVolume(Number.NaN), 0);
});

test("matches mobile square artwork cropping and removes symmetric borders", () => {
  const pixels = (width, height, horizontalBorder = 0, verticalBorder = 0) => {
    const result = new Uint8ClampedArray(width * height * 4);
    for (let y = 0; y < height; y += 1) {
      for (let x = 0; x < width; x += 1) {
        const offset = (y * width + x) * 4;
        const isBorder = x < horizontalBorder || x >= width - horizontalBorder
          || y < verticalBorder || y >= height - verticalBorder;
        result[offset] = isBorder ? 8 : 32 + (x * 17 + y * 3) % 190;
        result[offset + 1] = isBorder ? 8 : 32 + (x * 5 + y * 19) % 190;
        result[offset + 2] = isBorder ? 8 : 32 + (x * 11 + y * 7) % 190;
        result[offset + 3] = 255;
      }
    }
    return result;
  };

  assert.deepEqual(squareArtworkCropRect(pixels(12, 12), 12, 12), { x: 0, y: 0, width: 12, height: 12 });
  assert.deepEqual(squareArtworkCropRect(pixels(16, 12), 16, 12), { x: 2, y: 0, width: 12, height: 12 });
  assert.deepEqual(squareArtworkCropRect(pixels(16, 12, 2), 16, 12), { x: 2, y: 0, width: 12, height: 12 });
  assert.deepEqual(squareArtworkCropRect(pixels(12, 16, 0, 2), 12, 16), { x: 0, y: 2, width: 12, height: 12 });
  assert.deepEqual(squareArtworkCropRect(pixels(16, 12, 0, 2), 16, 12), { x: 4, y: 2, width: 8, height: 8 });
});

test("quits the Windows client when its only preview window closes", () => {
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  assert.match(mainSource, /app\.on\("window-all-closed", \(\) => app\.quit\(\)\)/);
  assert.doesNotMatch(mainSource, /window-all-closed[\s\S]{0,100}process\.platform !== "darwin"/);
});

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
  assert.match(htmlSource, /img-src[^"]*https:/);
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

test("renders every Windows select through the themed custom dropdown", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  const staticCustomControls = htmlSource.match(/<div\b[^>]*\bdata-custom-select\b[^>]*>/gi) || [];
  const settingsCustomControls = appSource.match(/<div\b[^>]*\bdata-custom-select\b[^>]*>/gi) || [];

  assert.doesNotMatch(htmlSource, /<select\b/i);
  assert.doesNotMatch(appSource, /<select\b/i);
  assert.equal(staticCustomControls.length + settingsCustomControls.length, 4);
  assert.doesNotMatch(appSource, /id="serverUploadMode"|id="serverDownloadMode"/);
  assert.match(appSource, /function initializeCustomSelects\(\)[\s\S]+querySelectorAll\("\[data-custom-select\]"\)/);
  assert.doesNotMatch(appSource, /#serverSettingsForm \[data-custom-select\]/);
  assert.match(appSource, /function setCustomSelectOptions\(/);
  assert.match(appSource, /role\", \"listbox/);
  assert.match(appSource, /role\", \"option/);
  assert.match(appSource, /root\.dispatchEvent\(new Event\("change"/);
  assert.match(appSource, /const openDialog = controller\.root\.closest\("dialog\[open\]"\)[\s\S]+openDialog\.append\(controller\.menu\)/);
  assert.match(appSource, /controller\.menu\.parentElement !== controller\.root[\s\S]+controller\.root\.append\(controller\.menu\)/);
  assert.match(appSource, /!controller\.root\.contains\(event\.target\) && !controller\.menu\.contains\(event\.target\)/);
  assert.doesNotMatch(appSource, /MutationObserver/);
  assert.match(styleSource, /\.resonance-select-menu\s*\{/);
  assert.match(styleSource, /\.resonance-select-menu\.dialog-contained\s*\{\s*position: absolute/);
  assert.match(styleSource, /\.resonance-select-option\.selected\s*\{/);
  assert.doesNotMatch(styleSource, /\.resonance-select-native\s*\{/);
});

test("persists macOS credentials without system credential commands", () => {
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const retiredStorageName = ["Liked", " Songs"].join("");
  assert.doesNotMatch(mainSource, /\{ app, BrowserWindow, dialog, ipcMain, safeStorage, shell \}/);
  assert.match(mainSource, /function usesPreviewCredentialStore\(\)[\s\S]+return process\.platform === "darwin"/);
  assert.match(mainSource, /previewCredentialStorePath[\s\S]+app\.getPath\("userData"\), "server-credentials\.json"/);
  assert.match(mainSource, /previewAccountSessionPath[\s\S]+app\.getPath\("userData"\), "account-session\.json"/);
  assert.doesNotMatch(
    mainSource,
    new RegExp(String.raw`previewCredentialStorePath[\s\S]+"${retiredStorageName}", "server-credentials\.json"`),
  );
  assert.match(mainSource, /fs\.mkdir\(directory, \{ recursive: true, mode: 0o700 \}\)/);
  assert.match(mainSource, /fs\.chmod\(destination, 0o600\)/);
  assert.match(mainSource, /server:credentials:load[\s\S]+usesPreviewCredentialStore\(\)[\s\S]+readPreviewCredentials/);
  assert.match(mainSource, /function persistServerCredentials\(credentialsValue\)[\s\S]+usesPreviewCredentialStore\(\)[\s\S]+writePreviewCredentials/);
  assert.match(mainSource, /server:credentials:save[\s\S]+persistServerCredentials\(credentialsValue\)/);
  assert.match(mainSource, /function encryptedCredentialStorage\(\)[\s\S]+require\("electron"\)\.safeStorage/);
});

test("isolates and visibly names source Preview instances by Git worktree", () => {
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  assert.match(mainSource, /process\.env\.RESONANCE_WORKTREE_ID/);
  assert.match(mainSource, /process\.env\.RESONANCE_INSTANCE_NAME/);
  assert.match(mainSource, /app\.setPath\("userData"/);
  assert.match(mainSource, /"Resonance Worktrees"/);
  assert.match(mainSource, /title: resonanceApplicationName/);
  assert.match(mainSource, /page-title-updated/);
});

test("uploads link imports even when the selected source is already saved locally", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  assert.match(appSource, /function localImportUploadConfigurationError/);
  assert.match(appSource, /response\.result\.kind === "duplicate"[\s\S]+importedTrack = state\.tracks\.find[\s\S]+uploadImportedTrackWithMode\(/);
  assert.match(appSource, /!response\.result\.serverBacked && uploadRequested && importedTrack\?\.filePath\)/);
  assert.match(appSource, /scheduleServerCatalogRefresh/);
  assert.match(appSource, /Uploaded \$\{importedTrack\.title\}/);
  assert.doesNotMatch(appSource, /importedTrack\?\.filePath && response\.result\.kind === "created"/);
});

test("binds the active library to the signed-in Clerk account", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.doesNotMatch(htmlSource, /id="profileSwitchDialog"|profileSwitchQuery|createProfileFromSwitcher/);
  assert.doesNotMatch(appSource, /api\.createProfile|openProfileSwitcher|matchingSyncProfile/);
  assert.match(appSource, /profileID: activeProfileID\(\)/);
  assert.match(appSource, /accountSession\?\.profileID[\s\S]+await activateProfile\(accountSession\.profileID/);
  assert.doesNotMatch(appSource, /ACCOUNT & TRANSFERS|Clerk account selects the library/);
  assert.doesNotMatch(appSource, /id="syncProfile"|id="newSyncProfile"/);
  assert.match(appSource, /track\.id === currentID \? toggle\(\) : play\(track, tracks, \{ playlistID: null \}\)/);
  assert.match(appSource, /function updateProfileControl\(\)[\s\S]+control\.hidden = false/);
  for (const id of ["settingsServer", "settingsRefreshMetadata"]) {
    assert.match(appSource, new RegExp(`id="${id}"`));
  }
  assert.doesNotMatch(appSource, /id="settingsCheckUpdates"|id="checkForUpdates"/);
  assert.doesNotMatch(appSource, /Library & tools|data-settings-panel="tools"|id="settingsHistory"|id="settingsClipEditor"|id="settingsStorage"/);
  assert.match(htmlSource, /id="profileHistory"[\s\S]+id="profileClipEditor"/);
  assert.match(htmlSource, /data-section="storage"[\s\S]+Song Storage/);
  assert.doesNotMatch(appSource, /Under construction/);
  assert.match(htmlSource, /id="settingsDialog"[^>]+settings-dialog/);
  assert.match(appSource, /#profileSettings"\)\.onclick = \(\) =>[\s\S]+openSettings\(\)/);
  assert.doesNotMatch(appSource, /navigate\("settings"\)/);
  assert.doesNotMatch(appSource, /#profileSettings"\)\.onclick = [\s\S]{0,160}openServerSettings/);
  assert.doesNotMatch(htmlSource, /id="serverSettingsDialog"/);
  assert.match(appSource, /data-settings-panel="server"[\s\S]+<form id="serverSettingsForm"/);
  assert.match(appSource, /function openServerSettings\(\) \{\s+openSettings\("server"\)/);
  assert.match(appSource, /#settingsServer"\)\.onclick = openServerSettings/);
  assert.match(styleSource, /\.settings-grid\s*\{/);
});

test("normalizes and persists the four device-local Windows themes", () => {
  assert.deepEqual(APP_THEMES.map(({ id, label }) => ({ id, label })), [
    { id: "midnight", label: "Midnight" },
    { id: "ocean", label: "Ocean" },
    { id: "forest", label: "Forest" },
    { id: "sunset", label: "Sunset" },
  ]);
  for (const { id } of APP_THEMES) assert.equal(normalizedAppTheme(id), id);
  for (const invalid of [null, "", "violet", "MIDNIGHT", {}, 1]) {
    assert.equal(normalizedAppTheme(invalid), "midnight");
  }
  assert.equal(normalizedAppPreferences({}).theme, "midnight");
  assert.equal(normalizedAppPreferences({ theme: "forest" }).theme, "forest");
  assert.equal(normalizedAppPreferences({ theme: "unknown" }).theme, "midnight");

  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  assert.match(mainSource, /const DEFAULT_APP_THEME = "midnight"/);
  assert.match(mainSource, /APP_THEME_IDS = new Set\(\[DEFAULT_APP_THEME, "ocean", "forest", "sunset"\]\)/);
  assert.match(mainSource, /theme: typeof preferences\.theme === "string" && APP_THEME_IDS\.has\(preferences\.theme\)[\s\S]+DEFAULT_APP_THEME/);
  assert.match(mainSource, /appPreferences: safeAppPreferences\(state\.appPreferences\)/);
  assert.match(mainSource, /backgroundColor: "#05060a"/);
  assert.match(appSource, /function applyAppTheme\(value\)[\s\S]+document\.documentElement\.dataset\.theme = theme[\s\S]+cacheAppTheme\(theme\)/);
  assert.match(appSource, /state = normalizeState\(loadedState\);\s*state\.appPreferences\.theme = applyAppTheme\(state\.appPreferences\.theme\)/);
  assert.match(appSource, /data-settings-panel="general"[\s\S]+data-settings-panel="appearance"[\s\S]+data-settings-panel="server"/);
  assert.match(appSource, /data-settings-content="appearance"[^>]*>[\s\S]+<h2>Appearance<\/h2>[\s\S]+name="settingsTheme"[\s\S]+stored only on this device/);
  const generalPanel = appSource.slice(
    appSource.indexOf('data-settings-content="general"'),
    appSource.indexOf('data-settings-content="appearance"'),
  );
  assert.doesNotMatch(generalPanel, /settingsTheme|settings-theme-card/);
  assert.match(appSource, /APP_THEMES\.map\(\(theme\) => `<label class="settings-theme-card"[\s\S]+type="radio" name="settingsTheme"/);
  assert.match(appSource, /updateAppPreference\("theme", input\.value\)/);
  const themeHandlerStart = appSource.indexOf(`document.querySelectorAll('input[name="settingsTheme"]')`);
  const themeHandlerEnd = appSource.indexOf("const runInBackground", themeHandlerStart);
  assert.ok(themeHandlerStart >= 0 && themeHandlerEnd > themeHandlerStart);
  assert.doesNotMatch(appSource.slice(themeHandlerStart, themeHandlerEnd), /renderSettings\(\)/);
});

test("bootstraps the cached Windows theme before CSS without trusting arbitrary values", () => {
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const bootstrapSource = readFileSync(new URL("../ui/theme-bootstrap.js", import.meta.url), "utf8");
  const bootstrapIndex = htmlSource.indexOf('<script src="theme-bootstrap.js"></script>');
  const stylesheetIndex = htmlSource.indexOf('<link rel="stylesheet" href="styles.css">');
  assert.ok(bootstrapIndex >= 0 && bootstrapIndex < stylesheetIndex);
  assert.match(bootstrapSource, /const fallback = "midnight"/);
  assert.match(bootstrapSource, /new Set\(\[fallback, "ocean", "forest", "sunset"\]\)/);
  assert.match(bootstrapSource, /localStorage\.getItem\("resonance\.theme"\)/);
  assert.match(bootstrapSource, /if \(themes\.has\(cached\)\) theme = cached/);
  assert.match(bootstrapSource, /document\.documentElement\.dataset\.theme = theme/);
});

test("defines complete Windows palettes and routes major chrome through theme tokens", () => {
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  const shuffleSource = readFileSync(new URL("../ui/shuffle-icon.css", import.meta.url), "utf8");
  const webImportOverrides = styleSource.slice(styleSource.indexOf("/* Web import is a utility, so keep its presentation quiet and direct. */"));
  const palettes = {
    midnight: [
      ["background", "#020305"], ["base", "#05060a"], ["panel", "#0c0d13"],
      ["surface", "#0b0c12"], ["surface-raised", "#11131c"], ["accent", "#7547ff"],
      ["accent-secondary", "#6540f5"], ["accent-tertiary", "#9b82ff"],
      ["gradient-accent", "linear-gradient(135deg, #536bff 0%, #7547ff 50%, #8a42eb 100%)"],
      ["action-background", "linear-gradient(135deg, #536bff 0%, #7547ff 50%, #8a42eb 100%)"],
      ["gradient-artwork", "linear-gradient(145deg, #3349c9 0%, #6857ff 52%, #f18cb2 100%)"],
    ],
    ocean: [
      ["background", "#02070d"], ["panel", "#050d14"], ["surface", "#07121b"],
      ["surface-raised", "#0d1d2a"], ["accent", "#1769c2"], ["accent-secondary", "#0f5caa"],
      ["accent-tertiary", "#55b8ff"],
      ["action-background", "var(--accent-secondary)"],
      ["gradient-accent", "linear-gradient(135deg, #0f5caa 0%, #218bd6 50%, #62c3ff 100%)"],
    ],
    forest: [
      ["background", "#020805"], ["panel", "#050d09"], ["surface", "#07120c"],
      ["surface-raised", "#0d1d14"], ["accent", "#198754"], ["accent-secondary", "#126b43"],
      ["accent-tertiary", "#5fd49a"],
      ["action-background", "var(--accent-secondary)"],
      ["gradient-accent", "linear-gradient(135deg, #126b43 0%, #219c64 50%, #69d89e 100%)"],
    ],
    sunset: [
      ["background", "#0a0403"], ["panel", "#100706"], ["surface", "#150a07"],
      ["surface-raised", "#21120e"], ["accent", "#c45132"], ["accent-secondary", "#a33a53"],
      ["accent-tertiary", "#ff9a62"],
      ["action-background", "var(--accent-secondary)"],
      ["gradient-accent", "linear-gradient(135deg, #a33a53 0%, #d25b3f 50%, #ff9a62 100%)"],
    ],
  };
  for (const [theme, expected] of Object.entries(palettes)) {
    const block = styleSource.match(new RegExp(`:root\\[data-theme="${theme}"\\]\\s*\\{([\\s\\S]*?)\\n\\}`))?.[1] || "";
    assert.ok(block, `${theme} theme selector is missing`);
    for (const [token, value] of expected) {
      assert.ok(block.includes(`--${token}: ${value};`), `${theme} is missing --${token}`);
    }
  }
  const whiteContrast = (hex) => {
    const channels = hex.match(/[0-9a-f]{2}/gi).map((value) => Number.parseInt(value, 16) / 255);
    const linear = channels.map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    const luminance = (0.2126 * linear[0]) + (0.7152 * linear[1]) + (0.0722 * linear[2]);
    return 1.05 / (luminance + 0.05);
  };
  for (const [theme, actionColor] of Object.entries({ ocean: "#0f5caa", forest: "#126b43", sunset: "#a33a53" })) {
    assert.ok(whiteContrast(actionColor) >= 4.5, `${theme} action background must retain 4.5:1 white-text contrast`);
  }
  assert.match(styleSource, /@scope \(:root\[data-theme="ocean"\],[\s\S]+:root\[data-theme="sunset"\]\) \{/);
  assert.match(styleSource, /scrollbar-color: #7c57df #11131b/);
  assert.match(styleSource, /@scope[\s\S]+scrollbar-color: var\(--accent\) var\(--surface-raised\)/);
  assert.match(styleSource, /outline: 2px solid var\(--accent-tertiary\)/);
  assert.doesNotMatch(styleSource, /outline: 2px solid #b69cff/i);
  assert.match(styleSource, /\.sidebar\s*\{[\s\S]*?background: var\(--sidebar-background\)/);
  assert.match(styleSource, /\.settings-dialog,[\s\S]+background: var\(--dialog-background\)/);
  assert.match(shuffleSource, /\.playlist-dialog\s*\{[\s\S]+background: var\(--dialog-background\)/);
  assert.match(shuffleSource, /#installUpdate\s*\{[\s\S]+background: var\(--action-background\)/);
  assert.match(styleSource, /\.add-song-row > button\.added\s*\{[^}]*background: var\(--accent-soft\)/);
  assert.match(webImportOverrides, /\.local-import-provider-pill button\[aria-pressed="true"\]\s*\{[^}]*border-color: var\(--accent-tertiary\)[^}]*background: transparent[^}]*box-shadow: none/);
  assert.match(webImportOverrides, /\.local-import-media-kind input:checked \+ span\s*\{[^}]*background: #252832[^}]*box-shadow: none/);
  assert.match(webImportOverrides, /\.local-import-candidate:has\(input:checked\)\s*\{[^}]*background: var\(--accent-soft\)[^}]*box-shadow: none/);
  assert.match(webImportOverrides, /\.local-import-sync input:checked \+ \.local-import-sync-toggle\s*\{[^}]*box-shadow: none/);
  assert.match(webImportOverrides, /#confirmLocalImport\s*\{[^}]*background: var\(--action-background\)[^}]*box-shadow: none/);
  const chromeOverrides = styleSource.slice(styleSource.indexOf("/* Keep every non-content accent surface on the active app theme. */"));
  assert.match(chromeOverrides, /\.profile-menu-badge\s*\{[^}]*var\(--accent-border\)[^}]*var\(--accent-soft\)[^}]*var\(--accent-text\)/);
  assert.match(chromeOverrides, /\.player-track:focus-visible\s*\{[^}]*var\(--accent-tertiary\)[^}]*var\(--accent-soft\)/);
  assert.match(chromeOverrides, /\.history-mode button\.active\s*\{[^}]*var\(--accent-border\)[^}]*var\(--accent-soft\)[^}]*var\(--accent-text\)/);
  assert.match(chromeOverrides, /\.history-top-song-cover\[aria-expanded="true"\]\s*\{[^}]*var\(--accent-tertiary\)[^}]*var\(--accent-soft\)/);
  assert.match(chromeOverrides, /\.local-import-preview-button\.playing\s*\{[^}]*var\(--accent-tertiary\)[^}]*var\(--action-background\)[^}]*var\(--accent-glow\)/);
  assert.match(chromeOverrides, /\.clip-editor-save\s*\{[^}]*var\(--accent-border\)/);
  assert.match(styleSource, /\.clip-editor-handle span\s*\{[^}]*background: var\(--accent-secondary\)[^}]*var\(--accent-glow\)/);
  assert.match(styleSource, /\.clip-editor-handle\.dragging span\s*\{[^}]*background: var\(--accent\)[^}]*var\(--accent-soft\)[^}]*var\(--accent-glow\)/);
  assert.match(styleSource, /\.clip-editor-selection-summary input:focus\s*\{[^}]*var\(--accent-tertiary\)[^}]*var\(--accent-soft\)/);
  assert.doesNotMatch(styleSource, /#(?:6841f1|7751ff|7654ff2e|8f72ff55|8f72ff|7654ff24|b49eff)/i);
  assert.match(styleSource, /\.profile-button\s*\{[^}]*border: 1px solid #a58cff52[^}]*linear-gradient\(145deg, #6f3cff, #3a207d\)/);
  assert.match(styleSource, /\.filters button\.active\s*\{[^}]*background: var\(--gradient-accent\)[^}]*#ad96ff4d/);
  assert.match(styleSource, /\.settings-nav button\.active svg\s*\{[^}]*#9f82ff[^}]*#805aff/);
  assert.match(styleSource, /\.storage-import-option-icon\s*\{[^}]*var\(--accent-border\)[^}]*var\(--accent-soft\)[^}]*var\(--accent-text\)/);
  assert.match(styleSource, /\.segmented button\.active\s*\{[^}]*#845bff[^}]*#5c2ee8[^}]*color: #fff/);
  assert.match(styleSource, /\.history-bar\.peak\s*\{[^}]*fill: var\(--history-peak-color\)/);
  assert.match(webImportOverrides, /\.local-import-provider-pill\s*\{[^}]*position: static[^}]*border: 0[^}]*background: transparent[^}]*box-shadow: none/);
  assert.match(styleSource, /\.clip-editor-selection\s*\{[^}]*background: var\(--clip-selection-background\)/);
  assert.match(styleSource, /--history-bar-color: #7659d6;[\s\S]+--history-peak-color: #a98cff;[\s\S]+--clip-visualizer-low: #4e1a95/);
  assert.match(styleSource, /\.settings-theme-grid\s*\{[^}]*repeat\(2, minmax\(0, 1fr\)\)/);
  assert.match(styleSource, /\.settings-theme-card\s*\{[^}]*grid-template-rows: 92px auto/);
  const alternateChrome = styleSource.slice(styleSource.indexOf("@scope (:root[data-theme=\"ocean\"]"));
  assert.match(alternateChrome, /\.profile-button,[\s\S]+background: var\(--control-surface\)/);
  assert.match(alternateChrome, /\.filters button\.active,[\s\S]+background: var\(--accent-soft\)/);
  assert.match(alternateChrome, /\.settings-nav button\.active\s*\{[^}]*var\(--accent\)[^}]*var\(--accent-glow\)/);
  assert.match(alternateChrome, /\.segmented button\.active[^}]*var\(--accent-soft\)[^}]*var\(--accent-text\)/);
  assert.doesNotMatch(styleSource, /#(?:8f72ec40|7651dc35|b79cff|8175ae80|7d47dd|a75bf5|55319d|8c46e845)/i);
});

test("adds focused keybinds, Discord presence, close-to-tray settings, custom scrollbars, and no volume percentage", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const packageMetadata = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
  const preloadSource = readFileSync(new URL("../preload.cjs", import.meta.url), "utf8");
  const discordSource = readFileSync(new URL("../discord-rpc.cjs", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  const defaults = normalizedAppPreferences({});
  assert.equal(defaults.runInBackground, false);
  assert.equal(defaults.discordRichPresence, false);
  assert.equal(defaults.crossfadeEnabled, false);
  assert.equal(defaults.crossfadeSeconds, 5);
  assert.equal(Object.hasOwn(defaults, "discordApplicationID"), false);
  assert.equal(defaults.keybinds.togglePlayback, "Space");
  assert.deepEqual(normalizedAppPreferences({
    runInBackground: 1,
    discordRichPresence: "yes",
    keybinds: { togglePlayback: " Ctrl+K ", volumeUp: "" },
  }), {
    ...defaults,
    runInBackground: true,
    discordRichPresence: true,
    keybinds: { ...defaults.keybinds, togglePlayback: "Ctrl+K" },
  });
  assert.equal(normalizedCrossfadeSeconds(-2), 1);
  assert.equal(normalizedCrossfadeSeconds(30), 12);
  assert.equal(normalizedCrossfadeSeconds("nope"), 5);
  assert.equal(crossfadeProgress(2.5, 5), .5);
  assert.match(appSource, /id="settingsCrossfadeEnabled"[\s\S]+id="settingsCrossfadeSeconds"/);
  assert.match(appSource, /function prepareCrossfade\(track\)[\s\S]+crossfadeAudio\.play\(\)[\s\S]+function promoteCrossfade\(\)/);
  assert.match(htmlSource, /id="audio"[\s\S]+id="crossfadeAudio"/);
  assert.match(appSource, /id="settingsRunInBackground"[\s\S]+id="settingsDiscordPresence"/);
  assert.doesNotMatch(appSource, /settingsDiscordApplicationID|Paste the Resonance Application ID/);
  assert.match(appSource, /signed-in Discord profile/);
  assert.match(appSource, /data-keybind-action="\$\{action\}"/);
  assert.match(appSource, /function keybindFromKeyboardEvent\(event\)[\s\S]+settingsRecordingAction/);
  assert.match(preloadSource, /updateAppPreferences:[\s\S]+app:preferences:update/);
  assert.match(preloadSource, /updateDiscordPresence:[\s\S]+app:discord-presence:update/);
  assert.match(mainSource, /new DiscordRPCClient[\s\S]+discordRPC\.configure/);
  assert.match(mainSource, /applicationID: bundledDiscordApplicationID/);
  assert.equal(packageMetadata.resonanceDiscordApplicationID, "1535574125395841154");
  assert.doesNotMatch(discordSource, /botToken|Authorization|\bBot\s/);
  assert.match(mainSource, /runtimeAppPreferences\.runInBackground[\s\S]+window\.hide\(\)[\s\S]+ensureBackgroundTray\(\)/);
  assert.match(mainSource, /function safeAppPreferences\(value\)[\s\S]+crossfadeEnabled:[\s\S]+crossfadeSeconds:/);
  assert.match(mainSource, /new Tray[\s\S]+Open Resonance[\s\S]+Quit Resonance/);
  assert.match(styleSource, /\*::\-webkit-scrollbar[\s\S]+\*::\-webkit-scrollbar-thumb/);
  assert.doesNotMatch(htmlSource, /id="volumeText"/);
  assert.doesNotMatch(appSource, /#volumeText/);
});

test("clears Discord presence while paused and sends trusted album artwork", () => {
  const base = {
    title: "Night Drive",
    artist: "Resonance",
    album: "After Dark",
    position: 12,
    duration: 180,
    artworkURL: "https://i.scdn.co/image/cover",
  };
  assert.equal(sanitizeDiscordActivity({ ...base, playing: false }, 1_000), null);
  assert.deepEqual(sanitizeDiscordActivity({ ...base, playing: true }, 1_000), {
    type: 2,
    details: "Night Drive",
    state: "by Resonance",
    instance: false,
    timestamps: { start: 988, end: 1_168 },
    assets: {
      large_image: "https://i.scdn.co/image/cover",
    },
  });
  assert.equal(discordArtworkURL("https://attacker.example/cover.jpg"), null);
  assert.equal(
    discordArtworkURL("https://i.ytimg.com/vi/example/maxresdefault.jpg"),
    "https://img.youtube.com/vi/example/maxresdefault.jpg",
  );
  assert.equal(discordArtworkURL(`https://i.ytimg.com/${"x".repeat(301)}`), null);

  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  assert.match(appSource, /discordPresenceActivity\(\)[\s\S]+!playbackIsActive\(\)[\s\S]+artworkURL: track\.artworkURL \|\| null/);
});

test("stores profile-menu clip ranges as playback metadata without exporting files", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const preloadSource = readFileSync(new URL("../preload.cjs", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.match(htmlSource, /id="profileClipEditor"[\s\S]+Clip Editor/);
  assert.match(htmlSource, /id="clipEditorDialog"[\s\S]+id="clipEditorTrack"[\s\S]+id="clipEditorStartInput"[^>]+type="text"[\s\S]+id="clipEditorEndInput"[^>]+type="text"/);
  assert.match(htmlSource, /class="clip-editor-title-picker"[\s\S]+id="clipEditorTitle"[\s\S]+id="clipEditorTrack"/);
  assert.doesNotMatch(htmlSource, />My Clip<|\[Visualizer\]/);
  assert.match(appSource, /triggerLabel: track\.title \|\| "Unknown title"/);
  assert.match(styleSource, /\.clip-editor-title-picker \.resonance-select-trigger\s*\{/);
  assert.match(htmlSource, /id="clipEditorStartHandle"[^>]+role="slider"[\s\S]+id="clipEditorEndHandle"[^>]+role="slider"/);
  assert.doesNotMatch(htmlSource, /id="clipEditor(?:Start|End)" type="range"/);
  assert.match(htmlSource, /id="saveClipRange"[^>]+disabled/);
  assert.match(htmlSource, /id="closeClipEditor"[^>]*>Done<\/button>[\s\S]+id="saveClipRange"[^>]*>Save<\/button>/);
  assert.match(htmlSource, /id="previewClipRange"[^>]+aria-pressed="false"[^>]+disabled[\s\S]+>Preview</);
  assert.match(htmlSource, /<video id="clipEditorPreview"[^>]+preload="metadata"[^>]+playsinline/);
  assert.match(htmlSource, /id="clipEditorVideoFrame"[^>]+hidden[\s\S]+VIDEO PREVIEW/);
  assert.match(htmlSource, /id="clipEditorVideoFrames"[^>]+hidden/);
  assert.match(htmlSource, /id="clipEditorPreviewCurrent"[\s\S]+id="clipEditorPreviewSeek"[^>]+type="range"[\s\S]+id="clipEditorPreviewEnd"/);
  assert.match(htmlSource, /id="clearClipRange"[^>]*>Use full song/);
  assert.match(htmlSource, /id="clipEditorStatus"[^>]+role="status"/);
  assert.match(appSource, /function clipEditorTrackIsEditable\(track\)[\s\S]+track\.available !== false[\s\S]+track\.fileUrl/);
  assert.match(appSource, /function openClipEditor\(trackID = null\)[\s\S]+requestedTrackID[\s\S]+track\.id === requestedTrackID[\s\S]+clipEditorDialog[\s\S]+showModal\(\)/);
  assert.match(appSource, /label: "Open in Clip Editor",[\s\S]{0,180}openClipEditor\(track\.id\)/);
  assert.match(appSource, /openServerTrackContextMenu[\s\S]+\.\.\.\(localTrack \? \[\{[\s\S]+label: "Open in Clip Editor"[\s\S]+openClipEditor\(localTrack\.id\)/);
  assert.match(appSource, /async function saveClipRange\(\)[\s\S]+setClipRangeForTrack\(state, track/);
  assert.match(appSource, /#saveClipRange"\)\.onclick = saveClipRange/);
  const saveFunctionSource = appSource.slice(appSource.indexOf("async function saveClipRange()"), appSource.indexOf("function clearClipRange()"));
  assert.doesNotMatch(saveFunctionSource, /clipEditorDialog[\s\S]*\.close\(\)/);
  assert.match(appSource, /#closeClipEditor"\)\.onclick = \(\) => \{ void stopClipRangePreview\(\)\.then\(\(\) => \$\("#clipEditorDialog"\)\.close\(\)\); \};/);
  assert.match(appSource, /async function loadClipEditorVideoFrames\(track, count = 12\)[\s\S]+drawImage[\s\S]+toDataURL\("image\/jpeg"/);
  assert.match(appSource, /api\.videoFrames\(\{[\s\S]+filePath: track\.filePath[\s\S]+duration: clipEditorDuration\(track\)/);
  assert.match(preloadSource, /videoFrames: \(value\) => ipcRenderer\.invoke\("library:video-frames", value\)/);
  assert.match(mainSource, /ipcMain\.handle\("library:video-frames"[\s\S]+rendererReadableMediaPath\(filePath, managedRoots\)[\s\S]+captureVideoFrame/);
  assert.match(appSource, /function finishClipPlaybackIfNeeded\(\)/);
  assert.match(appSource, /currentPlaybackDuration\(\)[\s\S]{0,180}clippedPlaybackPosition\(duration \* Number/);
  assert.match(appSource, /async function toggleClipRangePreview\(\)[\s\S]+prepareClipRangePreviewMedia\(track\)[\s\S]+clipEditorPreviewAudio\.play\(\)/);
  assert.match(appSource, /function waitForClipRangePreviewMetadata\(\)[\s\S]+loadedmetadata/);
  assert.match(appSource, /function syncClipRangePreviewTransport\(\)[\s\S]+clipEditorPreviewSeek[\s\S]+aria-valuetext/);
  assert.match(appSource, /function clipEditorTrackIsVideo\([\s\S]+mp4\|mov\|m4v\|webm/);
  assert.match(appSource, /async function stopClipRangePreview\([\s\S]+resumePlaybackAfterClipRangePreview/);
  assert.match(appSource, /clipEditorPreviewAudio\.ontimeupdate = \(\) =>[\s\S]+clipEditorPreviewEndSeconds[\s\S]+clipEditorPreviewAudio\.pause\(\)[\s\S]+resumePlaybackAfterClipRangePreview/);
  assert.match(appSource, /#previewClipRange"\)\.onclick = toggleClipRangePreview/);
  assert.doesNotMatch(preloadSource, /exportClip|clip:export/);
  assert.doesNotMatch(mainSource, /clip:export|Export Resonance clip/);
  assert.match(appSource, /#profileClipEditor"\)\.onclick = openClipEditor/);
  assert.match(appSource, /function updateClipEditorRange\(\)/);
  assert.match(appSource, /function parseClipEditorTime\(value\)/);
  assert.match(appSource, /function setClipEditorBoundary\(boundary, seconds\)/);
  assert.match(appSource, /handle\.setPointerCapture\(event\.pointerId\)/);
  assert.match(appSource, /event\.preventDefault\(\);[\s\S]+handle\.focus\(\);[\s\S]+handle\.setPointerCapture/);
  assert.match(appSource, /waveform\.getBoundingClientRect\(\)/);
  assert.doesNotMatch(styleSource, /\.clip-editor-ranges\s*\{/);
  assert.match(appSource, /CLIP_EDITOR_VISUALIZER_BAR_COUNT = 112/);
  assert.match(htmlSource, /id="clipEditorStageVisualizerCanvas"/);
  assert.match(appSource, /getContext\("2d", \{ alpha: true, desynchronized: true \}\)/);
  assert.match(appSource, /drawClipEditorStageVisualizer\(clipEditorVisualizerDisplayedLevels, \{ live: true \}\)/);
  assert.match(appSource, /clipEditorVisualizerDisplayedLevels\.set\(clipEditorVisualizerStaticLevels\)/);
  assert.doesNotMatch(appSource, /bar\.style\.height/);
  assert.doesNotMatch(appSource, /clipEditorStageVisualizer"\)\.children/);
  assert.match(appSource, /const defaultStart = duration > 60 \? 15 : 0/);
  assert.match(appSource, /defaultStart \+ 45/);
  assert.match(appSource, /bar\.classList\.toggle\("selected"/);
  assert.doesNotMatch(appSource, /clip-wave-height/);
  assert.match(htmlSource, /clip-editor-handle-start[›\s\S]+clip-editor-handle-end[‹\s\S]+/);
  assert.match(styleSource, /\.clip-editor-dialog\s*\{/);
  assert.match(styleSource, /\.clip-editor-waveform\s*\{/);
  assert.match(styleSource, /\.clip-editor-wave-bars i\.selected\s*\{/);
  assert.match(styleSource, /\.clip-editor-video-frame\s*\{[\s\S]+object-fit: contain/);
  assert.match(styleSource, /\.clip-editor-video-frames\s*\{[\s\S]+grid-template-columns/);
  assert.match(styleSource, /\.clip-editor-wave-bars\[hidden\]\s*\{\s*display: none/);
  assert.match(styleSource, /\.clip-editor-transport\s*\{[\s\S]+grid-template-columns: auto 42px minmax\(0, 1fr\) 42px/);
  assert.match(styleSource, /\.clip-editor-preview\.playing\s*\{/);
  assert.doesNotMatch(styleSource, /\.clip-editor-stage-visualizer::after/);
  assert.doesNotMatch(styleSource, /\.clip-editor-stage-visualizer\s*\{[^}]*mask-image/);
  assert.doesNotMatch(styleSource, /\.clip-editor-stage-visualizer i\s*\{[^}]*box-shadow/);
  assert.match(styleSource, /\.clip-editor-stage-visualizer\s*\{[^}]*contain: layout paint style/);
  assert.match(styleSource, /\.clip-editor-stage-visualizer canvas\s*\{/);
});

test("keeps reviewed Windows empty, selection, filter, and metadata states truthful", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");

  assert.match(appSource, /data-search-scope="\$\{value\}"/);
  assert.match(appSource, /\["all", "All"\][\s\S]+\["device", "On Device"\][\s\S]+\["available", "Not Downloaded"\]/);
  assert.match(appSource, /const selectLabel = serverSelecting \? "Cancel song selection"/);
  assert.match(appSource, /id="syncAll"[\s\S]+!offlineDownloadAvailable \|\| \(serverSelecting && !selectedRemoteIDs\.size\) \? "disabled"/);
  assert.match(appSource, /event\.key === "Escape"[\s\S]+serverSelecting = false;[\s\S]+selectedRemoteIDs\.clear\(\)/);
  assert.match(appSource, /const resultSummary = filtered \? `Showing \$\{filteredCount\} of \$\{serverCatalog\.length\} tracks` : "All tracks"/);
  assert.match(appSource, /const showConnectionDetail = !connected;/);

  assert.match(appSource, /const emptyLibraryTitle = hasLibraryFilter \? "No matching songs"[\s\S]+"This playlist is empty"/);
  assert.match(appSource, /id="playCollection" \$\{playableTrackCount \? "" : "disabled"\}/);
  assert.match(appSource, /playableTrackCount \? `<button[^`]+data-hero-next>Next Track<\/button>` : ""/);
  assert.match(appSource, /id="heroShuffle"[\s\S]+\$\{playableTrackCount && !currentTrack\(\)\?\.transientStream \? "" : "disabled"\}/);
  assert.match(appSource, /aria-label="Library filter"[\s\S]+aria-pressed="\$\{libraryFilter === "all"\}"/);

  assert.match(appSource, /storageScope === "downloads" \? "No server downloads yet"/);
  assert.match(appSource, /id="storageEdit" \$\{!storageEditing && !tracks\.length \? "disabled"/);
  assert.match(appSource, /aria-label="\$\{selectedStorageIDs\.has\(track\.id\) \? "Deselect" : "Select"\}/);
  assert.match(appSource, /aria-label="Storage scope"[\s\S]+aria-pressed="\$\{storageScope === "songs"\}"/);

  assert.match(appSource, /function displayAlbum\(track\)[\s\S]+"Unknown Album"/);
  assert.match(mainSource, /album: details\.album \|\| "Unknown Album"/);
  assert.match(htmlSource, /id="createPlaylist"[^>]+disabled/);
  assert.match(appSource, /#playlistName"\)\.oninput[\s\S]+createPlaylist"\)\.disabled = !/);
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
  assert.match(appSource, /const recentTracks = !selectedPlaylistID \? filterTracks\(tracks, "", "recent"\)\.filter/);
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

test("opens a synchronized full-screen Now Playing viewer from the mini-player", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");

  assert.match(htmlSource, /id="openNowPlaying"[\s\S]+id="nowPlayingDialog" class="full-player-dialog"/);
  assert.match(htmlSource, /id="fullPlayerBackdrop"[\s\S]+id="fullPlayerArtwork"[\s\S]+id="fullPlayerTitle"[\s\S]+id="fullPlayerArtist"[\s\S]+id="fullPlayerAlbum"/);
  assert.match(htmlSource, /id="fullPlayerSeek"[\s\S]+id="fullPlayerShuffle"[\s\S]+data-action="previous"[\s\S]+class="full-player-play"[^>]+data-action="toggle"[\s\S]+data-action="next"[\s\S]+id="fullPlayerRepeat"/);
  assert.match(htmlSource, /id="fullPlayerSpeed"[\s\S]+id="fullPlayerVolume"[\s\S]+id="fullPlayerQueueToggle"[\s\S]+id="fullPlayerQueuePanel"/);
  assert.match(htmlSource, /id="fullPlayerQueueTitle">Queue[\s\S]+id="fullPlayerQueueCount"[\s\S]+data-full-player-queue-tab="up-next">Up next[\s\S]+data-full-player-queue-tab="history">History/);
  assert.match(appSource, /function openNowPlaying\(\)[\s\S]+renderFullPlayer\(\)[\s\S]+dialog\.showModal\(\)/);
  assert.match(appSource, /function renderFullPlayer\(\)[\s\S]+fullPlayerBackdrop[\s\S]+fullPlayerFavorite[\s\S]+renderFullPlayerQueue\(\)/);
  assert.match(appSource, /const backdropNode = \$\("#fullPlayerBackdrop"\)[\s\S]+backdropNode\.innerHTML = track\.artwork/);
  assert.doesNotMatch(appSource, /fullPlayerBackdrop"\)\.style\.backgroundImage/);
  assert.match(appSource, /function updateFullPlayerProgress\(\)/);
  assert.match(appSource, /function fullPlayerQueueTracks\(\)/);
  assert.match(appSource, /function fullPlayerHistoryTracks\(\)[\s\S]+\[\.\.\.history\]\.reverse\(\)/);
  assert.match(appSource, /function fullPlayerHistoryTracks\(\)[\s\S]+state\.listeningHistory[\s\S]+historyOnly: true/);
  assert.match(appSource, /track\.historyOnly \? "Not downloaded"/);
  assert.match(appSource, /fullPlayerQueueTab === "history" \? fullPlayerHistoryTracks\(\) : fullPlayerQueueTracks\(\)/);
  assert.match(appSource, /data-full-player-queue/);
  assert.match(appSource, /#fullPlayerSeek"\)\.oninput[\s\S]+audio\.currentTime/);
  assert.match(appSource, /#fullPlayerVolume"\)\.oninput = \(event\) => setPlaybackVolume\(event\.target\.value\)/);
  assert.match(appSource, /function setPlaybackVolume\([\s\S]+#volume[\s\S]+#fullPlayerVolume[\s\S]+#installedVideoVolume/);
  assert.match(appSource, /#fullPlayerSpeed"\)\.onchange[\s\S]+#speed/);
  assert.match(appSource, /#fullPlayerMore"\)\.onclick[\s\S]+openTrackContextMenu/);
  assert.match(appSource, /function bindPrimaryAudioEvents\(media\)[\s\S]+media\.ontimeupdate = \(\) => \{[\s\S]+updateFullPlayerProgress\(\)/);
  assert.match(styleSource, /\.full-player-dialog\s*\{[\s\S]*?position: fixed;[\s\S]*?inset: 0;[\s\S]*?width: auto;[\s\S]*?height: auto;/);
  assert.match(styleSource, /\.full-player-shell\s*\{[\s\S]*?position: absolute;[\s\S]*?inset: 0;[\s\S]*?min-width: 0;[\s\S]*?min-height: 0;/);
  assert.match(appSource, /const FULL_PLAYER_TRANSITION_MS = 380/);
  assert.match(appSource, /function closeNowPlaying\(\)[\s\S]*?classList\.add\("closing"\)[\s\S]*?setTimeout\(finishNowPlayingClose, FULL_PLAYER_TRANSITION_MS \+ 80\)/);
  assert.match(appSource, /animationName === "full-player-slide-out"[\s\S]*?finishNowPlayingClose\(\)/);
  assert.match(styleSource, /\.full-player-dialog\[open\]\s*\{[\s\S]*?full-player-slide-in 380ms/);
  assert.match(styleSource, /\.full-player-dialog\[open\]\.closing\s*\{[\s\S]*?full-player-slide-out 380ms/);
  assert.match(styleSource, /@keyframes full-player-slide-in\s*\{[\s\S]*?translateY\(100%\)[\s\S]*?translateY\(0\)/);
  assert.match(styleSource, /@keyframes full-player-slide-out\s*\{[\s\S]*?translateY\(0\)[\s\S]*?translateY\(100%\)/);
  assert.match(styleSource, /@media \(prefers-reduced-motion: reduce\)[\s\S]*?\.full-player-dialog\[open\],[\s\S]*?\.full-player-dialog\[open\]\.closing \{ animation: none; \}/);
  assert.match(styleSource, /\.full-player-backdrop\s*\{[\s\S]*?z-index: 0[\s\S]*?filter: blur\(64px\) saturate\(1\.18\)[\s\S]*?opacity: \.88/);
  assert.match(styleSource, /\.full-player-backdrop img\s*\{[\s\S]*?object-fit: cover/);
  assert.match(styleSource, /\.full-player-shade\s*\{[\s\S]*?z-index: 1[\s\S]*?linear-gradient\(180deg, #00000075 0%, #07071194 52%, #000000c2 100%\)/);
  assert.match(styleSource, /\.full-player-layout\s*\{[\s\S]*?z-index: 2/);
  assert.match(styleSource, /\.full-player-layout\s*\{[\s\S]+grid-template-columns/);
  assert.match(styleSource, /\.full-player-artwork\s*\{[\s\S]+aspect-ratio: 1/);
  assert.match(styleSource, /\.full-player-details\s*\{[\s\S]*?grid-template-columns: minmax\(0, 1fr\);[\s\S]*?width: 100%;[\s\S]*?max-width: 100%;[\s\S]*?min-width: 0;/);
  assert.match(styleSource, /\.full-player-copy\s*\{[\s\S]*?min-width: 0;/);
  assert.match(htmlSource, /id="fullPlayerTitle"[\s\S]+id="fullPlayerTitleTrack"[\s\S]+id="fullPlayerTitleText"[\s\S]+id="fullPlayerTitleRepeat"[^>]+aria-hidden="true"/);
  assert.match(appSource, /function syncFullPlayerTitleMarquee\(\)[\s\S]+titleMarqueeMetrics\(text\.getBoundingClientRect\(\)\.width, viewport\.clientWidth\)/);
  assert.match(appSource, /function setFullPlayerTitle\(title\)[\s\S]+aria-label[\s\S]+syncFullPlayerTitleMarquee/);
  assert.match(styleSource, /#fullPlayerTitle\.overflowing #fullPlayerTitleTrack\s*\{[\s\S]+full-player-title-marquee/);
  assert.match(styleSource, /full-player-title-marquee[^;]+linear 1s infinite/);
  assert.doesNotMatch(styleSource, /full-player-title-marquee[^;]+alternate/);
  assert.match(styleSource, /@keyframes full-player-title-marquee\s*\{[\s\S]+from[^}]+translateX\(0\)[\s\S]+to[^}]+calc\(-1 \* var\(--full-player-title-cycle\)\)/);
  assert.match(appSource, /function currentPlaybackDuration\([^]*?audioMetadataTrackID !== track\.id[^]*?playableMediaDuration\(\{ storedDuration, audioDuration: audio\.duration \}\)/);
  assert.match(appSource, /media\.onloadedmetadata = async \(\) => \{[^]*?audioSourceTrackID[^]*?playableMediaDuration\(\{ audioDuration: audio\.duration \}\)[^]*?track\.duration = measuredDuration/);
  assert.match(styleSource, /@media \(prefers-reduced-motion: reduce\)[\s\S]+#fullPlayerTitle\.overflowing #fullPlayerTitleTrack/);
  assert.match(styleSource, /\.full-player-transport \.full-player-play\s*\{/);
  assert.match(styleSource, /\.full-player-queue-panel\s*\{/);
  assert.match(styleSource, /\.full-player-queue-tabs\s*\{[\s\S]+grid-template-columns: 1fr 1fr/);
  assert.match(styleSource, /\.full-player-queue-tabs button\.active::after\s*\{[\s\S]+background: #9b7aff/);
});

test("hides inline playlist row buttons while preserving drag and context controls", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.match(appSource, /data-playlist-draggable="true"/);
  assert.match(appSource, /data-playlist-entry=/);
  assert.match(appSource, /const canReorder = Boolean\(editablePlaylist && entryKey[\s\S]+notDownloaded/);
  assert.match(appSource, /row\.onpointerdown\s*=/);
  assert.match(appSource, /row\.onpointerup\s*=/);
  assert.doesNotMatch(appSource, /row\.ondragstart\s*=/);
  assert.match(appSource, /drag-preview-up/);
  assert.doesNotMatch(appSource, /data-reorder-track/);
  assert.doesNotMatch(appSource, /data-remove-playlist-track/);
  assert.doesNotMatch(appSource, /playlist-track-actions/);
  assert.match(appSource, /row\.oncontextmenu\s*=\s*\(event\) => \{[\s\S]+openTrackContextMenu/);
  assert.match(appSource, /function renderContextMenu\(\{ title, subtitle, actions \}\)/);
  assert.match(appSource, /function renderTrackPlaylistContextMenu\(track, options\)/);
  assert.match(appSource, /label: "Add to playlist"/);
  assert.match(appSource, /label: `Remove from \$\{activePlaylist\.name\}`,[\s\S]+danger: true/);
  assert.match(appSource, /label: "Remove from device",[\s\S]+deleteStoredTracks\(\[track\.id\]\)/);
  assert.doesNotMatch(appSource, /options\.source === "storage"[\s\S]{0,300}label: "Remove from device"/);
  assert.match(appSource, /async function deleteStoredTracks[\s\S]+audio\.removeAttribute\("src"\)[\s\S]+audio\.load\(\)[\s\S]+await api\.deleteAudio\(track\.filePath\)/);
  assert.match(appSource, /activePlaybackPlaylistID === activePlaylist\.id/);
  assert.match(appSource, /button\.oncontextmenu = \(event\) => openTrackContextMenu/);
  assert.match(appSource, /data-storage-track/);
  assert.match(appSource, /row\.oncontextmenu = \(event\) => openServerTrackContextMenu/);
  assert.match(appSource, /button\.oncontextmenu = \(event\) => openPlaylistContextMenu/);
  assert.match(appSource, /playerTrackContextTarget\.oncontextmenu/);
  assert.doesNotMatch(appSource, /data-playlist-sync-status/);
  assert.doesNotMatch(appSource, /Synced \$\{(?:remoteDocument|result\.document)\.playlists\.length/);
  assert.match(styleSource, /\.track-row\.playlist-draggable\s*\{/);
  assert.match(styleSource, /\.track-row\.playlist-drag-floating\s*\{/);
  assert.match(styleSource, /\.track-context-menu\s*\{/);
  assert.match(styleSource, /\.track-context-menu \.context-danger/);
  assert.match(styleSource, /\.context-action-icon svg/);
});

test("gives interactive rows real primary buttons alongside secondary controls", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  assert.match(appSource, /data-track="\$\{escapeHTML\(track\.id\)\}" role="group" aria-label=/);
  assert.match(appSource, /data-track-activate="\$\{escapeHTML\(track\.id\)\}" aria-label=/);
  assert.match(appSource, /const keyboardActionLabel = unavailable/);
  assert.match(appSource, /Press Enter or Space to play/);
  assert.match(appSource, /aria-keyshortcuts="Enter Space Alt\+ArrowUp Alt\+ArrowDown Shift\+F10"/);
  assert.match(appSource, /data-storage-track="\$\{escapeHTML\(track\.id\)\}" role="group" aria-label=/);
  assert.match(appSource, /data-storage-activate="\$\{escapeHTML\(track\.id\)\}" aria-label=/);
  assert.match(appSource, /data-remote-activate="\$\{escapeHTML\(song\.id\)\}" aria-label=/);
  assert.match(appSource, /const storageActionLabel = storageEditing/);
  assert.match(appSource, /aria-disabled="\$\{!storageEditing && unavailable\}"/);
  assert.match(appSource, /primaryAction\.onclick/);
  assert.match(appSource, /document\.querySelectorAll\("\[data-storage-select\]"\)/);
});

test("uses the playlist dropdown treatment across app popup menus", () => {
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  const shuffleStyleSource = readFileSync(new URL("../ui/shuffle-icon.css", import.meta.url), "utf8");
  assert.match(styleSource, /--menu-surface: #201f29/);
  assert.match(styleSource, /--menu-border: #5f5c69/);
  assert.match(styleSource, /--menu-shadow: 0 22px 55px #000b/);
  for (const selector of ["profile-menu", "search-sort-menu", "playlist-menu", "track-context-menu", "storage-import-menu"]) {
    assert.match(styleSource, new RegExp(`\\.${selector}\\s*\\{[\\s\\S]+?var\\(--menu-(?:surface|border|shadow)\\)`));
  }
  assert.match(styleSource, /\.resonance-select-menu\s*\{[\s\S]+background: var\(--menu-surface\)[\s\S]+box-shadow: var\(--menu-shadow\)/);
  assert.match(styleSource, /\.resonance-select-option\.selected\s*\{[\s\S]+background: var\(--accent-soft\)[\s\S]+color: #b6a3ff/);
  assert.match(styleSource, /\.playlist-menu button:focus-visible[\s\S]+background: var\(--menu-hover\)/);
  assert.match(styleSource, /\.storage-import-option:focus-visible[\s\S]+background: var\(--menu-hover\)/);
  assert.match(styleSource, /\.playlist-menu,\s*\.track-context-menu\s*\{[\s\S]+gap: 2px[\s\S]+padding: 7px[\s\S]+border-radius: 12px[\s\S]+background: var\(--menu-surface\)/);
  assert.match(styleSource, /\.playlist-menu button,\s*\.track-context-menu button\s*\{[\s\S]+padding: 8px 9px[\s\S]+border-radius: 7px[\s\S]+font-size: 14px[\s\S]+font-weight: 450/);
  assert.match(styleSource, /\.track-context-menu\s*\{[\s\S]+width: max-content[\s\S]+min-width: 164px[\s\S]+max-width: min\(246px/);
  assert.match(styleSource, /\.context-action-icon\s*\{\s*display: none/);
  assert.match(styleSource, /\.context-action-label\s*\{[\s\S]+?width: 100%[\s\S]+?text-align: left/);
  assert.match(styleSource, /\.playlist-menu \.danger-item,\s*\.track-context-menu \.context-danger\s*\{\s*color: #ff9ba3/);
  assert.match(styleSource, /\.context-divider\s*\{\s*display: none/);
  assert.doesNotMatch(shuffleStyleSource, /\.track-context-menu/);
});

test("ports playback reliability, recovery notices, and keyboard operation into the current UI", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.match(appSource, /function activePlaybackTracks\(\)/);
  assert.match(appSource, /state\.playbackQueueIDs = \[\.\.\.activePlaybackQueueIDs\]/);
  assert.match(appSource, /function previous\(\)[\s\S]+activePlaybackMedia\(\)[\s\S]+media\.currentTime > start \+ 3[\s\S]+recordHistory: false/);
  assert.match(appSource, /pendingRestorePosition[\s\S]+audio\.currentTime = clippedPlaybackPosition\(Math\.min/);
  assert.match(appSource, /audio\.volume = playbackGainForVolume\(state\.volume\)/);
  assert.match(appSource, /function showNotice\(message, kind = "error"\)/);
  assert.match(appSource, /const APP_NOTICE_LIFETIME_MS = 5000/);
  assert.match(appSource, /function showNotice\(message, kind = "error"\)[\s\S]+clearTimeout\(appNoticeDismissTimer\)[\s\S]+setTimeout\([\s\S]+APP_NOTICE_LIFETIME_MS/);
  assert.match(appSource, /function dismissNotice\(\)[\s\S]+clearTimeout\(appNoticeDismissTimer\)[\s\S]+notice\.hidden = true/);
  assert.match(appSource, /function friendlyIPCError\(error, fallback\)/);
  assert.match(appSource, /replace\(\/\^Error invoking remote method/);
  assert.match(appSource, /const deleted = \[\];[\s\S]+const failed = \[\];[\s\S]+The files remain in your library/);
  assert.match(appSource, /Alt\+Up or Alt\+Down/);
  assert.match(appSource, /primaryAction\.onkeydown = async[\s\S]+dataset\.playlistEntry[\s\S]+CSS\.escape\(entryKey\)/);
  assert.match(appSource, /menu\.onkeydown = \(keyEvent\)[\s\S]+ArrowDown[\s\S]+Home[\s\S]+End/);
  assert.match(mainSource, /\.corrupt-\$\{Date\.now\(\)\}/);
  assert.match(mainSource, /sanitizePersistedJSON\(rawBackup\)/);
  assert.doesNotMatch(mainSource, /fs\.copyFile\(state, backup\)/);
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
  assert.match(appSource, /artwork\(song, \{ animateLoading: true, forceLoading: artworkLoading \}\)/);
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
  const webImportOverrides = styleSource.slice(styleSource.indexOf("/* Web import is a utility, so keep its presentation quiet and direct. */"));
  const packageSource = readFileSync(new URL("../package.json", import.meta.url), "utf8");
  const localImportUploadSource = mainSource.slice(
    mainSource.indexOf('ipcMain.handle("local-import:upload"'),
    mainSource.indexOf('ipcMain.handle("library:delete"'),
  );

  assert.match(mainSource, /function localImportEnabled\(\) \{\s+return process\.env\.RESONANCE_LOCAL_DEVICE_IMPORT !== "0";\s+\}/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:resolve"/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:artwork"/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:start"/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:start-external"/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:cancel"/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:upload"/);
  assert.match(mainSource, /destinationDirectory: paths\.local/);
  assert.match(mainSource, /Only a song already saved in the managed Resonance library can be uploaded/);
  assert.match(localImportUploadSource, /managedRoots = \[paths\.local, paths\.remote\]/);
  assert.match(localImportUploadSource, /isManagedLibraryFile\(absolute, managedRoots\)/);
  assert.match(mainSource, /adminToken = canonicalCredentialToken\(adminToken\)[\s\S]+profileHeaders\(adminToken, profileID\)/);
  assert.match(mainSource, /cleanupLocalImportTemporaryFiles[\s\S]+startsWith\("resonance-local-import-"\)/);
  assert.match(preloadSource, /resolveLocalImport:[\s\S]+local-import:resolve/);
  assert.match(preloadSource, /fetchLocalImportArtwork:[\s\S]+local-import:artwork/);
  assert.match(preloadSource, /startLocalImport:[\s\S]+local-import:start/);
  assert.match(preloadSource, /startExternalImport:[\s\S]+local-import:start-external/);
  assert.match(preloadSource, /cancelLocalImport:[\s\S]+local-import:cancel/);
  assert.match(preloadSource, /uploadLocalImport:[\s\S]+local-import:upload/);
  assert.match(preloadSource, /onLocalImportProgress:[\s\S]+local-import:progress/);
  assert.match(htmlSource, /id="localImportDialog"/);
  assert.match(htmlSource, /id="localImportTitle">Import from Web/);
  assert.match(webImportOverrides, /\.local-import-panel\s*\{[^}]*border-radius: 13px[^}]*background: #0d0f14/);
  assert.match(styleSource, /\.storage-import-menu\s*\{[\s\S]*?overflow: hidden;[\s\S]*?isolation: isolate;[\s\S]*?border-radius: 18px/);
  assert.doesNotMatch(htmlSource, /Spotify tracks are matched against/);
  assert.match(htmlSource, /id="localImportStage"[^>]*hidden/);
  assert.doesNotMatch(htmlSource, /Choose a source|Confirm the match before/);
  assert.doesNotMatch(styleSource, /\.local-import-stage/);
  assert.match(htmlSource, /id="localImportSource"/);
  assert.doesNotMatch(htmlSource, /id="resolveLocalImport"|>Find (?:audio|video)</);
  assert.match(htmlSource, /id="localImportMediaKind"[\s\S]+value="audio"[\s\S]+value="video"/);
  assert.match(htmlSource, /id="localImportProviderPill"[\s\S]+data-local-import-provider="youtube"[\s\S]+data-local-import-provider="spotify"[\s\S]+data-local-import-provider="soundcloud"/);
  assert.match(htmlSource, /value="audio" checked><span>Audio<\/span>[\s\S]+value="video"><span>Video<\/span>/);
  assert.doesNotMatch(htmlSource, /local-import-spark|provider-youtube|provider-spotify|provider-soundcloud/);
  assert.match(htmlSource, /<header>[\s\S]+id="localImportMediaKind"[\s\S]+id="closeLocalImport"[\s\S]+<\/header>/);
  assert.doesNotMatch(htmlSource, /MP4 with audio/);
  assert.match(htmlSource, /id="localImportCandidates"/);
  assert.match(htmlSource, /id="localImportPreview"/);
  assert.match(htmlSource, /id="localImportSync"/);
  assert.match(htmlSource, /<footer>[\s\S]+id="localImportSyncRow"[\s\S]+Upload to server/);
  assert.match(appSource, /sync\.checked = true/);
  assert.match(appSource, /sync\.disabled = serverBacked/);
  assert.match(appSource, /input\.onchange = \(\) => \{[\s\S]+updateLocalImportSyncForSelection\(\{ preserveChecked: true \}\)/);
  assert.doesNotMatch(appSource, /sync\.disabled = serverBacked \|\| !canSync/);
  assert.doesNotMatch(htmlSource, /localImportSyncTitle|localImportSyncHelp|Upload after saving locally/);
  assert.match(htmlSource, /Supports YouTube, Spotify, and SoundCloud\./);
  assert.match(htmlSource, /id="chooseLocalFiles"[^>]*>Choose files<\/button>/);
  assert.match(htmlSource, /id="confirmLocalImport"[\s\S]+Import selected/);
  assert.match(htmlSource, /style-src 'self'; style-src-attr 'unsafe-inline'/);
  assert.match(htmlSource, /connect-src blob:/);
  assert.match(appSource, /function resolveLinkImport\(\)/);
  assert.match(appSource, /const LOCAL_IMPORT_AUTO_RESOLVE_DELAY = 450/);
  assert.match(appSource, /function localImportSourceIsReady\(value\)/);
  assert.match(appSource, /function scheduleLocalImportResolution/);
  assert.match(appSource, /function localImportInputIsLink\(value\)/);
  assert.match(mainSource, /!looksLikeLink\(input\)[\s\S]+searchAllPlatforms\(input, controller\.signal, fetch, \{ mediaKind \}\)/);
  assert.match(packageSource, /"local-search\.cjs"/);
  assert.match(appSource, /\$\("#localImportSource"\)\.oninput = \(\) => \{[\s\S]+scheduleLocalImportResolution\(\)/);
  assert.doesNotMatch(appSource, /\$\("#resolveLocalImport"\)/);
  assert.match(styleSource, /\.local-import-source\.searching \.local-import-source-spinner/);
  assert.match(appSource, /renderLocalImportArtwork\(track, candidates, mediaKind\)/);
  assert.match(appSource, /candidates\.length > 1/);
  assert.match(appSource, /data-local-import-preview/);
  assert.match(appSource, /function toggleLocalImportPreview\(index\)/);
  assert.match(appSource, /localImportPreviewAudio\.ontimeupdate/);
  assert.match(appSource, /api\.previewLocalImport\(candidate\.sourceURL\)/);
  assert.match(appSource, /function setLocalImportOperationLocked\(locked, \{ keepSourceEditable = false \} = \{\}\)[\s\S]+disabled = locked && !keepSourceEditable/);
  assert.match(appSource, /setLocalImportOperationLocked\(true, \{ keepSourceEditable: true \}\)/);
  assert.match(appSource, /localImportResolutionRestartPending = true;[\s\S]+api\.cancelLocalImport\(\)/);
  assert.match(appSource, /const restartResolution = localImportResolutionRestartPending[\s\S]+if \(restartResolution\) scheduleLocalImportResolution\(\)/);
  assert.match(appSource, /function updateLocalImportTransfer\(value = \{\}\)[\s\S]+if \(\$\("#localImportDialog"\)\.open\) return/);
  assert.match(appSource, /if \(!localImportResolution\) \$\("#cancelLocalImport"\)\.hidden = true;[\s\S]+hideServerTransfer\("local-import"\)/);
  assert.match(preloadSource, /previewLocalImport: \(sourceURL\) => ipcRenderer\.invoke\("local-import:preview"/);
  assert.match(preloadSource, /cancelLocalImportPreview: \(\) => ipcRenderer\.invoke\("local-import:preview:cancel"\)/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:preview"/);
  assert.match(mainSource, /resolveYouTubeAudio\(source, controller\.signal\)/);
  assert.match(mainSource, /downloadResolvedAudio\(resolved, filePath, controller\.signal\)/);
  assert.match(mainSource, /ipcMain\.handle\("local-import:preview:cancel"/);
  assert.match(appSource, /const stage = value\.stage \|\| "idle";[\s\S]+\$\("#localImportStage"\)\.dataset\.stage = stage/);
  assert.match(appSource, /\$\("#localImportDialog"\)\.classList\.toggle\("expanded", stage !== "idle"\)/);
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
  assert.match(appSource, /if \(!response\.result\.serverBacked && uploadRequested[\s\S]+uploadImportedTrackWithMode\(/);
  assert.match(appSource, /function uploadLocalImportTrack\(track, context\)[\s\S]+api\.uploadLocalImport/);
  assert.doesNotMatch(appSource, /A failed upload will not remove or alter the local media file/);
  assert.match(appSource, /mediaKind: localImportResolution\.mediaKind|mediaKind,/);
  assert.match(mainSource, /outputFormats: \{ audio: "m4a", video: "mp4" \}/);
  assert.match(mainSource, /sources: \["spotify", "spotify_playlists", "soundcloud", "soundcloud_playlists", "youtube", "youtube_playlists"/);
  assert.match(mainSource, /resolveSoundCloudAudio\(source, controller\.signal\)/);
  assert.match(mainSource, /downloadResolvedSoundCloudAudio\(resolved, filePath, controller\.signal\)/);
  assert.match(appSource, /candidate\.sourceProvider === "soundcloud"[\s\S]+return "SoundCloud"/);
  assert.match(appSource, /"soundcloud\.com", "www\.soundcloud\.com", "m\.soundcloud\.com", "on\.soundcloud\.com"/);
  assert.match(appSource, /localImportResolution\?\.kind\?\.endsWith\("_playlist"\)/);
  assert.match(appSource, /kind === "spotify_playlist"[\s\S]+"Spotify"[\s\S]+kind === "soundcloud_playlist"[\s\S]+"SoundCloud"[\s\S]+kind === "youtube_playlist"[\s\S]+"YouTube"/);
  assert.match(appSource, /input\[name="localImportPlaylistItem"\]:checked/);
  assert.match(appSource, /async function confirmPlaylistImport\(\)/);
  assert.match(appSource, /const transferSelected = uniqueLocalImportPlaylistCandidates\(selected, mediaKind\)/);
  assert.match(appSource, /for \(let index = 0; index < transferSelected\.length; index \+= 1\)/);
  const playlistImportSource = appSource.slice(
    appSource.indexOf("async function confirmPlaylistImport()"),
    appSource.indexOf("async function confirmLinkImport()"),
  );
  const downloadPhase = playlistImportSource.slice(
    playlistImportSource.indexOf("for (let index = 0; index < transferSelected.length; index += 1)"),
    playlistImportSource.indexOf("await saveImportedPlaylist();"),
  );
  assert.doesNotMatch(downloadPhase, /uploadLocalImportTrack|uploadLocalImportTracks|api\.uploadServer/);
  assert.match(playlistImportSource, /await saveImportedPlaylist\(\);[\s\S]+prepareLocalImportUploadBatch\(uploadQueue, importContext\)[\s\S]+uploadLocalImportTracks\(pendingUploads, importContext\)/);
  assert.match(appSource, /async function uploadLocalImportTracks\(tracks, context\)[\s\S]+api\.uploadServer\([\s\S]+result\?\.results/);
  assert.match(playlistImportSource, /uploadFailures\.push\(\.\.\.\(uploadResult\?\.failed \|\| \[\]\)\)/);
  assert.match(playlistImportSource, /formatServerUploadFailureNotice\(uploadFailures\)/);
  assert.match(mainSource, /mediaKind: value\.mediaKind/);
  assert.match(mainSource, /putSourceLinkRegistration\(\{[\s\S]+"Content-Type": "application\/json"[\s\S]+item: \{ mediaSourceURL, mediaKind \}/);
  assert.match(mainSource, /currentFile: filename,[\s\S]+completed,[\s\S]+total: 1/);
  assert.match(appSource, /sourceProvider === "debrid_vault"[\s\S]+return "Debrid Vault"/);
  assert.match(appSource, /api\.startExternalImport\(/);
  assert.match(appSource, /response\.result\.kind === "selection_required"/);
  assert.match(mainSource, /const reviewedSearch = \(async \(\) => \{[\s\S]+clientConfigContext\(baseURL, profileID\)[\s\S]+searchFileBackedSources\(track, \{[\s\S]+clientContextHeaders: \{ \.\.\.requestContext\.expected\.request_headers \}[\s\S]+\}, signal\)/);
  assert.match(debridSource, /review_candidates/);
  assert.match(debridSource, /redirect: "manual"/);
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
  assert.match(styleSource, /html\s*\{[\s\S]*?overflow: hidden/);
  assert.match(styleSource, /\.local-import-dialog\s*\{[\s\S]*?position: fixed/);
  assert.doesNotMatch(styleSource, /\.local-import-dialog\s*\{[\s\S]{0,160}?position: relative/);
  assert.match(webImportOverrides, /\.local-import-dialog:not\(\.expanded\),[\s\S]*?height: 226px/);
  assert.match(styleSource, /\.local-import-dialog\.expanded\s*\{[\s\S]*?height: min\(600px, calc\(100vh - 64px\)\)/);
  assert.match(styleSource, /\.local-import-dialog\.expanded \.local-import-panel\s*\{\s*height: 100%/);
  assert.match(styleSource, /\.local-import-resolved fieldset\s*\{[\s\S]*?flex: 1 1 auto[\s\S]*?overflow: hidden/);
  assert.match(styleSource, /\.local-import-candidates\.search-results\s*\{[\s\S]*?height: 100%[\s\S]*?overscroll-behavior: contain/);
  assert.match(appSource, /LOCAL_IMPORT_PROVIDER_ORDER = Object\.freeze\(\[\s*\["youtube", "YouTube"\],[\s\S]*?\["spotify", "Spotify"\],[\s\S]*?\["soundcloud", "SoundCloud"\]/);
  assert.match(styleSource, /\.local-import-media-kind\s*\{/);
  assert.match(webImportOverrides, /\.local-import-provider-pill\s*\{[^}]*position: static[^}]*display: flex/);
  assert.match(appSource, /function setLocalImportProviderFocus[\s\S]+data-search-provider/);
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
  assert.match(packageSource, /"ffmpeg-static": "5\.3\.0"/);
  assert.match(packageSource, /"resonanceUpdateAuthenticity": "production"/);
  assert.match(packageSource, /extraMetadata\.resonanceUpdateAuthenticity=unsigned/);
  assert.match(packageSource, /"local-debrid\.cjs"/);
  assert.match(packageSource, /"local-soundcloud\.cjs"/);
  assert.match(packageSource, /"node_modules\/ffmpeg-static\/\*\*"/);
});

test("opens a listening-history analytics dialog and records real playback time", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const preloadSource = readFileSync(new URL("../preload.cjs", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  const historyChartSource = appSource.slice(
    appSource.indexOf("function historyChartMarkup"),
    appSource.indexOf("function bindListeningHistoryChartInteractions"),
  );
  const historyStyleSource = styleSource.slice(
    styleSource.indexOf(".listening-history-dialog {"),
    styleSource.indexOf("@media (max-width: 720px)"),
  );
  assert.match(htmlSource, /id="profileHistory"[\s\S]+Listening History/);
  assert.match(htmlSource, /id="listeningHistoryDialog"/);
  assert.match(htmlSource, /id="listeningHistoryRange"/);
  assert.match(appSource, /value: "1", label: "Last 1 day"/);
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
  assert.match(appSource, /function finishListeningSessionForReplay\(\)[\s\S]+activeListeningEntryID = null/);
  assert.match(appSource, /media\.onended = \(\) => \{[\s\S]+if \(repeat\) \{[\s\S]+finishListeningSessionForReplay\(\)[\s\S]+requestPlayback\(\)/);
  assert.match(appSource, /function pendingListeningHistoryBatches\(\)[\s\S]+listeningHistoryEntryQualifiesAsPlay\(state, entry\)/);
  assert.match(appSource, /api\.onPrepareToClose\(async \(\) =>[\s\S]+updateListeningSession\(\)[\s\S]+await persist\(\{ refreshSidebar: false \}\)[\s\S]+api\.readyToClose\(\)/);
  assert.match(preloadSource, /onPrepareToClose:[\s\S]+app:prepare-close/);
  assert.match(preloadSource, /readyToClose:[\s\S]+app:close-ready/);
  assert.match(preloadSource, /postListeningHistory:[\s\S]+server:listening-history:post/);
  assert.match(preloadSource, /fetchListeningHistory:[\s\S]+server:listening-history:get/);
  assert.match(mainSource, /function safeListeningHistory\(value\)/);
  assert.match(mainSource, /remoteID: optionalText\(entry\.remoteID, 128\)[\s\S]+originatedOnThisDevice/);
  assert.match(mainSource, /duration: entry\.duration !== null[\s\S]+\? Math\.min\(Number\(entry\.duration\)/);
  assert.match(mainSource, /listeningHistory: safeListeningHistory\(state\.listeningHistory\)/);
  assert.match(mainSource, /ipcMain\.handle\("server:listening-history:post"/);
  assert.match(mainSource, /ipcMain\.handle\("server:listening-history:get"[\s\S]+url\.searchParams\.set\("limit"[\s\S]+Accept: "application\/json"/);
  assert.match(mainSource, /api\/v1\/listening-history/);
  assert.match(mainSource, /normalizeListeningHistoryUploadEntries/);
  assert.match(mainSource, /JSON\.stringify\(\{ entries: minimalEntries, client: DESKTOP_CLIENT_PLATFORM \}\)/);
  assert.match(
    mainSource.slice(
      mainSource.indexOf('ipcMain.handle("server:listening-history:post"'),
      mainSource.indexOf('ipcMain.handle("server:listening-history:get"'),
    ),
    /normalizeListeningHistoryUploadEntries[\s\S]+client: DESKTOP_CLIENT_PLATFORM/,
  );
  assert.match(mainSource, /response\.status === 404[\s\S]+supported: false/);
  assert.match(appSource, /const LISTENING_HISTORY_BATCH_SIZE = 500/);
  assert.match(appSource, /profileID: activeProfileID\(\)/);
  assert.match(appSource, /function pendingListeningHistoryBatches\(\)/);
  assert.match(appSource, /api\.postListeningHistory\(\{/);
  assert.match(appSource, /api\.fetchListeningHistory\(\{[\s\S]+mergeListeningHistoryDocument\(state, remoteDocument, context\.profileID, context\.serverURL, serverCatalog\)/);
  assert.match(appSource, /result\?\.supported === false/);
  assert.match(appSource, /scheduleListeningHistorySync\(\)/);
  assert.match(appSource, /syncListeningHistoryNow\(\{ force: true \}\)/);
  assert.match(mainSource, /librarySaveQueue[\s\S]+\.catch\(\(\) => \{\}\)[\s\S]+atomicWriteFile/);
  assert.match(mainSource, /window\.webContents\.send\("app:prepare-close"\)/);
  assert.match(mainSource, /ipcMain\.on\("app:close-ready"/);
  assert.match(mainSource, /app\.on\("before-quit", \(\) => \{[\s\S]+applicationQuitRequested = true;/);
  assert.match(mainSource, /clearTimeout\(automaticUpdateCheckTimer\)[\s\S]+clearInterval\(automaticUpdateCheckInterval\)/);
  assert.match(mainSource, /if \(applicationQuitRequested\) app\.quit\(\);/);
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
  assert.match(appSource, /const right = 40[\s\S]+const top = 8[\s\S]+const bottom = 28/);
  assert.match(appSource, /class="history-x-axis"/);
  assert.match(appSource, /historyDayDetailsMarkup[\s\S]+aria-label="Collapse day details"[\s\S]+<svg/);
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
  assert.match(styleSource, /\.listening-history-panel\s*\{[^}]*background: #090b12/);
  assert.doesNotMatch(styleSource, /--history-ambient-surface/);
  assert.doesNotMatch(historyStyleSource, /gradient\(/);
  assert.match(styleSource, /\.listening-history-panel::\-webkit-scrollbar-thumb\s*\{[^}]*background: var\(--history-scrollbar-thumb\)[^}]*box-shadow: none/);
  assert.match(styleSource, /\.history-content-toolbar\s*\{[\s\S]*?background: transparent/);
  assert.match(styleSource, /\.listening-history-stats\s*\{[\s\S]*?background: transparent/);
  assert.match(styleSource, /\.listening-history-chart\s*\{[\s\S]*?background: transparent/);
  assert.match(styleSource, /\.listening-history-day-details\s*\{[\s\S]*?background: transparent/);
  assert.doesNotMatch(styleSource, /\.listening-history-day-details\s*\{[^}]*border-top/);
  assert.match(styleSource, /\.history-window-button\s*\{[\s\S]+\.history-window-button:disabled/);
  assert.match(styleSource, /\.history-window-button\s*\{[\s\S]*?height: 32px[\s\S]*?border-radius: 6px/);
  assert.match(styleSource, /\.history-range\s*\{[\s\S]*?height: 32px[\s\S]*?border-radius: 6px/);
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
  assert.match(styleSource, /\.history-bar\s*\{[^}]*fill: var\(--history-bar-color\)/);
  assert.match(styleSource, /\.history-bar\.peak\s*\{[^}]*fill: var\(--history-peak-color\)/);
  assert.doesNotMatch(historyChartSource, /gradient/i);
  assert.doesNotMatch(styleSource, /\.history-bar(?:\.peak)?\s*\{[^}]*filter:/);
  assert.match(styleSource, /\.history-bar\.selected[\s\S]*?stroke: var\(--accent-tertiary\)/);
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
    serverURL: "https://resonance-core.blithe-haven-9710.chatgpt.site",
    syncProfileID: "music-room",
    listeningHistory: [
      { id: "first", trackID: "a", profileID: "music-room", serverOrigin: "https://resonance-core.blithe-haven-9710.chatgpt.site", startedAt: new Date(2026, 6, 30, 8, 0, 0).toISOString(), listenedSeconds: 600, duration: 240 },
      { id: "second", trackID: "b", serverOrigin: "https://resonance-core.blithe-haven-9710.chatgpt.site", startedAt: new Date(2026, 6, 29, 8, 0, 0).toISOString(), listenedSeconds: 300, duration: 240 },
      { id: "old", trackID: "c", serverOrigin: "https://resonance-core.blithe-haven-9710.chatgpt.site", startedAt: new Date(2026, 5, 1, 8, 0, 0).toISOString(), listenedSeconds: 900, duration: 240 },
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

test("counts a listening-history play only after more than ten percent", () => {
  const now = new Date(2026, 6, 30, 12, 0, 0);
  const base = {
    serverURL: "https://resonance-core.blithe-haven-9710.chatgpt.site",
    tracks: [{ id: "song", title: "Threshold", artist: "Test", duration: 200 }],
  };
  const entry = (id, listenedSeconds) => ({
    id,
    trackID: "song",
    serverOrigin: base.serverURL,
    startedAt: now.toISOString(),
    listenedSeconds,
    duration: 200,
  });
  const state = normalizeState({
    ...base,
    listeningHistory: [entry("below", 19.99), entry("exact", 20), entry("above", 20.01)],
  });

  assert.equal(listeningHistoryEntryQualifiesAsPlay(state, state.listeningHistory[0]), false);
  assert.equal(listeningHistoryEntryQualifiesAsPlay(state, state.listeningHistory[1]), false);
  assert.equal(listeningHistoryEntryQualifiesAsPlay(state, state.listeningHistory[2]), true);
  assert.equal(summarizeListeningHistory(state, 1, now).plays, 1);
  assert.equal(summarizeListeningStats(state, now).plays, 1);
  assert.equal(summarizeListeningStats(state, now).totalSeconds, 60);
});

test("merges and displays server-only listening history snapshots", () => {
  const now = new Date(2026, 6, 30, 12, 0, 0);
  const state = normalizeState({
    syncProfileID: "default",
    tracks: [],
    listeningHistory: [],
  });
  const merged = mergeListeningHistoryDocument(state, {
    profile_id: "default",
    entries: [
      {
        id: "remote-play-one",
        track_id: "windows-track-id",
        song_id: "server-song-id",
        started_at: new Date(2026, 6, 30, 8, 0, 0).toISOString(),
        listened_seconds: 90,
        title: "Server Only",
        artist: "Remote Artist",
        album: "Remote Album",
        duration_seconds: 240,
      },
      {
        id: "remote-play-two",
        track_id: "mac-track-id",
        song_id: "server-song-id",
        started_at: new Date(2026, 6, 30, 9, 0, 0).toISOString(),
        listened_seconds: 30,
        title: "Server Only",
        artist: "Remote Artist",
        album: "Remote Album",
        duration_seconds: 240,
      },
    ],
  }, "default");

  assert.equal(merged, true);
  assert.equal(state.listeningHistory.length, 2);
  assert.equal(state.listeningHistory[0].originatedOnThisDevice, false);
  assert.equal(state.listeningHistory[0].title, "Server Only");
  const summary = summarizeListeningHistory(state, 7, now);
  assert.equal(summary.songs, 1);
  assert.equal(summary.songSeries.length, 1);
  assert.equal(summary.songSeries[0].remoteID, "server-song-id");
  assert.equal(summary.songSeries[0].title, "Server Only");
  assert.equal(summary.songSeries[0].seconds, 120);
  assert.equal(summary.songSeries[0].fileUrl, null);
  const stats = summarizeListeningStats(state, now);
  assert.equal(stats.songs, 1);
  assert.equal(stats.topArtist, "Remote Artist");
  assert.equal(stats.songRanking[0].album, "Remote Album");
  assert.equal(stats.songRanking[0].seconds, 120);

  const restored = normalizeState(JSON.parse(JSON.stringify(state)));
  assert.equal(restored.listeningHistory[0].title, "Server Only");
  assert.equal(restored.listeningHistory[0].originatedOnThisDevice, false);
});

test("hydrates uninstalled listening-history songs from the server catalog", () => {
  const state = normalizeState({
    serverURL: "https://music.example",
    syncProfileID: "default",
    tracks: [],
    listeningHistory: [],
  });
  const merged = mergeListeningHistoryDocument(state, {
    profile_id: "default",
    entries: [{
      id: "catalog-history-event",
      track_id: "track-on-another-device",
      song_id: "catalog-song",
      started_at: "2026-08-16T12:00:00Z",
      listened_seconds: 45,
    }],
  }, "default", "https://music.example", [{
    id: "catalog-song",
    title: "Catalog title",
    artist: "Catalog artist",
    album: "Catalog album",
      duration_seconds: 300,
      artwork_url: "https://music.example/api/v1/songs/catalog-song/artwork?token=signed",
    }]);

  assert.equal(merged, true);
  assert.equal(state.listeningHistory[0].title, "Catalog title");
  assert.equal(state.listeningHistory[0].artist, "Catalog artist");
  assert.equal(state.listeningHistory[0].album, "Catalog album");
  assert.equal(state.listeningHistory[0].duration, 300);
  assert.equal(state.listeningHistory[0].artworkURL, "https://music.example/api/v1/songs/catalog-song/artwork?token=signed");
  assert.equal(summarizeListeningStats(state).songRanking[0].artworkURL, state.listeningHistory[0].artworkURL);
});

test("catalog placeholders never replace history metadata and resolved catalog updates apply immediately", () => {
  const state = normalizeState({
    serverURL: "https://music.example",
    syncProfileID: "default",
    tracks: [],
    listeningHistory: [{
      id: "history-event",
      trackID: "track-on-another-device",
      profileID: "default",
      serverOrigin: "https://music.example",
      startedAt: "2026-08-16T12:00:00Z",
      listenedSeconds: 45,
      remoteID: "catalog-song",
      title: "Snapshot title",
      artist: "Snapshot artist",
      album: "Snapshot album",
      duration: 200,
    }],
  });

  assert.equal(hydrateListeningHistoryFromCatalog(state, [{
    id: "catalog-song",
    title: "Resolving metadata…",
    artist: "Automatic lookup",
    album: "Link only",
  }]), false);
  assert.equal(state.listeningHistory[0].title, "Snapshot title");

  assert.equal(hydrateListeningHistoryFromCatalog(state, [{
    id: "catalog-song",
    title: "Resolved title",
    artist: "Resolved artist",
    album: "Resolved album",
    duration: 245,
    artwork_url: "https://music.example/api/v1/songs/catalog-song/artwork?token=signed",
  }]), true);
  assert.deepEqual({
    title: state.listeningHistory[0].title,
    artist: state.listeningHistory[0].artist,
    album: state.listeningHistory[0].album,
    duration: state.listeningHistory[0].duration,
    artworkURL: state.listeningHistory[0].artworkURL,
  }, {
    title: "Resolved title",
    artist: "Resolved artist",
    album: "Resolved album",
    duration: 245,
    artworkURL: "https://music.example/api/v1/songs/catalog-song/artwork?token=signed",
  });
});

test("stored catalog placeholders still require provider metadata hydration", () => {
  assert.equal(serverSongHasCatalogMetadata({
    title: "Resolving metadata…",
    artist: "Automatic lookup",
    album: "Link only",
  }), false);
  assert.equal(serverSongHasCatalogMetadata({
    title: "Resolved title",
    artist: "Resolved artist",
  }), true);
});

test("hydrates legacy listening history from one downloaded local copy without guessing", () => {
  const now = new Date(2026, 6, 30, 12, 0, 0);
  const downloaded = {
    id: "downloaded-copy",
    title: "Candle - Light/Speed (Geometry Dash / FUNHOUSE)",
    artist: "EDMS and Candle / Audio",
    album: "Current Local Metadata",
    duration: 276,
    artwork: "data:image/png;base64,iVBORw0KGgo=",
    filePath: "/music/candle-history-copy.m4a",
  };
  const historyEntry = {
    id: "legacy-play",
    trackID: "old-device-track",
    profileID: "default",
    serverOrigin: "https://resonance.example",
    remoteID: "old-server-song",
    startedAt: now.toISOString(),
    listenedSeconds: 120,
    title: "Candle - Light/Speed (Geometry Dash / FUNHOUSE)",
    artist: "Candle and EDMS / Audio",
    album: "Imported",
    duration: 276,
    originatedOnThisDevice: false,
  };
  const state = normalizeState({
    serverURL: "https://resonance.example",
    syncProfileID: "default",
    tracks: [downloaded],
    listeningHistory: [historyEntry],
  });

  const hydrated = summarizeListeningHistory(state, 1, now).songSeries[0];
  assert.equal(hydrated.trackID, downloaded.id);
  assert.equal(hydrated.artwork, downloaded.artwork);
  assert.equal(hydrated.album, downloaded.album);
  assert.equal(summarizeListeningStats(state, now).topTrackID, downloaded.id);

  state.tracks.push({
    ...downloaded,
    id: "ambiguous-copy",
    album: "Different Copy",
    filePath: "/music/candle-history-copy-2.m4a",
  });
  const unresolved = summarizeListeningHistory(state, 1, now).songSeries[0];
  assert.equal(unresolved.trackID, historyEntry.trackID);
  assert.equal(unresolved.artwork, null);
});

test("summarizes all-time listening stats independently of the graph window", () => {
  const now = new Date(2026, 6, 30, 12, 0, 0);
  const result = summarizeListeningStats({
    serverURL: "https://resonance-core.blithe-haven-9710.chatgpt.site",
    syncProfileID: "alpha-room",
    tracks: [
      { id: "a", title: "First", artist: "Alpha", duration: 240 },
      { id: "b", title: "Second", artist: "Beta", duration: 240 },
      { id: "c", title: "Other profile", artist: "Gamma", duration: 240 },
    ],
    listeningHistory: [
      { trackID: "a", profileID: "alpha-room", serverOrigin: "https://resonance-core.blithe-haven-9710.chatgpt.site", startedAt: new Date(2026, 6, 29, 10, 0, 0).toISOString(), listenedSeconds: 120 },
      { trackID: "a", profileID: "alpha-room", serverOrigin: "https://resonance-core.blithe-haven-9710.chatgpt.site", startedAt: new Date(2026, 6, 30, 8, 0, 0).toISOString(), listenedSeconds: 60 },
      { trackID: "b", profileID: "alpha-room", serverOrigin: "https://resonance-core.blithe-haven-9710.chatgpt.site", startedAt: new Date(2026, 6, 30, 9, 0, 0).toISOString(), listenedSeconds: 30 },
      { trackID: "c", profileID: "other-room", serverOrigin: "https://resonance-core.blithe-haven-9710.chatgpt.site", startedAt: new Date(2026, 6, 30, 10, 0, 0).toISOString(), listenedSeconds: 900 },
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
    serverURL: "https://resonance-core.blithe-haven-9710.chatgpt.site",
    listeningHistory: [
      { id: "current-day", trackID: "a", serverOrigin: "https://resonance-core.blithe-haven-9710.chatgpt.site", startedAt: new Date(2026, 6, 30, 11, 10, 0).toISOString(), listenedSeconds: 120, duration: 240 },
      { id: "current-morning", trackID: "b", serverOrigin: "https://resonance-core.blithe-haven-9710.chatgpt.site", startedAt: new Date(2026, 6, 30, 1, 30, 0).toISOString(), listenedSeconds: 180, duration: 240 },
      { id: "previous-day", trackID: "c", serverOrigin: "https://resonance-core.blithe-haven-9710.chatgpt.site", startedAt: new Date(2026, 6, 29, 23, 15, 0).toISOString(), listenedSeconds: 300, duration: 240 },
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

test("selects the newest stable or timestamped prerelease Windows update feed", async () => {
  const releases = [
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
      {
        name: "Repeated beta title",
        tag_name: "v1.0.4-pre.1788150123",
        draft: false,
        prerelease: true,
        assets: [{ name: "latest.yml", browser_download_url: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.0.4-pre.1788150123/latest.yml" }],
      },
      {
        name: "Repeated beta title",
        tag_name: "v1.0.4-pre.1788154123",
        draft: false,
        prerelease: true,
        assets: [{ name: "latest.yml", browser_download_url: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.0.4-pre.1788154123/latest.yml" }],
      },
    ];
  const fetchImpl = async (url) => {
    const href = String(url);
    if (href.includes("api.github.com")) {
      return { ok: true, status: 200, headers: { get: () => null }, json: async () => releases };
    }
    const tag = href.match(/\/download\/(v[^/]+)\/latest\.yml$/)?.[1];
    const parsed = parseWindowsReleaseTag(tag);
    return {
      ok: true,
      status: 200,
      headers: { get: () => null },
      text: async () => `version: ${parsed.effectiveVersion}\nresonanceBuild: ${tag.includes("4123") ? 22 : 21}\n`,
    };
  };

  const selected = await resolveWindowsUpdateFeed(fetchImpl, { prerelease: true });
  assert.equal(selected.tag, "v1.0.4-pre.1788154123");
  assert.equal(selected.version, "1.0.4-pre.1788154123");
  assert.equal(selected.build, 22);
  assert.equal(selected.feedURL, "https://github.com/Drastics-Experiments/resonance/releases/download/v1.0.4-pre.1788154123/");
  assert.equal(selectNewestWindowsRelease([selected, { tag: "v1.0.4-pre.1788150123", build: 21 }]), selected);
});

test("developer update feeds select prereleases with the required platform manifest", async () => {
  const releases = [
    {
      tag_name: "v1.3.0-pre.1788159123",
      draft: true,
      prerelease: true,
      assets: [
        { name: "latest.yml", browser_download_url: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.3.0-pre.1788159123/latest.yml" },
      ],
    },
    {
      tag_name: "v1.2.1-pre.1788158123",
      draft: false,
      prerelease: true,
      assets: [{ name: "notes.txt", browser_download_url: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.2.1-pre.1788158123/notes.txt" }],
    },
    {
      tag_name: "v1.1.0",
      draft: false,
      prerelease: false,
      assets: [
        { name: "latest.yml", browser_download_url: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.1.0/latest.yml" },
        { name: "latest-mac.json", browser_download_url: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.1.0/latest-mac.json" },
      ],
    },
    {
      tag_name: "v1.2.0-pre.1788154123",
      draft: false,
      prerelease: true,
      assets: [
        { name: "latest.yml", browser_download_url: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.2.0-pre.1788154123/latest.yml" },
        { name: "latest-mac.json", browser_download_url: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.2.0-pre.1788154123/latest-mac.json" },
      ],
    },
  ];
  const fetchImpl = async (url) => String(url).endsWith("latest.yml")
    ? { ok: true, text: async () => `version: ${String(url).includes("pre.1788154123") ? "1.2.0-pre.1788154123" : "1.1.0"}\nresonanceBuild: 21\n` }
    : { ok: true, json: async () => releases };
  assert.deepEqual(await resolveWindowsUpdateFeed(fetchImpl, { prerelease: true }), {
    tag: "v1.2.0-pre.1788154123",
    feedURL: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.2.0-pre.1788154123/",
    version: "1.2.0-pre.1788154123",
    baseVersion: "1.2.0",
    build: 21,
    prerelease: true,
    sourceTimestamp: 1788154123,
  });
  assert.deepEqual(await resolveMacUpdateManifest(fetchImpl, { prerelease: true }), {
    tag: "v1.2.0-pre.1788154123",
    manifestURL: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.2.0-pre.1788154123/latest-mac.json",
  });
  assert.deepEqual(await resolveWindowsUpdateFeed(fetchImpl), {
    tag: "v1.1.0",
    feedURL: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.1.0/",
    version: "1.1.0",
    baseVersion: "1.1.0",
    build: 21,
    prerelease: false,
    sourceTimestamp: null,
  });

  const unsafeFetch = async () => ({
    ok: true,
    json: async () => [{
      tag_name: "v9.0.0-pre.1788159123",
      draft: false,
      prerelease: true,
      assets: [{ name: "latest.yml", browser_download_url: "https://evil.example/latest.yml" }],
    }],
  });
  await assert.rejects(
    resolveWindowsUpdateFeed(unsafeFetch, { prerelease: true }),
    /No published prerelease contains latest\.yml/,
  );
});

test("developer source builds can scan a bounded Windows manifest without installing", async () => {
  const fetchImpl = async () => ({
    ok: true,
    text: async () => "version: 2.1.0-beta.3\npath: Resonance-Setup-2.1.0-beta.3.exe\n",
  });
  assert.equal(
    await fetchWindowsUpdateVersion(
      "https://github.com/Drastics-Experiments/resonance/releases/download/v2.1.0-beta.3/latest.yml",
      fetchImpl,
    ),
    "2.1.0-beta.3",
  );
  await assert.rejects(
    fetchWindowsUpdateVersion("https://evil.example/latest.yml", fetchImpl),
    /unsafe/,
  );
});

test("rejects release lists without a Windows manifest and shortens updater errors", async () => {
  const fetchImpl = async () => ({
    ok: true,
    status: 200,
    headers: { get: () => null },
    json: async () => [{ tag_name: "android-v1.0.4", assets: [] }],
  });
  await assert.rejects(resolveWindowsUpdateFeed(fetchImpl), /No published stable release contains latest\.yml/);
  assert.equal(
    conciseUpdaterError(new Error("Cannot find latest.yml: 404 Not Found\nvery long response headers and stack")),
    "The Windows update feed is temporarily unavailable.",
  );
});

test("installs downloaded Windows updates silently in place", () => {
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const readmeSource = readFileSync(new URL("../../installers/windows/README.md", import.meta.url), "utf8");
  let installArguments = null;
  assert.equal(installDownloadedWindowsUpdate({
    quitAndInstall(...values) { installArguments = values; },
  }), true);
  assert.deepEqual(installArguments, [true, true]);
  assert.match(mainSource, /autoUpdater\.autoDownload = true/);
  assert.match(mainSource, /autoUpdater\.allowPrerelease = true/);
  assert.match(mainSource, /allowDowngrade = developerMode[\s\S]+candidate\.prerelease[\s\S]+app\.getVersion\(\) === candidate\.baseVersion/);
  assert.match(mainSource, /autoUpdater\.autoInstallOnAppQuit = false/);
  assert.match(mainSource, /verifyDownloadedWindowsUpdate\(\{[\s\S]+downloadedFile: information\?\.downloadedFile[\s\S]+authenticityMode: desktopPackage\.resonanceUpdateAuthenticity/);
  assert.match(mainSource, /verifiedWindowsUpdate\.generation !== desktopUpdateChannel\.capture\(\)[\s\S]+windowsUpdateVerificationPromise/);
  assert.match(mainSource, /installDownloadedWindowsUpdate\(autoUpdater\)/);
  assert.doesNotMatch(mainSource, /autoUpdater\.quitAndInstall\(false, true\)/);
  assert.match(appSource, /Restarting to finish the update/);
  assert.match(appSource, /id="settingsCheckForUpdates"[\s\S]+Check now/);
  assert.match(appSource, /settingsCheckForUpdates"\)\.onclick = checkForUpdates/);
  assert.match(appSource, /const status = result\.status \|\| await api\.getUpdateStatus\(\)/);
  assert.match(appSource, /Updates are checked automatically/);
  assert.match(appSource, /Check GitHub prereleases instead of stable releases[\s\S]+id="settingsDeveloperMode"/);
  assert.match(mainSource, /resolveWindowsUpdateFeed\(fetch, \{[\s\S]+prerelease: developerMode/);
  assert.match(mainSource, /const developerMode = runtimeAppPreferences\.developerMode[\s\S]+autoUpdater\.allowPrerelease = developerMode/);
  assert.match(mainSource, /resolveMacUpdateManifest\(fetch, \{ prerelease: true \}\)/);
  assert.match(mainSource, /app\.isPackaged \|\| runtimeAppPreferences\.developerMode/);
  assert.match(mainSource, /scanOnly: true/);
  assert.match(mainSource, /desktopUpdateChannel\.invalidate\(\)[\s\S]+windowsUpdateCancellation\?\.token\?\.cancel\(\)/);
  assert.match(mainSource, /const verificationPromise = windowsUpdateVerificationPromise;[\s\S]+if \(verificationPromise\) await verificationPromise;[\s\S]+if \(!desktopUpdateChannel\.isCurrent\(generation\)\) return null/);
  assert.match(mainSource, /publishUpdateStatusForGeneration\(generation, "ready"/);
  assert.match(mainSource, /macUpdateArtifactGeneration !== generation/);
  assert.match(mainSource, /authorizeInstall: \(\) => desktopUpdateChannel\.isCurrent\(generation\)/);
  assert.match(htmlSource, /Restart &amp; update/);
  assert.match(readmeSource, /runs the verified NSIS update silently/);
  assert.match(readmeSource, /does not show the setup wizard/);
});

test("checks automatically and shows a dismissible top-right Windows update badge", () => {
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const preloadSource = readFileSync(new URL("../preload.cjs", import.meta.url), "utf8");
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");

  assert.match(mainSource, /AUTOMATIC_UPDATE_CHECK_INTERVAL_MS = 5 \* 60 \* 1000/);
  assert.match(mainSource, /function startAutomaticUpdateChecks\(\)[\s\S]+setInterval\(runAutomaticUpdateCheck, AUTOMATIC_UPDATE_CHECK_INTERVAL_MS\)/);
  assert.match(mainSource, /app:preferences:update[\s\S]+runtimeAppPreferencesLoaded = true;[\s\S]+startAutomaticUpdateChecks\(\)/);
  assert.doesNotMatch(mainSource, /createWindow\(\);\s*startAutomaticUpdateChecks\(\)/);
  assert.match(mainSource, /\["available", "downloading", "ready"\]\.includes\(currentWindowsUpdateStatus\.type\)/);
  assert.match(mainSource, /ipcMain\.handle\("update:state", \(\) => currentWindowsUpdateStatus\)/);
  assert.match(preloadSource, /getUpdateStatus: \(\) => ipcRenderer\.invoke\("update:state"\)/);
  assert.match(htmlSource, /id="updateAvailableBadge"[\s\S]+Update Available[\s\S]+id="updateAvailableAction"[\s\S]+id="dismissUpdateAvailable"/);
  assert.match(styleSource, /\.update-available-badge\s*\{[\s\S]+top: 94px;[\s\S]+right: 18px;/);
  assert.match(appSource, /function syncWindowsUpdateBadge\(value = \{\}\)[\s\S]+value\.type === "ready"[\s\S]+Restart to update/);
  assert.match(appSource, /dismissedWindowsUpdateVersion = availableWindowsUpdateVersion;[\s\S]+updateAvailableBadge"\)\.hidden = true/);
  assert.match(appSource, /api\.onUpdateStatus\(handleWindowsUpdateStatus\)[\s\S]+await api\.getUpdateStatus\(\)/);
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
    { id: "b", title: "Ping", artist: "Server", album: "Remote", filePath: "C:\\Music\\ping.mp4", fileUrl: "file:///C:/Music/ping.mp4", dateAdded: "2026-02-01T00:00:00Z" },
  ];
  assert.deepEqual(filterTracks(tracks, "remote").map((track) => track.id), ["b"]);
  assert.deepEqual(filterTracks(tracks, "glass.mp3").map((track) => track.id), ["a"]);
  assert.deepEqual(filterTracks(tracks, "", "audio").map((track) => track.id), ["a"]);
  assert.deepEqual(filterTracks(tracks, "", "video").map((track) => track.id), ["b"]);
  assert.deepEqual(filterTracks(tracks, "", "recent").map((track) => track.id), ["b", "a"]);
  assert.equal(nextIndex(tracks, "a", 1), 1);
  assert.equal(nextIndex(tracks, "a", -1), 1);
  assert.equal(nextIndex(tracks, "b", 1), 0);
  assert.deepEqual(shuffledTrackIDs(tracks, "a", () => 0), ["a", "b"]);
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

test("scopes downloaded tracks by both server and profile", () => {
  const state = normalizeState({
    ...createEmptyState(),
    serverURL: "https://current.example/api/",
    syncProfileID: "profile-a",
    tracks: [
      { id: "local", title: "Local" },
      { id: "active", remoteID: "same-song", sourceServer: "https://current.example", syncProfileID: "profile-a" },
      { id: "other-profile", remoteID: "same-song", sourceServer: "https://current.example", syncProfileID: "profile-b" },
      { id: "other-server", remoteID: "same-song", sourceServer: "https://other.example", syncProfileID: "profile-a" },
    ],
    playlists: [{ id: "liked", name: "Liked Songs", trackIDs: [], isSystem: true }],
    favorites: [],
  });

  assert.deepEqual(state.tracks.map((track) => track.id), ["local", "active", "other-profile", "other-server"]);
  assert.deepEqual(tracksForActiveProfile(state).map((track) => track.id), ["local", "active"]);
});

test("preserves unsynced playlist state across profile switches", () => {
  const state = normalizeState({
    ...createEmptyState(),
    serverURL: "https://music.example",
    syncProfileID: "profile-a",
  });
  state.playlists.push({ id: "offline-mix", name: "Offline Mix", trackIDs: [], remoteSongIDs: [], isSystem: false });
  state.dirtyPlaylistIDs = ["offline-mix"];
  storeActiveProfileState(state);

  restoreProfileState(state, "profile-b");
  assert.deepEqual(state.playlists.map((playlist) => playlist.id), ["liked"]);
  state.playlists.push({ id: "profile-b-mix", name: "Profile B Mix", trackIDs: [], remoteSongIDs: [], isSystem: false });
  state.dirtyPlaylistIDs = ["profile-b-mix"];
  storeActiveProfileState(state);

  restoreProfileState(state, "profile-a");
  assert.deepEqual(state.playlists.map((playlist) => playlist.id), ["liked", "offline-mix"]);
  assert.deepEqual(state.dirtyPlaylistIDs, ["offline-mix"]);
});

test("moves the confirmed legacy device context to its Clerk account without touching other profiles", () => {
  const serverURL = "https://music.example";
  const oldKey = "https://music.example#profile=default";
  const nextKey = "https://music.example#profile=user_listener";
  const state = normalizeState({
    ...createEmptyState(),
    serverURL,
    syncProfileID: "default",
    tracks: [
      { id: "migrated", remoteID: "song-a", sourceServer: serverURL, syncProfileID: "default" },
      { id: "other", remoteID: "song-b", sourceServer: serverURL, syncProfileID: "family" },
    ],
    playlists: [
      { id: "liked", name: "Liked Songs", trackIDs: ["migrated"], isSystem: true },
      { id: "mix", name: "Mix", trackIDs: ["migrated"], remoteSongIDs: ["song-a"], isSystem: false },
    ],
    favorites: ["migrated"],
    playlistSyncServerURL: oldKey,
    dirtyPlaylistIDs: ["mix"],
    listeningHistory: [{
      id: "play-a",
      trackID: "migrated",
      profileID: "default",
      serverOrigin: serverURL,
      startedAt: new Date().toISOString(),
      listenedSeconds: 30,
    }],
    serverTransferPreferences: { [oldKey]: { uploadMode: "server_source_link", downloadMode: "stream_only" } },
  });

  assert.equal(migrateProfileContext(state, serverURL, "default", "user_listener"), true);
  assert.equal(state.syncProfileID, "user_listener");
  assert.equal(state.tracks[0].syncProfileID, "user_listener");
  assert.equal(state.tracks[1].syncProfileID, "family");
  assert.equal(state.listeningHistory[0].profileID, "user_listener");
  assert.equal(state.playlistSyncServerURL, nextKey);
  assert.deepEqual(state.profileStates[nextKey].dirtyPlaylistIDs, ["mix"]);
  assert.equal(state.profileStates[oldKey], undefined);
  assert.deepEqual(state.serverTransferPreferences[nextKey], {
    uploadMode: "server_source_link",
    downloadMode: "stream_only",
  });
  assert.equal(state.serverTransferPreferences[oldKey], undefined);
  assert.equal(migrateProfileContext(state, serverURL, "default", "user_listener"), false);
});

test("keeps clip ranges profile specific and migrates local ranges after upload", () => {
  const track = { id: "local-track", title: "Range", duration: 120 };
  const state = normalizeState({
    ...createEmptyState(),
    serverURL: "https://music.example",
    syncProfileID: "profile-a",
    tracks: [track],
  });
  assert.deepEqual(setClipRangeForTrack(state, track, 12.5, 41.25), {
    startSeconds: 12.5,
    endSeconds: 41.25,
  });
  assert.deepEqual(playbackRangeForTrack(state, track), { startSeconds: 12.5, endSeconds: 41.25 });
  storeActiveProfileState(state);

  restoreProfileState(state, "profile-b");
  assert.equal(playbackRangeForTrack(state, track), null);
  restoreProfileState(state, "profile-a");
  assert.deepEqual(playbackRangeForTrack(state, track), { startSeconds: 12.5, endSeconds: 41.25 });

  assert.equal(reconcileUploadedTrack(state, track.id, { id: "server-song" }, {
    profileID: "profile-a",
    serverURL: "https://music.example",
  }), true);
  assert.deepEqual(state.clipRanges["remote:server-song"], { startSeconds: 12.5, endSeconds: 41.25 });
  assert.deepEqual(state.dirtyClipRangeKeys, ["remote:server-song"]);
  assert.equal(state.clipRanges["local:local-track"], undefined);
});

test("guards profile transitions, authenticated downloads, persistence, and transfer memory", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const packageJSON = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
  const syncSource = mainSource.slice(mainSource.indexOf('ipcMain.handle("server:sync"'), mainSource.indexOf('ipcMain.handle("server:upload"'));
  const uploadSource = mainSource.slice(mainSource.indexOf('ipcMain.handle("server:upload"'), mainSource.indexOf('ipcMain.handle("server:cancel-transfer"'));

  assert.match(appSource, /storeActiveProfileState\(state\);[\s\S]+restoreProfileState\(state, profileID, serverURL\)/);
  assert.match(appSource, /if \(!profileContextIsCurrent\(context\)\) return;/);
  assert.match(appSource, /serverConnected = false;[\s\S]+replaceServerCatalog\(\[\]\);[\s\S]+selectedRemoteIDs\.clear\(\)/);
  assert.match(appSource, /updatePlaylistRemoteSongIDs\(state, playlist\);[\s\S]+markPlaylistDirty\(playlist\)/);
  assert.match(mainSource, /app\.requestSingleInstanceLock\(\)/);
  assert.match(mainSource, /function atomicWriteFile\([\s\S]+fs\.rename\(temporary, destination\)/);
  assert.match(mainSource, /function sameOriginServerMediaURL\([\s\S]+url\.origin !== base\.origin/);
  assert.match(syncSource, /sameOriginServerMediaURL\(mediaLocation\?\.download_url \|\| song\.download_url/);
  assert.match(syncSource, /redirect: "manual"/);
  assert.match(syncSource, /syncProfileID \|\| "default"\) === \(profileID \|\| "default"\)/);
  assert.match(syncSource, /if \(alreadyDownloaded\) continue;/);
  assert.doesNotMatch(syncSource, /if \(alreadyDownloaded\) return/);
  assert.match(syncSource, /writeResponseToFile\(response, temporary/);
  assert.doesNotMatch(syncSource, /response\.arrayBuffer\(\)/);
  assert.doesNotMatch(uploadSource, /createReadStream\(filePath\)|duplex: "half"/);
  assert.match(uploadSource, /putSourceLinkRegistration\(\{[\s\S]+"Content-Type": "application\/json"[\s\S]+item,/);
  assert.doesNotMatch(uploadSource, /fs\.readFile\(filePath\)/);
  assert.match(uploadSource, /managedRoots = \[paths\.local, paths\.remote\]/);
  assert.match(uploadSource, /isManagedLibraryFile\(item\.filePath, managedRoots\)/);
  assert.ok(packageJSON.build.files.includes("library-paths.cjs"));
  assert.match(packageJSON.scripts["package:win"], /electron-builder --dir --win --x64/);
});

test("retries individual server downloads and reports every song that still fails", async () => {
  let transientAttempts = 0;
  const retried = [];
  const transientResult = await retryServerDownload(async () => {
    transientAttempts += 1;
    if (transientAttempts < SERVER_DOWNLOAD_ATTEMPTS) throw new Error("temporary failure");
    return "downloaded";
  }, {
    pause: async () => undefined,
    onRetry: ({ nextAttempt }) => retried.push(nextAttempt),
  });
  assert.equal(transientResult, "downloaded");
  assert.equal(transientAttempts, 3);
  assert.deepEqual(retried, [2, 3]);

  let permanentAttempts = 0;
  await assert.rejects(retryServerDownload(async () => {
    permanentAttempts += 1;
    throw new Error("still unavailable");
  }, { pause: async () => undefined }), /still unavailable/);
  assert.equal(permanentAttempts, 3);

  let revokedAttempts = 0;
  await assert.rejects(retryServerDownload(async () => {
    revokedAttempts += 1;
    const error = new Error("download policy revoked");
    error.retryable = false;
    throw error;
  }, { pause: async () => undefined }), /download policy revoked/);
  assert.equal(revokedAttempts, 1);

  const controller = new AbortController();
  let cancelledAttempts = 0;
  await assert.rejects(retryServerDownload(async () => {
    cancelledAttempts += 1;
    throw new Error("temporary failure");
  }, {
    signal: controller.signal,
    pause: async () => undefined,
    onRetry: () => controller.abort(new DOMException("Download cancelled", "AbortError")),
  }), { name: "AbortError" });
  assert.equal(cancelledAttempts, 1);

  assert.equal(
    formatServerDownloadFailureNotice([
      { title: "Glass", artist: "Alice" },
      { filename: "Ping.mp3" },
    ]),
    "2 songs failed to download after retrying: “Glass” — Alice; “Ping.mp3”.",
  );

  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const packageJSON = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));
  const syncSource = mainSource.slice(mainSource.indexOf('ipcMain.handle("server:sync"'), mainSource.indexOf('ipcMain.handle("server:upload"'));
  assert.match(syncSource, /retryServerDownload/);
  assert.match(syncSource, /const pendingDownloads = \[\][\s\S]+if \(alreadyDownloaded\) continue;[\s\S]+itemCount = pendingDownloads\.length/);
  assert.match(syncSource, /failed\.push\(\{/);
  assert.match(syncSource, /return \{ catalog, downloaded, replacedTrackIDs, failed \}/);
  assert.match(appSource, /showNotice\(formatServerDownloadFailureNotice\(failedDownloads\)\)/);
  assert.ok(packageJSON.build.files.includes("server-download.cjs"));
});

test("shows catalog song titles instead of internal server download filenames", () => {
  assert.equal(
    serverDownloadDisplayName({
      title: "Actual Song Name",
      name: "Track-0ae24d3e-3e34-4230-9775-39eb40a744d8.mp3",
      filename: "Track-0ae24d3e-3e34-4230-9775-39eb40a744d8.mp3",
    }, "Track-0ae24d3e-3e34-4230-9775-39eb40a744d8.mp3"),
    "Actual Song Name",
  );
  assert.equal(serverDownloadDisplayName({ title: "  Trimmed Name  " }, "Track-id.mp3"), "Trimmed Name");
  assert.equal(serverDownloadDisplayName({ name: "Track-id.mp3" }, "Track-id.mp3", "Resolved Legacy Song"), "Resolved Legacy Song");
  assert.equal(serverDownloadDisplayName({ name: "Track-id.mp3" }), "Untitled song");

  assert.deepEqual(serverDownloadProgressEvent({
    song: { id: "song-a", filename: "5wxQw7ll2TSFbwjaQcoJVB.m4a" },
    preferredTitle: "Nevada",
    itemIndex: 3,
    itemCount: 10,
    completedBytes: 42,
    totalBytes: 100,
    completedItems: 2,
  }), {
    direction: "download",
    currentFile: "Nevada",
    completed: 2,
    total: 10,
    itemCompleted: 42,
    itemTotal: 100,
    itemIndex: 3,
    itemCount: 10,
    title: undefined,
    autoHide: false,
  });
  assert.deepEqual(
    serverTransferProgressPresentation({
      completed: 7,
      total: 10,
      itemCompleted: 42,
      itemTotal: 100,
      itemIndex: 3,
      itemCount: 10,
    }),
    { ratio: 0.42, counter: "3/10", determinate: true, label: "42% · 3/10" },
  );
  assert.deepEqual(serverTransferProgressPresentation({
    completed: 7,
    total: 10,
    itemCompleted: 0,
    itemTotal: 100,
    itemIndex: 4,
    itemCount: 10,
  }), {
    ratio: null,
    counter: "4/10",
    determinate: false,
    label: "4/10",
  });
  assert.equal(serverTransferProgressPresentation({
    itemCompleted: 1,
    itemTotal: 10_000,
    itemIndex: 1,
    itemCount: 1,
  }).label, "<1% · 1/1");
  assert.equal(serverTransferProgressPresentation({
    itemCompleted: 512,
    itemTotal: 0,
    itemIndex: 1,
    itemCount: 2,
  }).label, "Downloading · 1/2");
});

test("server downloads prefer already-hydrated catalog metadata", () => {
  const sourceURL = "https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8";
  assert.deepEqual(serverDownloadMetadata({
    title: "Catalog placeholder",
    artist: "Automatic lookup",
    album: "Link only",
    duration_seconds: 10,
    artwork_url: "https://server.example/old.jpg",
    source_url: sourceURL,
  }, {
    title: "Hydrated title",
    artist: "Hydrated artist",
    album: "Hydrated album",
    duration: 42,
    artworkURL: "https://i.scdn.co/image/current",
  }), {
    title: "Hydrated title",
    artist: "Hydrated artist",
    album: "Hydrated album",
    durationSeconds: 42,
    artworkURL: "https://i.scdn.co/image/current",
    sourceURL,
  });
  const snapshot = serverDownloadMetadataSnapshot({
    title: "Hydrated title",
    artist: "Hydrated artist",
    resolved: true,
    sourceURL,
    mediaKind: "audio",
  });
  const freshSong = { source_url: sourceURL, media_kind: "audio" };
  assert.equal(serverDownloadMetadataContextMatches(freshSong, snapshot), true);
  assert.equal(serverDownloadMetadataIsResolved(freshSong, snapshot), true);
  assert.equal(serverDownloadMetadataIsResolved(freshSong, {
    ...snapshot,
    sourceURL: "https://open.spotify.com/track/11dFghVXANMlKmJXsNCbNl",
  }), false);
  assert.equal(serverDownloadMetadataIsResolved(freshSong, {
    ...snapshot,
    mediaKind: "video",
  }), false);
  assert.equal(serverDownloadMetadataIsResolved(freshSong, serverDownloadMetadataSnapshot({
    title: "Resolving metadata…",
    artist: "Automatic lookup",
    resolved: false,
    sourceURL,
    mediaKind: "audio",
  })), false);
});

test("server catalog snapshots replace and invalidate only within their exact owner context", () => {
  const snapshots = createServerCatalogSnapshotStore();
  const context = {
    origin: "https://music.test",
    profileID: "profile-a",
    credentialFingerprint: "credential-a",
  };
  const first = { songs: [{ id: "first" }] };
  const replacement = { songs: [{ id: "replacement" }] };
  snapshots.remember(7, context, first);
  assert.equal(snapshots.read(7, context), first);
  assert.equal(snapshots.read(8, context), null);
  assert.equal(snapshots.read(7, { ...context, origin: "https://other.test" }), null);
  assert.equal(snapshots.read(7, { ...context, profileID: "profile-b" }), null);
  assert.equal(snapshots.read(7, { ...context, credentialFingerprint: "credential-b" }), null);
  snapshots.remember(7, context, replacement);
  assert.equal(snapshots.read(7, context), replacement);
  const secondCredentialContext = { ...context, credentialFingerprint: "credential-b" };
  const otherProfileContext = { ...context, profileID: "profile-b" };
  const otherOriginContext = { ...context, origin: "https://other.test" };
  snapshots.remember(8, secondCredentialContext, first);
  snapshots.remember(9, otherProfileContext, first);
  snapshots.remember(10, otherOriginContext, first);
  assert.equal(snapshots.clearContext(context), 2);
  assert.equal(snapshots.read(7, context), null);
  assert.equal(snapshots.read(8, secondCredentialContext), null);
  assert.equal(snapshots.read(9, otherProfileContext), first);
  assert.equal(snapshots.read(10, otherOriginContext), first);
  snapshots.remember(7, context, replacement);
  snapshots.clear(7);
  assert.equal(snapshots.read(7, context), null);
});

test("server SoundCloud downloads carry their prepared rendition into the exact import context", () => {
  const mainSource = readFileSync(new URL("../main.cjs", import.meta.url), "utf8");
  const start = mainSource.indexOf("async function downloadSavedSourceSong");
  const end = mainSource.indexOf('ipcMain.handle("server:sync"', start);
  const downloadSource = mainSource.slice(start, end);
  assert.match(downloadSource, /preparationContext = JSON\.stringify\(\{[\s\S]+serverOrigin:[\s\S]+profileID:[\s\S]+songID:/);
  assert.match(downloadSource, /resolveLocalImportDownloadSource\([\s\S]+\{ mediaKind, preparationContext \},?[\s\S]*\)/);
  assert.match(downloadSource, /preparedSoundCloudAudio: candidate\.preparedSoundCloudAudio/);
  assert.match(downloadSource, /preparationContext,[\s\S]+existing: options\.existing/);
  assert.match(downloadSource, /const metadataEnrichment = options\.metadataIsResolved[\s\S]+resolveLocalImportMetadata/);
  assert.match(downloadSource, /metadataSnapshot,[\s\S]+preparedSoundCloudAudio/);
  assert.match(downloadSource, /finally \{[\s\S]+metadataController\.abort\(\);[\s\S]+void metadataEnrichment\.then/);
  assert.doesNotMatch(downloadSource, /const metadata = await completedMetadata/);
});

test("unresolved fallback metadata cannot be overwritten by stale display metadata", () => {
  const resolved = {
    title: "Fresh resolver title",
    artist: "Fresh resolver artist",
    album: "Fresh resolver album",
    durationSeconds: 210,
  };
  const stale = {
    title: "Resolving metadata…",
    artist: "Automatic lookup",
    album: "Link only",
  };
  assert.deepEqual(
    serverDownloadImportedMetadata(resolved, stale, false, "https://youtu.be/jNQXAC9IVRw"),
    { ...resolved, sourceURL: "https://youtu.be/jNQXAC9IVRw" },
  );
  assert.deepEqual(
    serverDownloadImportedMetadata(resolved, {
      title: "Hydrated title",
      artist: "Hydrated artist",
    }, true, "https://youtu.be/jNQXAC9IVRw"),
    {
      ...resolved,
      title: "Hydrated title",
      artist: "Hydrated artist",
      sourceURL: "https://youtu.be/jNQXAC9IVRw",
    },
  );
});

test("throttles current-song progress while always publishing its initial and final values", () => {
  let timestamp = 0;
  const published = [];
  const publish = createServerDownloadProgressPublisher((event) => published.push(event.itemCompleted), {
    now: () => timestamp,
    minimumInterval: 100,
  });
  const event = (itemCompleted) => ({ itemCompleted, itemTotal: 1_000 });

  assert.equal(publish(event(0)), true);
  timestamp = 10;
  assert.equal(publish(event(100)), false);
  timestamp = 100;
  assert.equal(publish(event(200)), true);
  timestamp = 101;
  assert.equal(publish(event(1_000)), true);
  assert.deepEqual(published, [0, 200, 1_000]);
});

test("a failed attempt hides stale bytes and the retry publishes only its first new byte", async () => {
  let attempt = 0;
  let visibleBytes = null;
  const published = [];
  const publish = createServerDownloadProgressPublisher((event) => {
    visibleBytes = event.itemCompleted;
    published.push({ attempt, bytes: event.itemCompleted });
  }, {
    now: () => 0,
    minimumInterval: 100,
  });

  await retryServerDownload(async () => {
    attempt += 1;
    if (attempt === 1) {
      publish({ itemCompleted: 320, itemTotal: 1_000 }, { force: true });
      throw new Error("mid-stream failure");
    }
    assert.equal(visibleBytes, null);
    assert.equal(publish({ itemCompleted: 24, itemTotal: 1_000 }), true);
    return true;
  }, {
    attempts: 2,
    pause: async () => assert.equal(visibleBytes, null),
    onRetry: () => {
      visibleBytes = null;
      publish.reset();
    },
  });

  assert.deepEqual(published, [
    { attempt: 1, bytes: 320 },
    { attempt: 2, bytes: 24 },
  ]);
});

test("a permanently failed item drops its partial bytes before the next item or final reconciliation", async () => {
  const visible = [];
  const checkpoints = [];
  const runFailedItem = async (label) => {
    let visibleBytes = null;
    const publish = createServerDownloadProgressPublisher((event) => {
      visibleBytes = event.itemCompleted;
      visible.push({ label, bytes: visibleBytes });
    }, {
      now: () => 0,
      minimumInterval: 100,
    });
    const dismiss = () => {
      visibleBytes = null;
      publish.reset();
    };

    try {
      await retryServerDownload(async () => {
        publish({ itemCompleted: 640, itemTotal: 1_000 }, { force: true });
        throw new Error("permanent mid-stream failure");
      }, {
        attempts: 2,
        pause: async () => assert.equal(visibleBytes, null),
        onRetry: dismiss,
      });
    } catch (error) {
      dismiss();
      checkpoints.push({ label, visibleBytes, message: error.message });
    }
  };

  await runFailedItem("first");
  checkpoints.push({ label: "next-item-discovery", visibleBytes: null });
  await runFailedItem("last");
  checkpoints.push({ label: "final-reconciliation", visibleBytes: null });

  assert.deepEqual(visible, [
    { label: "first", bytes: 640 },
    { label: "first", bytes: 640 },
    { label: "last", bytes: 640 },
    { label: "last", bytes: 640 },
  ]);
  assert.deepEqual(checkpoints, [
    { label: "first", visibleBytes: null, message: "permanent mid-stream failure" },
    { label: "next-item-discovery", visibleBytes: null },
    { label: "last", visibleBytes: null, message: "permanent mid-stream failure" },
    { label: "final-reconciliation", visibleBytes: null },
  ]);
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
    downloaded: [{ id: "stale", remoteID: "remote-1", sourceServer: state.serverURL, syncProfileID: "default", title: "Fresh copy" }],
  });
  assert.deepEqual(state.tracks.map((track) => track.id), ["local", "stale"]);
  assert.deepEqual(state.favorites, ["stale"]);
  assert.deepEqual(state.playlists.find((playlist) => playlist.id === "mix").trackIDs, ["stale", "local"]);
});

test("uploaded local tracks adopt server identity and preserve every client reference", () => {
  const state = createEmptyState();
  state.tracks = [
    { id: "local", title: "Shared", remoteID: null, size: 42, contentSha256: "same-hash" },
    {
      id: "server-copy",
      title: "Shared",
      remoteID: "remote-song",
      sourceServer: "https://resonance-core.blithe-haven-9710.chatgpt.site",
      syncProfileID: "default",
      size: 42,
      contentSha256: "same-hash",
    },
  ];
  state.playlists.push({
    id: "12345678-1234-abcd-9876-abcdef123456",
    name: "Shared mix",
    trackIDs: ["local", "server-copy"],
    remoteSongIDs: [],
    isSystem: false,
  });
  state.favorites = ["server-copy"];
  state.currentTrackID = "server-copy";
  state.playbackQueueIDs = ["server-copy", "local"];
  state.listeningHistory = [{
    id: "history",
    trackID: "server-copy",
    profileID: "default",
    startedAt: "2026-08-03T00:00:00.000Z",
    listenedSeconds: 12,
  }];

  assert.equal(reconcileUploadedTrack(state, "local", { id: "remote-song" }, {
    serverURL: "https://resonance-core.blithe-haven-9710.chatgpt.site",
    profileID: "default",
  }), true);
  assert.deepEqual(state.tracks.map((track) => track.id), ["local"]);
  assert.equal(state.tracks[0].remoteID, "remote-song");
  assert.deepEqual(state.playlists[1].trackIDs, ["local"]);
  assert.deepEqual(state.playlists[1].remoteSongIDs, ["remote-song"]);
  assert.deepEqual(state.dirtyPlaylistIDs, ["12345678-1234-abcd-9876-abcdef123456"]);
  assert.deepEqual(state.favorites, ["local"]);
  assert.equal(state.currentTrackID, "local");
  assert.deepEqual(state.playbackQueueIDs, ["local"]);
  assert.equal(state.listeningHistory[0].trackID, "local");
  assert.deepEqual(state.dirtyRemoteLikeSongIDs, ["remote-song"]);
});

test("reconciling a stale downloaded identity removes its old playlist, like, and clip references", () => {
  const state = createEmptyState();
  state.tracks = [{
    id: "downloaded",
    title: "Downloaded",
    remoteID: "old-song",
    sourceServer: "https://music.example",
    syncProfileID: "default",
  }];
  state.playlists.push({
    id: "12345678-1234-abcd-9876-abcdef123456",
    name: "Mix",
    trackIDs: ["downloaded"],
    remoteSongIDs: ["old-song"],
    isSystem: false,
  });
  state.favorites = ["downloaded"];
  state.remoteLikedSongIDs = ["old-song"];
  state.clipRanges = { "remote:old-song": { startSeconds: 2, endSeconds: 8 } };

  reconcileUploadedTrack(state, "downloaded", { id: "new-song" }, {
    serverURL: "https://music.example",
    profileID: "default",
  });

  assert.deepEqual(state.playlists[1].remoteSongIDs, ["new-song"]);
  assert.deepEqual(state.remoteLikedSongIDs, ["new-song"]);
  assert.deepEqual(state.dirtyRemoteLikeSongIDs, ["old-song", "new-song"]);
  assert.deepEqual(state.clipRanges, { "remote:new-song": { startSeconds: 2, endSeconds: 8 } });
  assert.deepEqual(state.dirtyClipRangeKeys, ["remote:old-song", "remote:new-song"]);
  assert.deepEqual(state.deletedClipRangeKeys, ["remote:old-song"]);
});

test("plans every eligible link download while preserving server and profile boundaries", () => {
  const exactHash = "a".repeat(64);
  const sourceURL = "https://media.example/song.m4a";
  const state = normalizeState({
    ...createEmptyState(),
    serverURL: "https://music.example",
    syncProfileID: "profile-a",
    tracks: [
      { id: "present", filePath: "/music/present.mp3", remoteID: "remote-present", sourceServer: "https://music.example", syncProfileID: "profile-a" },
      { id: "missing", filePath: "/music/missing.mp3", remoteID: "remote-gone", sourceServer: "https://music.example", syncProfileID: "profile-a", sourceURL },
      { id: "hash-match", filePath: "/music/hash.mp3", remoteID: "old-id", sourceServer: "https://music.example", syncProfileID: "profile-a", contentSha256: exactHash },
      { id: "local", filePath: "/music/local.mp3", remoteID: null },
      { id: "local-link", filePath: "/music/local-link.mp3", remoteID: null, sourceIdentity: { sourcePageURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw" } },
      { id: "local-download-link", filePath: "/music/local-download.mp3", remoteID: null, downloadSourceURL: "https://media.example/downloaded.m4a" },
      { id: "local-invalid-link", filePath: "/music/local-invalid.mp3", remoteID: null, sourceURL: "http://media.example/song.m4a" },
      { id: "other-profile", filePath: "/music/other.mp3", remoteID: "gone", sourceServer: "https://music.example", syncProfileID: "profile-b" },
      { id: "metadata-match", title: "All for You - Radio Version", artist: "Ace of Base", duration: 217.1, filePath: "/music/metadata.mp3", remoteID: "old-metadata-id", sourceServer: "https://music.example", syncProfileID: "profile-a", sourceURL },
      { id: "source-only-current", title: "Actually Missing", artist: "Artist", duration: 180, filePath: "/music/source.mp3", sourceServer: "https://music.example", syncProfileID: "profile-a", sourceURL },
      { id: "missing-preserved-source", title: "Unavailable Source", filePath: "/music/unavailable.mp3", remoteID: "old-unavailable", sourceServer: "https://music.example", syncProfileID: "profile-a" },
      { id: "source-only-other-profile", filePath: "/music/profile.mp3", sourceServer: "https://music.example", syncProfileID: "profile-b" },
      { id: "source-only-other-server", filePath: "/music/server.mp3", sourceServer: "https://other.example", syncProfileID: "profile-a" },
      { id: "cross-server-id-collision", filePath: "/music/collision.mp3", remoteID: "remote-present", sourceServer: "https://other.example", syncProfileID: "profile-b" },
      { id: "cross-server-hash-match", filePath: "/music/cross-hash.mp3", remoteID: "other-id", sourceServer: "https://other.example", syncProfileID: "profile-b", contentSha256: exactHash },
    ],
  });
  const plan = planMissingDownloadedUploads(state, [
    { id: "remote-present" },
    { id: "replacement", content_sha256: exactHash },
    { id: "metadata-replacement", title: "All for You Radio Version", artist: "Ace of Base", duration_seconds: 217.9 },
  ]);
  assert.deepEqual(plan.uploadTracks.map((track) => track.id), [
    "missing",
    "local-link",
    "local-download-link",
    "source-only-current",
  ]);
  assert.deepEqual(plan.alreadyPresent.map((track) => track.id), ["present"]);
  assert.deepEqual(plan.matches.map((match) => [match.trackID, match.remoteSong.id]), [
    ["hash-match", "replacement"],
  ]);
  assert.deepEqual(plan.ambiguous.map((match) => [match.track.id, match.candidates[0].id]), [
    ["metadata-match", "metadata-replacement"],
  ]);
  assert.deepEqual(plan.missingSource.map((track) => track.id), ["missing-preserved-source"]);
  assert.equal(preservedUploadSourceURL(state.tracks.find((track) => track.id === "local-link")), "https://www.youtube.com/watch?v=jNQXAC9IVRw");
  assert.equal(preservedUploadSourceURL(state.tracks.find((track) => track.id === "local-download-link")), "https://media.example/downloaded.m4a");
  assert.equal(preservedUploadSourceURL(state.tracks.find((track) => track.id === "local-invalid-link")), null);
});

test("continues planning after the first downloaded song is already on the server", () => {
  const state = normalizeState({
    ...createEmptyState(),
    serverURL: "https://music.example",
    syncProfileID: "profile-a",
    tracks: [
      {
        id: "already-present-first",
        filePath: "/music/present.mp3",
        remoteID: "remote-present",
        sourceServer: "https://music.example",
        syncProfileID: "profile-a",
        sourceURL: "https://media.example/present.m4a",
      },
      {
        id: "missing-second",
        filePath: "/music/missing.mp3",
        remoteID: "remote-deleted",
        sourceServer: "https://music.example",
        syncProfileID: "profile-a",
        sourceURL: "https://media.example/missing.m4a",
      },
      {
        id: "local-link-third",
        filePath: "/music/local.mp3",
        sourceIdentity: { sourcePageURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw" },
      },
    ],
  });

  const plan = planMissingDownloadedUploads(state, [{ id: "remote-present" }]);

  assert.deepEqual(plan.alreadyPresent.map((track) => track.id), ["already-present-first"]);
  assert.deepEqual(plan.uploadTracks.map((track) => track.id), ["missing-second", "local-link-third"]);
});

test("does not hold uploads behind catalog, playlist, likes, profile, or history synchronization", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const sourceBetween = (start, end) => appSource.slice(appSource.indexOf(start), appSource.indexOf(end));
  const localUploadSource = sourceBetween("async function uploadLocalImportTrack", "async function refreshServerCatalogAfterUpload");
  const catalogRefreshSource = sourceBetween("async function refreshServerCatalogAfterUpload", "function scheduleServerCatalogRefresh");
  const rememberUploadsSource = sourceBetween("function rememberUploadedServerSongs", "function serverCatalogMatchForLocalImport");
  const localCatalogMatchSource = sourceBetween("function serverCatalogMatchForLocalImport", "async function prepareLocalImportUploadBatch");
  const localBatchPlanSource = sourceBetween("async function prepareLocalImportUploadBatch", "async function uploadLocalImportTracks");
  const serverActionSource = sourceBetween("async function serverAction", "async function uploadServerSongs");
  const manualUploadSource = sourceBetween("async function uploadServerSongs", "async function uploadMissingDownloadedSongs");
  const missingUploadSource = sourceBetween("async function uploadMissingDownloadedSongs", "async function requestPlayback");

  assert.doesNotMatch(localUploadSource, /fetchCatalog|refreshServerCatalogAfterUpload/);
  assert.doesNotMatch(localBatchPlanSource, /fetchCatalog|refreshServerCatalogAfterUpload/);
  assert.match(localCatalogMatchSource, /serverTrackRemoteIDBelongsToContext\(track/);
  assert.doesNotMatch(serverActionSource, /await syncPlaylistsNow/);
  assert.match(serverActionSource, /schedulePlaylistSync\(\)/);
  assert.match(serverActionSource, /const catalogRequestGeneration = serverCatalogGeneration/);
  assert.match(serverActionSource, /catalogRequestCanApply\(\{[\s\S]+requestGeneration: catalogRequestGeneration[\s\S]+contextCurrent: profileContextIsCurrent\(context\)/);
  assert.match(catalogRefreshSource, /const requestGeneration = serverCatalogGeneration[\s\S]+catalogRequestCanApply\(\{[\s\S]+currentGeneration: serverCatalogGeneration/);
  assert.match(rememberUploadsSource, /replaceServerCatalog\(merged\)/);
  assert.doesNotMatch(manualUploadSource, /await serverAction\("catalog"\)|await api\.fetchCatalog/);
  assert.match(manualUploadSource, /scheduleServerCatalogRefresh\(context\)/);
  assert.match(manualUploadSource, /rememberUploadedServerSongs\(result\.results\)/);
  assert.doesNotMatch(missingUploadSource, /await api\.fetchCatalog/);
  assert.match(missingUploadSource, /planMissingDownloadedUploads\(state, serverCatalog\)/);
  assert.match(missingUploadSource, /scheduleServerCatalogRefresh\(context\)/);
  assert.match(missingUploadSource, /rememberUploadedServerSongs\(result\.results\)/);
  assert.match(manualUploadSource, /serverUploadConfigurationError\(\{ serverURL: state\.serverURL, adminToken: serverAdminToken \}\)/);
  assert.match(missingUploadSource, /serverUploadConfigurationError\(\{ serverURL: state\.serverURL, adminToken: serverAdminToken \}\)/);
  assert.equal(manualUploadSource.match(/serverUploadBlockedByActivity/g)?.length, 2);
  assert.equal(missingUploadSource.match(/serverUploadBlockedByActivity/g)?.length, 2);
  assert.match(manualUploadSource, /await saveServerForm\(\);\s+if \(serverUploadBlockedByActivity/);
  assert.match(missingUploadSource, /await saveServerForm\(\);\s+if \(serverUploadBlockedByActivity/);
});

test("reserves immutable upload contexts while account sessions replace credential fields", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const htmlSource = readFileSync(new URL("../ui/index.html", import.meta.url), "utf8");
  const sourceBetween = (start, end) => appSource.slice(appSource.indexOf(start), appSource.indexOf(end));
  const contextSource = sourceBetween("function currentServerUploadContext", "function serverArtworkKey");
  const saveFormSource = sourceBetween("async function saveServerForm", "function renderSettings");
  const localUploadSource = sourceBetween("async function uploadLocalImportTrack", "async function refreshServerCatalogAfterUpload");
  const localBatchSource = sourceBetween("async function prepareLocalImportUploadBatch", "function resetLocalImportArtwork");
  const playlistImportSource = sourceBetween("async function confirmPlaylistImport", "async function confirmLinkImport");
  const linkImportSource = sourceBetween("async function confirmLinkImport", "async function cancelLinkImport");
  const settingsSubmitSource = sourceBetween('$("#serverSettingsForm").onsubmit', "async function finishProfileSelection");

  assert.match(contextSource, /Object\.freeze\(\{[\s\S]+adminToken: serverAdminToken/);
  assert.match(contextSource, /serverUploadContextIsCurrent[\s\S]+context\?\.adminToken === serverAdminToken/);
  assert.match(contextSource, /ensureServerContextCanChange[\s\S]+serverTransferActive \|\| serverDownloadOperationActive \|\| serverContextReservation/);
  assert.match(saveFormSource, /const settingsOpen = Boolean\(\$\("#settingsDialog"\)\?\.open && settingsPanel === "server" && \$\("#serverSettingsForm"\)\)/);
  assert.doesNotMatch(saveFormSource, /#serverToken|#serverAdminToken|saveServerCredentials/);
  assert.match(saveFormSource, /serverToken = String\(accountSession\?\.accessToken \|\| ""\)\.trim\(\)/);
  assert.match(saveFormSource, /serverAdminToken = accountSession \? serverToken : ""/);
  assert.doesNotMatch(appSource, /id="serverToken"|id="serverAdminToken"/);
  assert.match(appSource, /data-auth-provider="clerk"/);
  assert.match(appSource, /email, Google, Apple, and Discord/);
  assert.match(localUploadSource, /uploadLocalImportTrack\(track, context\)[\s\S]+requireLocalImportServerContext\(context\)/);
  assert.match(localUploadSource, /baseURL: context\.serverURL[\s\S]+adminToken: context\.adminToken[\s\S]+profileID: context\.profileID/);
  assert.match(localBatchSource, /prepareLocalImportUploadBatch\(tracks, context\)[\s\S]+uploadLocalImportTracks\(tracks, context\)/);
  assert.match(playlistImportSource, /reserveServerContext\(importContext\)[\s\S]+prepareLocalImportUploadBatch\(uploadQueue, importContext\)[\s\S]+releaseServerContext\(importContext\)/);
  assert.match(linkImportSource, /reserveServerContext\(importContext\)[\s\S]+uploadImportedTrackWithMode\([\s\S]+releaseServerContext\(importContext\)/);
  assert.match(playlistImportSource, /localImportNeedsServerContext\(\{ uploadRequested \}\)[\s\S]+if \(needsServerContext\) \{[\s\S]+currentServerUploadContext\(\)/);
  assert.match(linkImportSource, /localImportNeedsServerContext\(\{ serverBacked, uploadRequested \}\)[\s\S]+if \(needsServerContext\) \{[\s\S]+currentServerUploadContext\(\)/);
  assert.doesNotMatch(playlistImportSource, /const importContext = currentServerUploadContext\(\)/);
  assert.doesNotMatch(linkImportSource, /const importContext = currentServerUploadContext\(\)/);
  assert.match(settingsSubmitSource, /if \(!serverToken\.trim\(\)\)[\s\S]+Server saved • sign in to connect/);
  assert.doesNotMatch(settingsSubmitSource.match(/if \(!serverToken\.trim\(\)\) \{([\s\S]*?)\n\s+\} else/)?.[1] || "", /serverAction\("catalog"\)/);
});

test("matches re-encoded server copies by title artist and duration", () => {
  assert.equal(serverSongMetadataMatches(
    { title: "Cake By The Ocean", artist: "DNCE", duration: 219.2 },
    { title: "Cake By The Ocean", artist: "DNCE", duration_seconds: 218.9 },
  ), true);
  assert.equal(serverSongMetadataMatches(
    { title: "Cake By The Ocean", artist: "DNCE", duration: 219.2 },
    { title: "Cake By The Ocean", artist: "DNCE", duration_seconds: 260 },
  ), false);
});

test("names every permanent upload failure after retries", () => {
  assert.equal(formatServerUploadFailureNotice([
    { title: "First", artist: "Artist" },
    { filename: "Second.mp3" },
  ]), "2 songs failed to upload after retrying: “First” — Artist; “Second.mp3”.");
});

test("matching cached server hashes reconcile old uploads during state normalization", () => {
  const state = createEmptyState();
  state.tracks = [
    { id: "local", remoteID: null, size: 128, contentSha256: "content-hash" },
    {
      id: "server-copy",
      remoteID: "remote-song",
      sourceServer: state.serverURL,
      syncProfileID: "default",
      size: 128,
      contentSha256: "content-hash",
    },
  ];
  state.playlists.push({ id: "mix", name: "Mix", trackIDs: ["local"], remoteSongIDs: [], isSystem: false });

  assert.equal(reconcileServerBackedTrackDuplicates(state), 1);
  assert.deepEqual(state.tracks.map((track) => track.id), ["local"]);
  assert.equal(state.tracks[0].remoteID, "remote-song");
  assert.deepEqual(state.playlists[1].remoteSongIDs, ["remote-song"]);
});

test("merges dirty local playlists over the server without deleting unrelated playlists", () => {
  const state = createEmptyState();
  state.tracks = [
    { id: "local-a", remoteID: "a".repeat(24), sourceServer: state.serverURL, syncProfileID: "default" },
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

test("reorders playlist tracks before or after a drop target", () => {
  const original = ["one", "two", "three", "four"];
  assert.deepEqual(reorderPlaylistTrackIDs(original, "four", "one"), ["four", "one", "two", "three"]);
  assert.deepEqual(reorderPlaylistTrackIDs(original, "one", "three", true), ["two", "three", "one", "four"]);
  assert.deepEqual(reorderPlaylistTrackIDs(original, "two", "missing"), original);
  assert.deepEqual(original, ["one", "two", "three", "four"]);
  assert.equal(playlistInsertionIndex([110, 170, 230], 40), 0);
  assert.equal(playlistInsertionIndex([110, 170, 230], 109), 0);
  assert.equal(playlistInsertionIndex([110, 170, 230], 110), 1);
  assert.equal(playlistInsertionIndex([110, 170, 230], 229), 2);
  assert.equal(playlistInsertionIndex([110, 170, 230], 230), 3);
  assert.equal(playlistInsertionIndex([110, 170, 230], 400), 3);
  assert.equal(playlistInsertionIndex([], 100), -1);

  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  const styleSource = readFileSync(new URL("../ui/styles.css", import.meta.url), "utf8");
  assert.doesNotMatch(appSource, /row\.onmousedown\s*=/);
  assert.match(appSource, /row\.onpointerdown = \(event\) => \{\s+if \(!event\.isPrimary[\s\S]+row\.setPointerCapture\(event\.pointerId\)/);
  assert.match(appSource, /function playlistDragDestination[\s\S]+playlistInsertionIndex\([\s\S]+row\.offsetTop/);
  assert.match(appSource, /row\.onpointermove = \(event\) => \{[\s\S]+playlistDragDestination\(trackTable, event\.clientY\)/);
  assert.match(appSource, /row\.onpointerup = \(event\) => \{[\s\S]+playlistDragDestination\(trackTable, event\.clientY\)/);
  assert.match(styleSource, /\.track-row\.playlist-draggable\s*\{[\s\S]+touch-action: none/);
  assert.match(appSource, /function commitPlaylistTrackReorder[\s\S]+renderLibrary\(\);[\s\S]+await persist\(\)/);
  assert.doesNotMatch(appSource, /draggable="true" data-playlist-draggable/);
});

test("merges server playlist order without moving Windows-only items out of their slots", () => {
  assert.deepEqual(
    mergePlaylistOrderWithPreservedItems(
      ["remote-a", "local-one", "remote-b", "local-two"],
      ["remote-b", "remote-c", "remote-a"],
      ["local-one", "local-two"],
    ),
    ["remote-b", "local-one", "remote-c", "local-two", "remote-a"],
  );
  assert.deepEqual(
    mergePlaylistOrderWithPreservedItems(["local-only"], ["downloaded-a"], ["local-only"]),
    ["local-only", "downloaded-a"],
  );
});

test("playlist presentation includes undownloaded server songs in order", () => {
  const state = createEmptyState();
  state.tracks = [
    { id: "downloaded-a", title: "Downloaded A", remoteID: "remote-a", sourceServer: state.serverURL, syncProfileID: "default" },
    { id: "local", title: "Local", remoteID: null },
    { id: "downloaded-b", title: "Downloaded B", remoteID: "remote-b", sourceServer: state.serverURL, syncProfileID: "default" },
  ];
  state.playlists.push({
    id: "shared",
    name: "Shared",
    trackIDs: ["downloaded-a", "local", "downloaded-b"],
    remoteSongIDs: ["remote-b", "remote-missing", "remote-a"],
    isSystem: false,
  });

  const entries = tracksForPlaylist(state, "shared", [{
    id: "remote-missing",
    title: "Server-only song",
    artist: "Remote artist",
    album: "Remote album",
    duration: 125,
    filename: "remote.m4a",
  }]);

  assert.deepEqual(entries.map((entry) => entry.id), [
    "downloaded-b",
    "local",
    "playlist-remote:remote-missing",
    "downloaded-a",
  ]);
  assert.equal(entries[2].title, "Server-only song");
  assert.equal(entries[2].available, false);
  assert.equal(entries[2].playlistUnavailable, true);
});

test("removing a download keeps its server playlist slot until the server song is gone", () => {
  const state = createEmptyState();
  const kept = {
    id: "downloaded-a",
    title: "Downloaded A",
    remoteID: "remote-a",
    sourceServer: state.serverURL,
    syncProfileID: "default",
  };
  const local = { id: "local", title: "Local" };
  state.tracks = [kept, local];
  const playlist = {
    id: "shared",
    name: "Shared",
    trackIDs: [local.id, kept.id],
    remoteSongIDs: [kept.remoteID],
    entryOrder: ["local:local", "remote:remote-a"],
    isSystem: false,
  };
  state.playlists.push(playlist);

  const preserved = removeLibraryTracksFromPlaylists(state, new Set([kept.id]), [{
    id: kept.remoteID,
    title: "Downloaded A",
  }], { catalogIsAuthoritative: true });
  assert.deepEqual(playlist.trackIDs, [local.id]);
  assert.deepEqual(playlist.remoteSongIDs, [kept.remoteID]);
  assert.deepEqual(playlist.entryOrder, ["local:local", "remote:remote-a"]);
  assert.deepEqual(preserved.remoteMembershipChangedPlaylistIDs, []);
  state.tracks = [local];
  assert.deepEqual(tracksForPlaylist(state, playlist.id, [{ id: kept.remoteID, title: "Downloaded A" }])
    .map((track) => track.id), [local.id, `playlist-remote:${kept.remoteID}`]);

  const missing = {
    id: "downloaded-b",
    title: "Downloaded B",
    remoteID: "remote-b",
    sourceServer: state.serverURL,
    syncProfileID: "default",
  };
  state.tracks.push(missing);
  playlist.trackIDs.push(missing.id);
  playlist.remoteSongIDs.push(missing.remoteID);
  playlist.entryOrder.push("remote:remote-b");
  const unavailableCatalog = removeLibraryTracksFromPlaylists(state, [missing.id], []);
  assert.deepEqual(playlist.remoteSongIDs, [kept.remoteID, missing.remoteID]);
  assert.deepEqual(playlist.entryOrder, ["local:local", "remote:remote-a", "remote:remote-b"]);
  assert.deepEqual(unavailableCatalog.remoteMembershipChangedPlaylistIDs, []);

  playlist.trackIDs.push(missing.id);
  const removed = removeLibraryTracksFromPlaylists(
    state,
    [missing.id],
    [{ id: kept.remoteID }],
    { catalogIsAuthoritative: true },
  );
  assert.deepEqual(playlist.remoteSongIDs, [kept.remoteID]);
  assert.deepEqual(playlist.entryOrder, ["local:local", "remote:remote-a"]);
  assert.deepEqual(removed.remoteMembershipChangedPlaylistIDs, [playlist.id]);
});

test("library removal mutates only the deleted raw entry-order token", () => {
  const state = createEmptyState();
  const removed = { id: "X", title: "Local X" };
  state.tracks = [removed];
  const playlist = {
    id: "raw-order",
    name: "Raw order",
    trackIDs: [removed.id],
    remoteSongIDs: ["A", "B"],
    entryOrder: ["remote:B", "local:X", "remote:A"],
    isSystem: false,
  };
  state.playlists.push(playlist);

  const result = removeLibraryTracksFromPlaylists(
    state,
    [removed.id],
    [{ id: "A" }, { id: "B" }],
    { catalogIsAuthoritative: true },
  );

  assert.deepEqual(playlist.remoteSongIDs, ["A", "B"]);
  assert.deepEqual(playlist.entryOrder, ["remote:B", "remote:A"]);
  assert.deepEqual(result.remoteMembershipChangedPlaylistIDs, []);
});

test("library removal appends a newly converted remote membership without reordering existing IDs", () => {
  const state = createEmptyState();
  const downloaded = {
    id: "downloaded-c",
    title: "Downloaded C",
    remoteID: "C",
    sourceServer: state.serverURL,
    syncProfileID: "default",
  };
  state.tracks = [downloaded];
  const playlist = {
    id: "converted-order",
    name: "Converted order",
    trackIDs: [downloaded.id],
    remoteSongIDs: ["A", "B"],
    entryOrder: ["remote:B", "local:downloaded-c", "remote:A"],
    isSystem: false,
  };
  state.playlists.push(playlist);

  const result = removeLibraryTracksFromPlaylists(
    state,
    [downloaded.id],
    [{ id: "A" }, { id: "B" }, { id: "C" }],
    { catalogIsAuthoritative: true },
  );

  assert.deepEqual(playlist.remoteSongIDs, ["A", "B", "C"]);
  assert.deepEqual(playlist.entryOrder, ["remote:B", "remote:C", "remote:A"]);
  assert.deepEqual(result.remoteMembershipChangedPlaylistIDs, [playlist.id]);
});

test("library removal does not synthesize legacy remote membership from an unproven catalog", () => {
  const state = createEmptyState();
  const downloaded = {
    id: "downloaded-c",
    title: "Downloaded C",
    remoteID: "C",
    sourceServer: state.serverURL,
    syncProfileID: "default",
  };
  state.tracks = [downloaded];
  const playlist = {
    id: "unproven-conversion",
    name: "Unproven conversion",
    trackIDs: [downloaded.id],
    remoteSongIDs: ["A", "B"],
    entryOrder: ["remote:B", "local:downloaded-c", "remote:A"],
    isSystem: false,
  };
  state.playlists.push(playlist);

  const result = removeLibraryTracksFromPlaylists(state, [downloaded.id], []);

  assert.deepEqual(playlist.remoteSongIDs, ["A", "B"]);
  assert.deepEqual(playlist.entryOrder, ["remote:B", "remote:A"]);
  assert.deepEqual(result.remoteMembershipChangedPlaylistIDs, []);
});

test("mixed playlist reorders and persists undownloaded server entries", () => {
  const state = createEmptyState();
  state.tracks = [
    { id: "downloaded-a", title: "Downloaded A", remoteID: "remote-a", sourceServer: state.serverURL, syncProfileID: "default" },
    { id: "local", title: "Local", remoteID: null },
    { id: "downloaded-b", title: "Downloaded B", remoteID: "remote-b", sourceServer: state.serverURL, syncProfileID: "default" },
  ];
  const playlist = {
    id: "shared",
    name: "Shared",
    trackIDs: ["downloaded-a", "local", "downloaded-b"],
    remoteSongIDs: ["remote-b", "remote-missing", "remote-a"],
    isSystem: false,
  };
  state.playlists.push(playlist);

  assert.equal(reorderPlaylistEntries(
    state,
    playlist,
    "remote:remote-missing",
    "remote:remote-b",
  ), true);
  assert.deepEqual(playlist.trackIDs, ["downloaded-b", "local", "downloaded-a"]);
  assert.deepEqual(playlist.remoteSongIDs, ["remote-missing", "remote-b", "remote-a"]);
  assert.deepEqual(playlist.entryOrder, [
    "remote:remote-missing",
    "remote:remote-b",
    "local:local",
    "remote:remote-a",
  ]);
  assert.deepEqual(tracksForPlaylist(state, "shared").map((entry) => entry.id), [
    "playlist-remote:remote-missing",
    "downloaded-b",
    "local",
    "downloaded-a",
  ]);
  const mergedDocument = mergePlaylistDocument(state, {
    revision: 0,
    playlists: [],
    liked_song_ids: [],
    clip_ranges: [],
  }).document;
  assert.deepEqual(mergedDocument.playlists, [{
    id: "shared",
    name: "Shared",
    song_ids: ["remote-missing", "remote-b", "remote-a"],
  }]);

  const reloaded = normalizeState(structuredClone(state));
  assert.deepEqual(reloaded.playlists.find((item) => item.id === "shared").entryOrder, playlist.entryOrder);
  assert.deepEqual(tracksForPlaylist(reloaded, "shared").map((entry) => entry.id), [
    "playlist-remote:remote-missing",
    "downloaded-b",
    "local",
    "downloaded-a",
  ]);
});

test("animates playback progress independently of media timeupdate events", () => {
  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  assert.match(appSource, /function animatePlaybackProgress\(\)[\s\S]+updatePlaybackProgressUI\(\)[\s\S]+requestAnimationFrame\(animatePlaybackProgress\)/);
  assert.match(appSource, /media\.onplay = \(\) => \{[\s\S]+startPlaybackProgressAnimation\(\)/);
  assert.match(appSource, /media\.onpause = \(\) => \{[\s\S]+stopPlaybackProgressAnimation\(\)/);
  assert.match(appSource, /bindPrimaryAudioEvents\(audio\)/);
  assert.match(appSource, /function setRepeatEnabled\(value\)[\s\S]+syncRepeatControls\(\)/);
  assert.doesNotMatch(appSource, /#fullPlayerRepeat"\)\.onclick = \(\) => \{[\s\S]{0,160}updateChrome\(\)/);
});

test("merges and applies profile clip ranges without overwriting newer local edits", () => {
  const track = { id: "downloaded", remoteID: "song-a", duration: 180 };
  const state = normalizeState({ ...createEmptyState(), tracks: [track] });
  setClipRangeForTrack(state, track, 15, 45);

  const merge = mergePlaylistDocument(state, {
    revision: 4,
    playlists: [],
    liked_song_ids: [],
    clip_ranges: [
      { song_id: "song-a", start_seconds: 1, end_seconds: 2 },
      { song_id: "song-b", start_seconds: 20, end_seconds: 40 },
    ],
  });
  assert.equal(merge.needsUpload, true);
  assert.deepEqual(merge.document.clip_ranges, [
    { song_id: "song-a", start_seconds: 15, end_seconds: 45 },
    { song_id: "song-b", start_seconds: 20, end_seconds: 40 },
  ]);

  applyRemotePlaylistDocument(state, {
    revision: 5,
    playlists: [],
    liked_song_ids: [],
    clip_ranges: [
      { song_id: "song-a", start_seconds: 3, end_seconds: 9 },
      { song_id: "song-b", start_seconds: 22, end_seconds: 44 },
    ],
  }, { preservingLocalClipKeys: state.dirtyClipRangeKeys });
  assert.deepEqual(playbackRangeForTrack(state, track), { startSeconds: 15, endSeconds: 45 });
  assert.deepEqual(state.clipRanges["remote:song-b"], { startSeconds: 22, endSeconds: 44 });

  removeClipRangeForTrack(state, track);
  const deletion = mergePlaylistDocument(state, {
    revision: 5,
    playlists: [],
    liked_song_ids: [],
    clip_ranges: [{ song_id: "song-a", start_seconds: 3, end_seconds: 9 }],
  });
  assert.deepEqual(deletion.document.clip_ranges, []);
});

test("applies remote ordering, preserves local-only songs, and hydrates later downloads", () => {
  const playlistID = "12345678-1234-abcd-9876-abcdef123456";
  const firstRemoteID = "a".repeat(24);
  const secondRemoteID = "b".repeat(24);
  const state = createEmptyState();
  state.tracks = [
    { id: "downloaded-a", remoteID: firstRemoteID, sourceServer: state.serverURL, syncProfileID: "default" },
    { id: "local-only", remoteID: null },
  ];
  state.playlists.push({ id: playlistID, name: "Old", trackIDs: ["local-only"], remoteSongIDs: [], isSystem: false });

  applyRemotePlaylistDocument(state, {
    revision: 7,
    playlists: [{ id: playlistID.toUpperCase(), name: "Shared", song_ids: [secondRemoteID, firstRemoteID] }],
  });
  assert.equal(state.playlistRevision, 7);
  assert.deepEqual(state.playlists[1].trackIDs, ["local-only", "downloaded-a"]);
  assert.deepEqual(state.playlists[1].remoteSongIDs, [secondRemoteID, firstRemoteID]);

  mergeSyncedTracks(state, { downloaded: [{ id: "downloaded-b", remoteID: secondRemoteID, sourceServer: state.serverURL, syncProfileID: "default" }], replacedTrackIDs: [] });
  assert.deepEqual(state.playlists[1].trackIDs, ["local-only", "downloaded-b", "downloaded-a"]);
});

test("remote playlist reordering preserves local-only and unresolved-song slots", () => {
  const playlistID = "12345678-1234-abcd-9876-abcdef123456";
  const firstRemoteID = "a".repeat(24);
  const unresolvedRemoteID = "b".repeat(24);
  const secondRemoteID = "c".repeat(24);
  const state = createEmptyState();
  state.tracks = [
    { id: "downloaded-a", remoteID: firstRemoteID, sourceServer: state.serverURL, syncProfileID: "default" },
    { id: "local-only", remoteID: null },
    { id: "downloaded-c", remoteID: secondRemoteID, sourceServer: state.serverURL, syncProfileID: "default" },
  ];
  state.playlists.push({
    id: playlistID,
    name: "Mixed order",
    trackIDs: ["downloaded-a", "local-only", "downloaded-c"],
    remoteSongIDs: [firstRemoteID, unresolvedRemoteID, secondRemoteID],
    isSystem: false,
  });

  applyRemotePlaylistDocument(state, {
    revision: 8,
    playlists: [{ id: playlistID, name: "Mixed order", song_ids: [secondRemoteID, unresolvedRemoteID, firstRemoteID] }],
  });
  assert.deepEqual(state.playlists[1].trackIDs, ["downloaded-c", "local-only", "downloaded-a"]);

  state.playlists[1].trackIDs = ["downloaded-a", "local-only", "downloaded-c"];
  updatePlaylistRemoteSongIDs(state, state.playlists[1]);
  assert.deepEqual(state.playlists[1].remoteSongIDs, [firstRemoteID, unresolvedRemoteID, secondRemoteID]);
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

test("stale playlist responses preserve newer edits and in-flight deletions", () => {
  const editedID = "12345678-1234-abcd-9876-abcdef123456";
  const deletedID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
  const state = createEmptyState();
  state.playlists.push(
    { id: editedID, name: "New local name", trackIDs: [], remoteSongIDs: ["new-song"], isSystem: false },
    { id: deletedID, name: "Delete me", trackIDs: [], remoteSongIDs: [], isSystem: false },
  );
  state.dirtyPlaylistIDs = [editedID];
  state.deletedPlaylistIDs = [deletedID];

  applyRemotePlaylistDocument(state, {
    revision: 8,
    playlists: [
      { id: editedID, name: "Stale submitted name", song_ids: ["old-song"] },
      { id: deletedID, name: "Delete me", song_ids: [] },
    ],
  }, { preservingLocalIDs: state.dirtyPlaylistIDs });

  assert.equal(state.playlists.find((playlist) => playlist.id === editedID)?.name, "New local name");
  assert.deepEqual(state.playlists.find((playlist) => playlist.id === editedID)?.remoteSongIDs, ["new-song"]);
  assert.equal(state.playlists.some((playlist) => playlist.id === deletedID), false);
  assert.deepEqual(state.dirtyPlaylistIDs, [editedID]);
  assert.deepEqual(state.deletedPlaylistIDs, [deletedID]);

  const appSource = readFileSync(new URL("../ui/app.js", import.meta.url), "utf8");
  assert.match(appSource, /submittedPlaylistGeneration = playlistMutationGeneration/);
  assert.match(appSource, /preservingLocalIDs:[\s\S]+state\.dirtyPlaylistIDs/);
});

test("removing a downloaded song updates remote membership while keeping unresolved songs", () => {
  const state = createEmptyState();
  state.tracks = [{ id: "downloaded", remoteID: "a".repeat(24), sourceServer: state.serverURL, syncProfileID: "default" }];
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
    serverURL: "https://resonance-core.blithe-haven-9710.chatgpt.site",
    tracks: [
      { id: "local", remoteID: null },
      { id: "remote-a", remoteID: "song-a", sourceServer: "https://resonance-core.blithe-haven-9710.chatgpt.site", syncProfileID: "default" },
      { id: "remote-b", remoteID: "song-b", sourceServer: "https://resonance-core.blithe-haven-9710.chatgpt.site", syncProfileID: "default" },
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
    downloaded: [{ id: "downloaded", remoteID: "not-downloaded-yet", sourceServer: state.serverURL, syncProfileID: "default" }],
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
