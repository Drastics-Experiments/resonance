import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

import core from "../local-import-core.cjs";
import debrid from "../local-debrid.cjs";
import platform from "../local-import-platform.cjs";
import youtube from "../local-youtube.cjs";
import metadata from "../metadata.cjs";

const {
  LocalImportError,
  isSpotifyURL,
  parseSpotifyEmbedEntity,
  parseSpotifyOEmbed,
  parseSpotifyPlaylistEmbed,
  parseSpotifyPlaylistOEmbed,
  parseYouTubeMusicSearch,
  parseYouTubePlaylistData,
  parseYouTubeWebSearch,
  resolveSpotifyPlaylist,
  resolveYouTubePlaylist,
  scoreAudioSource,
  youtubePlaylistID,
  youtubeVideoID,
  spotifyPlaylistURL,
} = core;
const {
  PREPARED_SOUNDCLOUD_AUDIO_TTL_MS,
  createPreparedSoundCloudAudioHandoff,
  duplicateTrack,
  importConfirmedSource,
  resolveLocalImportDownloadSource,
  resolveLocalImportMetadata,
  resolveLocalImportSource,
  safeArtworkURL,
} = platform;
const {
  chooseMP4VideoFormat,
  chooseMP4VideoOnlyFormat,
  downloadResolvedAudio,
  downloadResolvedVideo,
  resolveYouTubeMetadata,
  verifiedContentRange,
} = youtube;
const { importFileBackedSource, searchFileBackedSources } = debrid;

const spotifyTrackID = "4PTG3Z6ehGkBFwjybzWkR8";
const spotifyPlaylistID = "37i9dQZF1DXcBWIGoYBM5M";
const windowsClientContextHeaders = Object.freeze({
  "X-Resonance-Config-Protocol": "1",
  "X-Resonance-Client-Platform": "windows",
  "X-Resonance-App-Version": "1.1.4",
  "X-Resonance-App-Build": "17",
  "X-Resonance-Cohort-Key": "ABEiM0RVZneImaq7zN3u_w",
});

function spotifyEmbedFixture(overrides = {}) {
  const entity = {
    type: "track",
    id: spotifyTrackID,
    title: "Never Gonna Give You Up",
    artists: [{ name: "Rick Astley" }],
    duration: 213573,
    visualIdentity: {
      image: [{ url: "https://image-cdn-fa.spotifycdn.com/image/cover", maxWidth: 640 }],
    },
    ...overrides,
  };
  return `<html><script id="__NEXT_DATA__" type="application/json">${JSON.stringify({
    props: { pageProps: { state: { data: { entity } } } },
  })}</script></html>`;
}

test("accepts supported Spotify tracks and YouTube video or playlist URL shapes", () => {
  assert.equal(isSpotifyURL(`https://open.spotify.com/track/${spotifyTrackID}`), true);
  assert.equal(spotifyPlaylistURL(`https://open.spotify.com/intl-en/playlist/${spotifyPlaylistID}?si=test`).playlistID, spotifyPlaylistID);
  assert.equal(isSpotifyURL("https://open.spotify.example/track/example"), false);
  assert.equal(youtubeVideoID("https://www.youtube.com/watch?v=jNQXAC9IVRw"), "jNQXAC9IVRw");
  assert.equal(youtubeVideoID("https://youtu.be/jNQXAC9IVRw?t=3"), "jNQXAC9IVRw");
  assert.equal(youtubeVideoID("https://music.youtube.com/watch?v=jNQXAC9IVRw"), "jNQXAC9IVRw");
  assert.equal(youtubeVideoID("https://www.youtube.com/shorts/jNQXAC9IVRw"), "jNQXAC9IVRw");
  assert.equal(youtubePlaylistID("https://www.youtube.com/playlist?list=PL1234567890abcdefghijklmnop"), "PL1234567890abcdefghijklmnop");
  assert.equal(youtubePlaylistID("https://www.youtube.com/watch?v=jNQXAC9IVRw&list=PL1234567890abcdefghijklmnop"), "PL1234567890abcdefghijklmnop");
  assert.equal(youtubePlaylistID("https://youtu.be/jNQXAC9IVRw"), null);
  assert.throws(() => youtubePlaylistID("https://www.youtube.com/playlist?list=short"), /playlist URL is invalid/);
  assert.throws(() => youtubeVideoID("https://user:secret@youtube.com/watch?v=jNQXAC9IVRw"), /credentials/);
});

test("parses ordered public Spotify playlist embed tracks", () => {
  const artworkURL = "https://i.scdn.co/image/playlist-cover";
  const html = spotifyEmbedFixture({
    type: "playlist",
    id: spotifyPlaylistID,
    title: "Road Trip",
    subtitle: "Lily",
    coverArt: { sources: [{ url: artworkURL, width: 640 }] },
    trackList: [
      { uri: `spotify:track:${spotifyTrackID}`, title: "First Song", subtitle: "First Artist", duration: 123000, entityType: "track", isPlayable: true },
      { uri: "spotify:episode:ignored", title: "Podcast", subtitle: "Host", duration: 1000, entityType: "episode", isPlayable: true },
      { uri: "spotify:track:11dFghVXANMlKmJXsNCbNl", title: "Second Song", subtitle: "Second Artist", duration: 245000, entityType: "track", isPlayable: true },
    ],
  });
  const parsed = parseSpotifyPlaylistEmbed(html, spotifyPlaylistID);
  assert.equal(parsed.title, "Road Trip");
  assert.equal(parsed.author, "Lily");
  assert.equal(parsed.items.length, 2);
  assert.equal(parsed.items[0].trackNumber, 1);
  assert.equal(parsed.items[1].trackNumber, 3);
  assert.equal(parsed.items[1].durationSeconds, 245);
  assert.equal(parsed.unavailableCount, 1);
  assert.equal(parsed.artworkURL, artworkURL);
  assert.equal(parsed.items[0].artworkURL, null);
  assert.deepEqual(parseSpotifyPlaylistOEmbed({
    provider_name: "Spotify",
    type: "rich",
    title: "Road Trip",
    thumbnail_url: artworkURL,
    html: `<iframe src="https://open.spotify.com/embed/playlist/${spotifyPlaylistID}?utm_source=oembed"></iframe>`,
  }, spotifyPlaylistID), {
    title: "Road Trip",
    artworkURL,
    embedURL: `https://open.spotify.com/embed/playlist/${spotifyPlaylistID}`,
  });
});

test("hydrates Spotify playlist songs with their individual album artwork", async () => {
  const secondTrackID = "11dFghVXANMlKmJXsNCbNl";
  const playlistArtworkURL = "https://i.scdn.co/image/playlist-cover";
  const trackArtwork = new Map([
    [spotifyTrackID, "https://image-cdn-fa.spotifycdn.com/image/first-cover"],
    [secondTrackID, "https://image-cdn-ak.spotifycdn.com/image/second-cover"],
  ]);
  const playlistHTML = spotifyEmbedFixture({
    type: "playlist",
    id: spotifyPlaylistID,
    title: "Road Trip",
    subtitle: "Lily",
    coverArt: { sources: [{ url: playlistArtworkURL, width: 640 }] },
    trackList: [
      { uri: `spotify:track:${spotifyTrackID}`, title: "First Song", subtitle: "First Artist", duration: 123000, entityType: "track", isPlayable: true },
      { uri: `spotify:track:${secondTrackID}`, title: "Second Song", subtitle: "Second Artist", duration: 245000, entityType: "track", isPlayable: true },
    ],
  });
  const fetchImpl = async (input) => {
    const url = new URL(input);
    if (url.pathname === "/oembed") {
      const target = new URL(url.searchParams.get("url"));
      const trackID = target.pathname.split("/").filter(Boolean)[1];
      if (target.pathname.startsWith("/track/")) {
        return new Response(JSON.stringify({
          provider_name: "Spotify",
          type: "rich",
          title: trackID === spotifyTrackID ? "First Song" : "Second Song",
          thumbnail_url: trackArtwork.get(trackID),
          html: `<iframe src="https://open.spotify.com/embed/track/${trackID}"></iframe>`,
        }), { status: 200, headers: { "content-type": "application/json" } });
      }
      return new Response(JSON.stringify({
        provider_name: "Spotify",
        type: "rich",
        title: "Road Trip",
        thumbnail_url: playlistArtworkURL,
        html: `<iframe src="https://open.spotify.com/embed/playlist/${spotifyPlaylistID}"></iframe>`,
      }), { status: 200, headers: { "content-type": "application/json" } });
    }
    if (url.pathname === `/embed/playlist/${spotifyPlaylistID}`) {
      return new Response(playlistHTML, { status: 200, headers: { "content-type": "text/html" } });
    }
    throw new Error(`Unexpected URL ${url}`);
  };

  const playlist = await resolveSpotifyPlaylist(
    `https://open.spotify.com/playlist/${spotifyPlaylistID}`,
    new AbortController().signal,
    fetchImpl,
  );
  assert.equal(playlist.artworkURL, playlistArtworkURL);
  assert.deepEqual(playlist.items.map((item) => item.artworkURL), [...trackArtwork.values()]);
});

test("resolves YouTube playlist metadata and continuation items without inspecting every stream", async () => {
  const playlistID = "PL1234567890abcdefghijklmnop";
  const videoRenderer = (videoID, title, index) => ({
    videoId: videoID,
    title: { runs: [{ text: title }] },
    shortBylineText: { runs: [{ text: "Playlist Artist" }] },
    lengthText: { simpleText: index === 1 ? "3:33" : "4:05" },
    index: { simpleText: String(index) },
    thumbnail: { thumbnails: [{ url: `https://i.ytimg.com/vi/${videoID}/hqdefault.jpg`, width: 480 }] },
    isPlayable: true,
  });
  const initialData = {
    metadata: { playlistMetadataRenderer: { playlistId: playlistID, title: "Road Trip" } },
    header: { playlistHeaderRenderer: { ownerText: { runs: [{ text: "Lily" }] } } },
    contents: [
      { playlistVideoRenderer: videoRenderer("jNQXAC9IVRw", "Me at the zoo", 1) },
      { continuationItemRenderer: { continuationEndpoint: { continuationCommand: { token: "next-page" } } } },
    ],
  };
  const continuationData = {
    onResponseReceivedActions: [{ appendContinuationItemsAction: { continuationItems: [
      { playlistVideoRenderer: videoRenderer("dQw4w9WgXcQ", "Never Gonna Give You Up", 2) },
    ] } }],
  };
  const html = `<script>var ytInitialData = ${JSON.stringify(initialData)};</script><script>ytcfg.set(${JSON.stringify({
    INNERTUBE_API_KEY: "test-key",
    INNERTUBE_CLIENT_VERSION: "2.20260801.00.00",
    VISITOR_DATA: "test-visitor",
  })});</script>`;
  const requests = [];
  const playlist = await resolveYouTubePlaylist(
    `https://www.youtube.com/playlist?list=${playlistID}`,
    new AbortController().signal,
    async (_url, options = {}) => {
      requests.push(options.method || "GET");
      return options.method === "POST"
        ? new Response(JSON.stringify(continuationData), { status: 200, headers: { "content-type": "application/json" } })
        : new Response(html, { status: 200, headers: { "content-type": "text/html" } });
    },
  );
  assert.deepEqual(requests, ["GET", "POST"]);
  assert.equal(playlist.title, "Road Trip");
  assert.equal(playlist.author, "Lily");
  assert.equal(playlist.items.length, 2);
  assert.equal(playlist.items[1].sourceURL, "https://www.youtube.com/watch?v=dQw4w9WgXcQ");
  assert.equal(playlist.items[1].durationSeconds, 245);
  assert.equal(playlist.truncated, false);
  assert.equal(parseYouTubePlaylistData(initialData, playlistID).items[0].playlistIndex, 1);
  const currentRenderer = parseYouTubePlaylistData({ contents: [{ lockupViewModel: {
    contentId: "jNQXAC9IVRw",
    contentType: "LOCKUP_CONTENT_TYPE_VIDEO",
    contentImage: { thumbnailViewModel: {
      image: { sources: [{ url: "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg", width: 480 }] },
      overlays: [{ thumbnailBottomOverlayViewModel: { badges: [{ thumbnailBadgeViewModel: { text: "0:19" } }] } }],
    } },
    metadata: { lockupMetadataViewModel: {
      title: { content: "Me at the zoo" },
      metadata: { contentMetadataViewModel: { metadataRows: [{ metadataParts: [{ text: { content: "jawed" } }] }] } },
    } },
  } }] }, playlistID).items[0];
  assert.equal(currentRenderer.title, "Me at the zoo");
  assert.equal(currentRenderer.artist, "jawed");
  assert.equal(currentRenderer.durationSeconds, 19);
});

test("returns a selectable batch for YouTube playlist imports", async () => {
  const playlistID = "PL1234567890abcdefghijklmnop";
  const result = await resolveLocalImportSource(
    `https://www.youtube.com/playlist?list=${playlistID}`,
    new AbortController().signal,
    () => {},
    {
      resolveYouTubePlaylist: async () => ({
        playlistID,
        title: "Road Trip",
        author: "Lily",
        artworkURL: null,
        sourceURL: `https://www.youtube.com/playlist?list=${playlistID}`,
        items: [{
          videoID: "jNQXAC9IVRw",
          title: "Me at the zoo",
          artist: "jawed",
          durationSeconds: 19,
          thumbnailURL: null,
          sourceProvider: "youtube",
          sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
          playlistIndex: 1,
        }],
        unavailableCount: 0,
        truncated: false,
      }),
    },
    { mediaKind: "audio" },
  );
  assert.equal(result.kind, "youtube_playlist");
  assert.equal(result.track.type, "playlist");
  assert.equal(result.track.title, "Road Trip");
  assert.equal(result.candidates.length, 1);
});

test("chooses the highest verified progressive MP4 that contains video and audio", () => {
  const selected = chooseMP4VideoFormat({
    streamingData: {
      formats: [
        { itag: 18, url: "https://r1---sn.example.googlevideo.com/videoplayback", mimeType: 'video/mp4; codecs="avc1, mp4a"', qualityLabel: "360p", width: 640, height: 360, fps: 30, audioQuality: "AUDIO_QUALITY_LOW", contentLength: "100" },
        { itag: 22, url: "https://r1---sn.example.googlevideo.com/videoplayback", mimeType: 'video/mp4; codecs="avc1, mp4a"', qualityLabel: "720p", width: 1280, height: 720, fps: 30, audioChannels: 2, contentLength: "200" },
        { itag: 137, url: "https://r1---sn.example.googlevideo.com/videoplayback", mimeType: 'video/mp4; codecs="avc1"', qualityLabel: "1080p", width: 1920, height: 1080, fps: 30, contentLength: "300" },
      ],
    },
  });
  assert.equal(selected.itag, 22);
  assert.equal(chooseMP4VideoFormat({ streamingData: { adaptiveFormats: [{ ...selected, itag: 37 }] } }), null);
  const adaptive = chooseMP4VideoOnlyFormat({
    streamingData: {
      adaptiveFormats: [
        { itag: 136, url: selected.url, mimeType: 'video/mp4; codecs="avc1"', qualityLabel: "720p", width: 1280, height: 720, fps: 30, contentLength: "180" },
        { itag: 137, url: selected.url, mimeType: 'video/mp4; codecs="avc1"', qualityLabel: "1080p", width: 1920, height: 1080, fps: 30, contentLength: "280" },
      ],
    },
  });
  assert.equal(adaptive.itag, 137);
});

test("preserves the API Spotify normalization and exact embed validation contract", () => {
  assert.deepEqual(parseSpotifyEmbedEntity(spotifyEmbedFixture(), spotifyTrackID), {
    title: "Never Gonna Give You Up",
    artist: "Rick Astley",
    durationSeconds: 214,
    artworkURL: "https://image-cdn-fa.spotifycdn.com/image/cover",
  });
  assert.deepEqual(parseSpotifyOEmbed({
    provider_name: "Spotify",
    type: "rich",
    title: "Never Gonna Give You Up",
    thumbnail_url: "https://image-cdn-ak.spotifycdn.com/image/cover",
    html: `<iframe src="https://open.spotify.com/embed/track/${spotifyTrackID}?utm_source=oembed"></iframe>`,
  }, spotifyTrackID), {
    title: "Never Gonna Give You Up",
    artworkURL: "https://image-cdn-ak.spotifycdn.com/image/cover",
    embedURL: `https://open.spotify.com/embed/track/${spotifyTrackID}`,
  });
  assert.throws(() => parseSpotifyEmbedEntity(spotifyEmbedFixture({ id: "11dFghVXANMlKmJXsNCbNl" }), spotifyTrackID), LocalImportError);
});

test("parses both provider searches and preserves the API scoring rejection gates", () => {
  const musicRenderer = {
    playlistItemData: { videoId: "dQw4w9WgXcQ" },
    flexColumns: [
      { musicResponsiveListItemFlexColumnRenderer: { text: { runs: [{ text: "Never Gonna Give You Up" }] } } },
      {
        musicResponsiveListItemFlexColumnRenderer: {
          text: {
            runs: [
              { text: "Rick Astley", navigationEndpoint: { browseEndpoint: { browseId: "UCexample" } } },
              { text: " • " },
              { text: "Whenever You Need Somebody", navigationEndpoint: { browseEndpoint: { browseId: "MPREexample" } } },
              { text: " • " },
              { text: "3:34" },
            ],
          },
        },
      },
    ],
  };
  const musicHTML = `<script>var ytInitialData = ${JSON.stringify({ contents: { musicResponsiveListItemRenderer: musicRenderer } })};</script>`;
  const webHTML = `<script>ytInitialData = ${JSON.stringify({
    contents: {
      videoRenderer: {
        videoId: "dQw4w9WgXcQ",
        title: { runs: [{ text: "Rick Astley - Never Gonna Give You Up" }] },
        ownerText: { runs: [{ text: "Rick Astley" }] },
        lengthText: { simpleText: "3:33" },
      },
    },
  })};</script>`;
  assert.equal(parseYouTubeMusicSearch(musicHTML)[0].album, "Whenever You Need Somebody");
  assert.equal(parseYouTubeWebSearch(webHTML)[0].durationSeconds, 213);
  const track = {
    title: "Never Gonna Give You Up",
    artist: "Rick Astley",
    album: "Whenever You Need Somebody",
    durationSeconds: 214,
  };
  const exact = scoreAudioSource(track, {
    ...parseYouTubeMusicSearch(musicHTML)[0],
    thumbnailURL: null,
    officialArtist: true,
  });
  assert.equal(exact.confidence, "possible");
  assert.equal(exact.evidenceStrength, "metadata_only");
  assert.equal(exact.requiresReview, true);
  assert.equal(exact.autoSelectable, false);
  assert.equal(exact.actionable, false);
  assert.equal(scoreAudioSource(track, {
    videoID: "dQw4w9WgXcQ",
    title: "Never Gonna Give You Up (Karaoke Cover)",
    artist: "A Tribute Band",
    album: null,
    durationSeconds: 255,
    thumbnailURL: null,
    sourceProvider: "youtube",
    officialArtist: false,
  }), null);
});

test("keeps the local coordinator observable and cancellable without a Resonance API request", async () => {
  const stages = [];
  let serverRequests = 0;
  const result = await resolveLocalImportSource(
    `https://open.spotify.com/track/${spotifyTrackID}`,
    new AbortController().signal,
    (value) => stages.push(value.stage),
    {
      resolveSpotifyTrack: async () => ({
        provider: "spotify",
        type: "track",
        trackID: spotifyTrackID,
        title: "Never Gonna Give You Up",
        artist: "Rick Astley",
        album: "Whenever You Need Somebody",
        trackNumber: 1,
        durationSeconds: 214,
        artworkURL: null,
        embedURL: `https://open.spotify.com/embed/track/${spotifyTrackID}`,
        sourceURL: `https://open.spotify.com/track/${spotifyTrackID}`,
      }),
      searchYouTubeAudioSources: async () => [{
        videoID: "dQw4w9WgXcQ",
        title: "Never Gonna Give You Up",
        artist: "Rick Astley",
        album: "Whenever You Need Somebody",
        durationSeconds: 214,
        thumbnailURL: null,
        sourceProvider: "youtube_music",
        officialArtist: true,
        sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        score: 1,
        confidence: "high",
        match: { title: 1, artist: 1, album: 1, duration: 1, durationDeltaSeconds: 0 },
      }],
      requestResonanceAPI: async () => { serverRequests += 1; },
    },
  );
  assert.deepEqual(stages, ["resolving_metadata", "searching_candidates"]);
  assert.equal(result.kind, "spotify");
  assert.equal(serverRequests, 0);

  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    resolveLocalImportSource("https://youtu.be/jNQXAC9IVRw", controller.signal, () => {}, {}),
    (error) => error?.name === "AbortError",
  );
});

test("resolves server catalog metadata without preparing import candidates", async () => {
  let candidateSearches = 0;
  const expected = {
    provider: "spotify",
    type: "track",
    trackID: spotifyTrackID,
    title: "Never Gonna Give You Up",
    artist: "Rick Astley",
    album: "Whenever You Need Somebody",
    trackNumber: 1,
    durationSeconds: 214,
    artworkURL: "https://i.scdn.co/image/cover",
    embedURL: `https://open.spotify.com/embed/track/${spotifyTrackID}`,
    sourceURL: `https://open.spotify.com/track/${spotifyTrackID}`,
  };
  const metadata = await resolveLocalImportMetadata(
    expected.sourceURL,
    new AbortController().signal,
    {
      resolveSpotifyTrack: async () => expected,
      searchYouTubeAudioSources: async () => {
        candidateSearches += 1;
        return [];
      },
    },
  );
  assert.deepEqual(metadata, expected);
  assert.equal(candidateSearches, 0);
});

test("saved-link downloads reuse hydrated metadata instead of resolving it again", async () => {
  const metadata = {
    title: "Hydrated song",
    artist: "Hydrated artist",
    album: "Hydrated album",
    durationSeconds: 123,
    artworkURL: "https://i.scdn.co/image/current",
  };
  let metadataRequests = 0;
  let candidateSearches = 0;
  const spotify = await resolveLocalImportDownloadSource(
    `https://open.spotify.com/track/${spotifyTrackID}`,
    metadata,
    new AbortController().signal,
    () => {},
    {
      resolveSpotifyTrack: async () => {
        metadataRequests += 1;
        throw new Error("metadata should be reused");
      },
      searchYouTubeAudioSources: async (track) => {
        candidateSearches += 1;
        assert.equal(track.title, metadata.title);
        return [{ videoID: "jNQXAC9IVRw", sourceURL: "https://youtu.be/jNQXAC9IVRw" }];
      },
    },
  );
  assert.equal(spotify.track.title, metadata.title);
  assert.equal(spotify.candidates.length, 1);
  assert.equal(metadataRequests, 0);
  assert.equal(candidateSearches, 1);

  let inspections = 0;
  const youtube = await resolveLocalImportDownloadSource(
    "https://youtu.be/jNQXAC9IVRw",
    metadata,
    new AbortController().signal,
    () => {},
    {
      inspectYouTubeAudio: async () => {
        inspections += 1;
        throw new Error("stream inspection belongs to the byte-transfer step");
      },
    },
  );
  assert.equal(youtube.track.title, metadata.title);
  assert.equal(youtube.candidates[0].sourceURL, "https://youtu.be/jNQXAC9IVRw");
  assert.equal(inspections, 0);
});

test("hydrated SoundCloud downloads resolve the rendition once and hand it directly to import", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-prepared-soundcloud-test-"));
  const library = path.join(root, "library");
  const sourceURL = "https://soundcloud.com/resonance/hydrated-song";
  const preparationContext = JSON.stringify({
    serverOrigin: "https://music.example",
    profileID: "profile-a",
    songID: "song-a",
  });
  const bytes = Buffer.from("prepared SoundCloud audio bytes");
  const sourceSha256 = createHash("sha256").update(bytes).digest("hex");
  const preparedAudio = {
    track: {
      provider: "soundcloud",
      type: "track",
      trackID: "12345",
      title: "Stale provider title",
      artist: "Stale provider artist",
      album: null,
      durationSeconds: 90,
      artworkURL: null,
      sourceURL,
    },
    streamingURL: "https://cf-media.sndcdn.com/prepared.mp3",
    contentLength: bytes.length,
    contentType: "audio/mpeg",
    durationSeconds: 90,
    sourceURL,
  };
  let metadataResolutions = 0;
  let audioResolutions = 0;
  let preparedDownloads = 0;
  let fallbackDownloads = 0;
  try {
    const resolution = await resolveLocalImportDownloadSource(
      sourceURL,
      {
        title: "Hydrated title",
        artist: "Hydrated artist",
        album: "Hydrated album",
        durationSeconds: 123,
        artworkURL: null,
      },
      new AbortController().signal,
      () => {},
      {
        resolveSoundCloudSource: async () => {
          metadataResolutions += 1;
          throw new Error("catalog metadata must be reused");
        },
        resolveSoundCloudAudio: async () => {
          audioResolutions += 1;
          return preparedAudio;
        },
      },
      { mediaKind: "audio", preparationContext },
    );
    assert.equal(resolution.track.title, "Hydrated title");
    assert.equal(resolution.track.artist, "Hydrated artist");
    assert.equal(resolution.track.durationSeconds, 123);
    assert.equal(metadataResolutions, 0);
    assert.equal(audioResolutions, 1);

    const candidate = resolution.candidates[0];
    const imported = await importConfirmedSource({
      sourceURL: candidate.sourceURL,
      mediaKind: "audio",
      metadata: resolution.track,
      preparedSoundCloudAudio: candidate.preparedSoundCloudAudio,
      preparationContext,
      existing: [],
      destinationDirectory: library,
      temporaryRoot: root,
    }, new AbortController().signal, () => {}, {
      downloadSoundCloudAudio: async () => {
        fallbackDownloads += 1;
        audioResolutions += 1;
        throw new Error("the prepared rendition should be reused");
      },
      downloadResolvedSoundCloudAudio: async (resolved, destination) => {
        preparedDownloads += 1;
        assert.equal(resolved, preparedAudio);
        await fs.writeFile(destination, bytes);
        return { sha256: sourceSha256, bytesWritten: bytes.length };
      },
      fetchArtwork: async () => null,
      tagM4A: async (source, destination) => fs.copyFile(source, destination),
    });
    assert.equal(imported.kind, "created");
    assert.equal(imported.metadata.title, "Hydrated title");
    assert.equal(metadataResolutions, 0);
    assert.equal(audioResolutions, 1);
    assert.equal(preparedDownloads, 1);
    assert.equal(fallbackDownloads, 0);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("prepared SoundCloud audio is context-bound, single-use, and expires", () => {
  const resolved = { streamingURL: "https://cf-media.sndcdn.com/prepared.mp3" };
  const source = "https://soundcloud.com/resonance/prepared";
  const context = "server/profile/song";
  const singleUse = createPreparedSoundCloudAudioHandoff(resolved, {
    source,
    mediaKind: "audio",
    preparationContext: context,
    nowMilliseconds: 10,
  });
  assert.equal(singleUse.consume({
    source,
    mediaKind: "audio",
    preparationContext: context,
    nowMilliseconds: 11,
  }), resolved);
  assert.equal(singleUse.consume({
    source,
    mediaKind: "audio",
    preparationContext: context,
    nowMilliseconds: 12,
  }), null);

  const wrongContext = createPreparedSoundCloudAudioHandoff(resolved, {
    source,
    mediaKind: "audio",
    preparationContext: context,
    nowMilliseconds: 10,
  });
  assert.equal(wrongContext.consume({
    source,
    mediaKind: "audio",
    preparationContext: "another-profile",
    nowMilliseconds: 11,
  }), null);
  assert.equal(wrongContext.consume({
    source,
    mediaKind: "audio",
    preparationContext: context,
    nowMilliseconds: 12,
  }), null);

  const wrongSource = createPreparedSoundCloudAudioHandoff(resolved, {
    source,
    mediaKind: "audio",
    preparationContext: context,
    nowMilliseconds: 10,
  });
  assert.equal(wrongSource.consume({
    source: "https://soundcloud.com/resonance/different",
    mediaKind: "audio",
    preparationContext: context,
    nowMilliseconds: 11,
  }), null);

  const wrongMediaKind = createPreparedSoundCloudAudioHandoff(resolved, {
    source,
    mediaKind: "audio",
    preparationContext: context,
    nowMilliseconds: 10,
  });
  assert.equal(wrongMediaKind.consume({
    source,
    mediaKind: "video",
    preparationContext: context,
    nowMilliseconds: 11,
  }), null);

  const expired = createPreparedSoundCloudAudioHandoff(resolved, {
    source,
    mediaKind: "audio",
    preparationContext: context,
    nowMilliseconds: 10,
  });
  assert.equal(expired.consume({
    source,
    mediaKind: "audio",
    preparationContext: context,
    nowMilliseconds: 10 + PREPARED_SOUNDCLOUD_AUDIO_TTL_MS + 1,
  }), null);
});

test("resolves YouTube catalog metadata with one bounded oEmbed request", async () => {
  const requests = [];
  const metadata = await resolveYouTubeMetadata(
    "https://youtu.be/jNQXAC9IVRw",
    new AbortController().signal,
    async (input, options) => {
      const url = new URL(input);
      requests.push({ url, options });
      return new Response(JSON.stringify({
        type: "video",
        provider_name: "YouTube",
        title: "Me at the zoo",
        author_name: "jawed",
        thumbnail_url: "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg",
      }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    },
  );
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url.origin, "https://www.youtube.com");
  assert.equal(requests[0].url.pathname, "/oembed");
  assert.equal(requests[0].url.searchParams.get("format"), "json");
  assert.equal(requests[0].options.redirect, "error");
  assert.equal(metadata.title, "Me at the zoo");
  assert.equal(metadata.artist, "jawed");
  assert.equal(metadata.durationSeconds, null);
  assert.equal(metadata.sourceURL, "https://www.youtube.com/watch?v=jNQXAC9IVRw");
});

test("returns an ordered selectable batch for Spotify playlists", async () => {
  const tracks = [
    { provider: "spotify", type: "track", trackID: spotifyTrackID, title: "First Song", artist: "First Artist", album: null, trackNumber: 1, durationSeconds: 123, artworkURL: null, embedURL: "", sourceURL: `https://open.spotify.com/track/${spotifyTrackID}` },
    { provider: "spotify", type: "track", trackID: "11dFghVXANMlKmJXsNCbNl", title: "Second Song", artist: "Second Artist", album: null, trackNumber: 2, durationSeconds: 245, artworkURL: null, embedURL: "", sourceURL: "https://open.spotify.com/track/11dFghVXANMlKmJXsNCbNl" },
  ];
  const result = await resolveLocalImportSource(
    `https://open.spotify.com/playlist/${spotifyPlaylistID}`,
    new AbortController().signal,
    () => {},
    {
      resolveSpotifyPlaylist: async () => ({
        playlistID: spotifyPlaylistID,
        title: "Road Trip",
        author: "Lily",
        artworkURL: null,
        sourceURL: `https://open.spotify.com/playlist/${spotifyPlaylistID}`,
        items: tracks,
        unavailableCount: 0,
        truncated: false,
      }),
      searchYouTubeAudioSources: async (track) => [{
        videoID: track.trackNumber === 1 ? "jNQXAC9IVRw" : "dQw4w9WgXcQ",
        title: track.title,
        artist: track.artist,
        durationSeconds: track.durationSeconds,
        thumbnailURL: null,
        sourceProvider: "youtube",
        sourceURL: `https://www.youtube.com/watch?v=${track.trackNumber === 1 ? "jNQXAC9IVRw" : "dQw4w9WgXcQ"}`,
        score: 1,
        confidence: "high",
      }],
    },
  );
  assert.equal(result.kind, "spotify_playlist");
  assert.equal(result.track.title, "Road Trip");
  assert.deepEqual(result.candidates.map((candidate) => candidate.importMetadata.title), ["First Song", "Second Song"]);
  assert.deepEqual(result.candidates.map((candidate) => candidate.playlistIndex), [1, 2]);
});

test("resolves direct YouTube video mode without offering it for Spotify metadata", async () => {
  const stages = [];
  const result = await resolveLocalImportSource(
    "https://youtu.be/jNQXAC9IVRw",
    new AbortController().signal,
    (value) => stages.push(value.stage),
    {
      inspectYouTubeVideo: async () => ({
        videoID: "jNQXAC9IVRw",
        title: "Me at the zoo",
        author: "jawed",
        durationSeconds: 19,
        thumbnailURL: "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg",
        contentType: "video/mp4",
        qualityLabel: "720p",
        width: 1280,
        height: 720,
        fps: 30,
        sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
      }),
    },
    { mediaKind: "video" },
  );
  assert.deepEqual(stages, ["inspecting_source"]);
  assert.equal(result.kind, "youtube");
  assert.equal(result.mediaKind, "video");
  assert.equal(result.candidates[0].quality, "720p");
  assert.equal(result.candidates[0].contentType, "video/mp4");
  await assert.rejects(
    resolveLocalImportSource(
      `https://open.spotify.com/track/${spotifyTrackID}`,
      new AbortController().signal,
      () => {},
      {},
      { mediaKind: "video" },
    ),
    /direct YouTube video URL/,
  );
});

test("forwards the snapshotted Windows client context and exposes only explicit review candidates", async () => {
  const track = {
    provider: "spotify",
    type: "track",
    trackID: spotifyTrackID,
    title: "Never Gonna Give You Up",
    artist: "Rick Astley",
    album: "Whenever You Need Somebody",
    durationSeconds: 214,
    artworkURL: "https://image-cdn-fa.spotifycdn.com/image/cover",
    sourceURL: `https://open.spotify.com/track/${spotifyTrackID}`,
  };
  let request = null;
  const candidates = await searchFileBackedSources(track, {
    baseURL: "https://music.example",
    adminToken: "admin-secret",
    profileID: "drastic",
    clientContextHeaders: windowsClientContextHeaders,
  }, new AbortController().signal, async (url, options) => {
    request = { url: url.toString(), options };
    return new Response(JSON.stringify({
      review_candidates: [{
        provider: "youtube_music",
        source_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        video_id: "dQw4w9WgXcQ",
        title: "Rick Astley - Never Gonna Give You Up",
        artist: "Rick Astley",
        album: "Whenever You Need Somebody",
        duration_seconds: 213,
        thumbnail_url: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        score: 0.99,
        confidence: "possible",
        evidence_strength: "metadata_only",
        requires_review: true,
        auto_selectable: false,
        actionable: false,
        match: {
          title: 1,
          artist: 1,
          album: 0.9,
          duration: 0.88,
          duration_delta_seconds: 1,
        },
      }],
    }), { status: 200, headers: { "content-type": "application/json" } });
  });
  assert.equal(request.url, "https://music.example/api/v1/admin/debrid/resolve");
  assert.equal(request.options.headers.Authorization, "Bearer admin-secret");
  assert.equal(request.options.headers["X-Resonance-Profile"], "drastic");
  assert.equal(request.options.redirect, "manual");
  for (const [name, value] of Object.entries(windowsClientContextHeaders)) {
    assert.equal(request.options.headers[name], value);
  }
  assert.equal(JSON.parse(request.options.body).source, track.sourceURL);
  assert.equal(candidates.length, 1);
  assert.equal(candidates[0].sourceProvider, "youtube_music");
  assert.equal(candidates[0].sourceURL, "https://www.youtube.com/watch?v=dQw4w9WgXcQ");
  assert.equal(candidates[0].serverBacked, false);
  assert.equal(candidates[0].requiresReview, true);
  assert.equal(candidates[0].autoSelectable, false);
  assert.equal(candidates[0].actionable, false);
  assert.deepEqual(candidates[0].match, {
    title: 1,
    artist: 1,
    album: 0.9,
    duration: 0.88,
    durationDeltaSeconds: 1,
  });

  assert.deepEqual(await searchFileBackedSources(track, {
    baseURL: "https://music.example",
    adminToken: "",
    profileID: "default",
  }, new AbortController().signal, async () => { throw new Error("must not fetch"); }), []);
});

test("fails reviewed lookup closed for missing context and rejects legacy or actionable server results", async () => {
  const track = {
    title: "Never Gonna Give You Up",
    artist: "Rick Astley",
    sourceURL: `https://open.spotify.com/track/${spotifyTrackID}`,
  };
  let requests = 0;
  await assert.rejects(
    searchFileBackedSources(track, {
      baseURL: "https://music.example",
      adminToken: "admin-secret",
      profileID: "drastic",
    }, new AbortController().signal, async () => {
      requests += 1;
      throw new Error("must not fetch");
    }),
    (error) => error?.code === "INVALID_CLIENT_CONTEXT",
  );
  assert.equal(requests, 0);

  const candidates = await searchFileBackedSources(track, {
    baseURL: "https://music.example",
    adminToken: "admin-secret",
    profileID: "drastic",
    clientContextHeaders: windowsClientContextHeaders,
  }, new AbortController().signal, async () => new Response(JSON.stringify({
    releases: [{
      title: "Legacy torrent result",
      magnet_link: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
    }],
    review_candidates: [
      {
        provider: "youtube",
        source_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        video_id: "dQw4w9WgXcQ",
        title: "Unsafe automatic result",
        score: 1,
        requires_review: true,
        auto_selectable: false,
        actionable: true,
        match: { title: 1, artist: 1, album: null, duration: 1, duration_delta_seconds: 0 },
      },
      {
        provider: "youtube",
        source_url: "https://youtu.be/dQw4w9WgXcQ",
        video_id: "dQw4w9WgXcQ",
        title: "Non-canonical result",
        score: 1,
        requires_review: true,
        auto_selectable: false,
        actionable: false,
        match: { title: 1, artist: 1, album: null, duration: 1, duration_delta_seconds: 0 },
      },
    ],
  }), { status: 200, headers: { "content-type": "application/json" } }));
  assert.deepEqual(candidates, []);
});

test("resumes a TorBox file selection and verifies the downloaded local file", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-debrid-test-"));
  const library = path.join(root, "library");
  const audio = Buffer.from("verified external audio file");
  const stages = [];
  const requests = [];
  try {
    const selected = await importFileBackedSource({
      baseURL: "https://music.example",
      adminToken: "admin-secret",
      profileID: "drastic",
      sourceURL: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
      metadata: {
        title: "Never Gonna Give You Up",
        artist: "Rick Astley",
        album: "Whenever You Need Somebody",
        durationSeconds: 214,
        artworkURL: "https://image-cdn-fa.spotifycdn.com/image/cover",
        sourceURL: `https://open.spotify.com/track/${spotifyTrackID}`,
      },
      existing: [],
      destinationDirectory: library,
    }, new AbortController().signal, () => {}, async () => new Response(JSON.stringify({
      status: "selection_required",
      audio_files: [{ id: 7, name: "01 - Never Gonna Give You Up.flac", size: audio.length, content_type: "audio/flac" }],
      resume: { transfer_kind: "torrent", transfer_id: "42" },
    }), { status: 409, headers: { "content-type": "application/json" } }));
    assert.equal(selected.kind, "selection_required");
    assert.equal(selected.files[0].id, 7);

    const imported = await importFileBackedSource({
      baseURL: "https://music.example",
      adminToken: "admin-secret",
      profileID: "drastic",
      resume: selected.resume,
      fileID: 7,
      metadata: {
        title: "Never Gonna Give You Up",
        artist: "Rick Astley",
        album: "Whenever You Need Somebody",
        sourceURL: `https://open.spotify.com/track/${spotifyTrackID}`,
      },
      existing: [],
      destinationDirectory: library,
    }, new AbortController().signal, (value) => stages.push(value.stage), async (url, options) => {
      requests.push({ url: url.toString(), options });
      if (options?.method === "POST") {
        return new Response(JSON.stringify({
          provider: "torbox",
          status: "imported",
          source_file: { id: 7, name: "01 - Never Gonna Give You Up.flac", size: audio.length },
          song: { id: "remote-song", filename: "01 - Never Gonna Give You Up.flac" },
          temporary_download_url: "https://music.example/api/v1/downloads/remote-song?signature=temporary",
        }), { status: 201, headers: { "content-type": "application/json" } });
      }
      return new Response(audio, {
        status: 200,
        headers: { "content-type": "audio/flac", "content-length": String(audio.length) },
      });
    });
    assert.equal(imported.kind, "created");
    assert.equal(imported.serverBacked, true);
    assert.equal(imported.sourceSha256, createHash("sha256").update(audio).digest("hex"));
    assert.deepEqual(await fs.readFile(imported.filePath), audio);
    assert.equal(path.extname(imported.filePath), ".flac");
    assert.deepEqual(stages, ["preparing_external", "downloading", "saving_local"]);
    assert.equal(JSON.parse(requests[0].options.body).file_id, 7);
    assert.equal(requests[1].url, "https://music.example/api/v1/downloads/remote-song?signature=temporary");
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("verifies consecutive download ranges and deletes a mismatched partial file", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-range-test-"));
  const destination = path.join(directory, "audio.m4a");
  const bytes = Buffer.from("verified audio");
  const resolved = {
    streamingURL: "https://r1---sn.example.googlevideo.com/videoplayback",
    streamingHeaders: {},
    contentLength: bytes.length,
  };
  try {
    const result = await downloadResolvedAudio(
      resolved,
      destination,
      new AbortController().signal,
      () => {},
      async (_url, options) => {
        assert.equal(options.headers.Range, `bytes=0-${bytes.length - 1}`);
        return new Response(bytes, {
          status: 206,
          headers: {
            "content-range": `bytes 0-${bytes.length - 1}/${bytes.length}`,
            "content-length": String(bytes.length),
          },
        });
      },
    );
    assert.equal(result.sha256, createHash("sha256").update(bytes).digest("hex"));
    assert.deepEqual(await fs.readFile(destination), bytes);
    assert.equal(verifiedContentRange("bytes 0-4/5", 0, 4, 5), 5);

    const failedPath = path.join(directory, "failed.m4a");
    await assert.rejects(downloadResolvedAudio(
      { ...resolved, contentLength: 5 },
      failedPath,
      new AbortController().signal,
      () => {},
      async () => new Response(Buffer.from("bad"), {
        status: 206,
        headers: { "content-range": "bytes 1-3/5", "content-length": "3" },
      }),
    ), /unverifiable audio range/);
    await assert.rejects(fs.access(failedPath));
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});

test("downloads a verified MP4 video stream without stripping its video bytes", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-video-range-test-"));
  const destination = path.join(directory, "video.mp4");
  const bytes = Buffer.from("verified progressive mp4 video and audio");
  try {
    const result = await downloadResolvedVideo({
      streamingURL: "https://r1---sn.example.googlevideo.com/videoplayback",
      streamingHeaders: {},
      contentLength: bytes.length,
    }, destination, new AbortController().signal, () => {}, async (_url, options) => {
      assert.equal(options.headers.Range, `bytes=0-${bytes.length - 1}`);
      return new Response(bytes, {
        status: 206,
        headers: {
          "content-range": `bytes 0-${bytes.length - 1}/${bytes.length}`,
          "content-length": String(bytes.length),
        },
      });
    });
    assert.equal(result.sha256, createHash("sha256").update(bytes).digest("hex"));
    assert.deepEqual(await fs.readFile(destination), bytes);
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});

test("saves a confirmed YouTube video without waiting for unfinished metadata enrichment", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-video-import-test-"));
  const library = path.join(root, "library");
  const sourceBytes = Buffer.from("original combined YouTube MP4 bytes");
  const sourceSha256 = createHash("sha256").update(sourceBytes).digest("hex");
  const stages = [];
  let timeoutID;
  try {
    const importPromise = importConfirmedSource({
      sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
      mediaKind: "video",
      metadata: {
        title: "Me at the zoo",
        artist: "jawed",
        album: "YouTube",
        sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
        artworkURL: null,
      },
      metadataPromise: new Promise(() => {}),
      existing: [],
      destinationDirectory: library,
      temporaryRoot: root,
    }, new AbortController().signal, (value) => stages.push(value.stage), {
      downloadYouTubeVideo: async (_source, destination) => {
        await fs.writeFile(destination, sourceBytes);
        return {
          preview: {
            videoID: "jNQXAC9IVRw",
            title: "Me at the zoo",
            author: "jawed",
            durationSeconds: 19,
            thumbnailURL: null,
            sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
          },
          download: { path: destination, sha256: sourceSha256, size: sourceBytes.length },
        };
      },
    });
    const imported = await Promise.race([
      importPromise,
      new Promise((_, reject) => {
        timeoutID = setTimeout(() => reject(new Error("media import waited for optional metadata")), 2_000);
      }),
    ]);
    assert.equal(imported.kind, "created");
    assert.equal(imported.mediaKind, "video");
    assert.equal(path.extname(imported.filePath), ".mp4");
    assert.equal(imported.sourceSha256, sourceSha256);
    assert.equal(imported.contentSha256, sourceSha256);
    assert.deepEqual(await fs.readFile(imported.filePath), sourceBytes);
    assert.deepEqual(stages, ["inspecting_source", "saving_local"]);
  } finally {
    clearTimeout(timeoutID);
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("losslessly muxes separate verified YouTube video and audio streams", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-adaptive-video-test-"));
  const videoFixture = path.join(root, "video-only.mp4");
  const audioFixture = path.join(root, "audio-only.m4a");
  const library = path.join(root, "library");
  const ffmpeg = await import("ffmpeg-static").then((module) => module.default);
  const generatedVideo = spawnSync(ffmpeg, [
    "-y", "-f", "lavfi", "-i", "color=c=black:s=32x32:d=0.2", "-an", "-c:v", "mpeg4", videoFixture,
  ], { encoding: "utf8" });
  const generatedAudio = spawnSync(ffmpeg, [
    "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2", "-c:a", "aac", audioFixture,
  ], { encoding: "utf8" });
  assert.equal(generatedVideo.status, 0, generatedVideo.stderr);
  assert.equal(generatedAudio.status, 0, generatedAudio.stderr);
  const stages = [];
  try {
    const imported = await importConfirmedSource({
      sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
      mediaKind: "video",
      metadata: {
        title: "Adaptive Video",
        artist: "Resonance",
        album: "YouTube",
        sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
        artworkURL: null,
      },
      existing: [],
      destinationDirectory: library,
      temporaryRoot: root,
    }, new AbortController().signal, (value) => stages.push(value.stage), {
      downloadYouTubeVideo: async (_source, destination) => {
        const videoPath = `${destination}.video.mp4`;
        const audioPath = `${destination}.audio.m4a`;
        await fs.copyFile(videoFixture, videoPath);
        await fs.copyFile(audioFixture, audioPath);
        return {
          preview: {
            videoID: "jNQXAC9IVRw",
            title: "Adaptive Video",
            author: "Resonance",
            durationSeconds: 1,
            thumbnailURL: null,
            sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
          },
          separateStreams: {
            video: { path: videoPath, size: (await fs.stat(videoPath)).size },
            audio: { path: audioPath, size: (await fs.stat(audioPath)).size },
          },
        };
      },
    });
    assert.equal(imported.kind, "created");
    assert.equal(path.extname(imported.filePath), ".mp4");
    assert.deepEqual(stages, ["inspecting_source", "processing", "saving_local"]);
    const tags = await metadata.readAudioMetadata(imported.filePath);
    assert.equal(tags.title, "Adaptive Video");
    assert.equal(tags.artist, "Resonance");
    assert.ok(tags.duration > 0);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("tags a downloaded M4A locally, saves it outside profile ownership, and detects repeats", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-import-test-"));
  const fixture = path.join(root, "fixture.m4a");
  const library = path.join(root, "library");
  const ffmpeg = await import("ffmpeg-static").then((module) => module.default);
  const generated = spawnSync(ffmpeg, [
    "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.15",
    "-c:a", "aac", "-b:a", "96k", fixture,
  ], { encoding: "utf8" });
  assert.equal(generated.status, 0, generated.stderr);
  const sourceBytes = await fs.readFile(fixture);
  const sourceSha256 = createHash("sha256").update(sourceBytes).digest("hex");
  const stages = [];
  try {
    const imported = await importConfirmedSource({
      sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
      metadata: {
        title: "Local Test",
        artist: "Resonance",
        album: "Device Library",
        sourceURL: `https://open.spotify.com/track/${spotifyTrackID}`,
        artworkURL: null,
      },
      existing: [],
      destinationDirectory: library,
      temporaryRoot: root,
    }, new AbortController().signal, (value) => stages.push(value.stage), {
      downloadYouTubeAudio: async (_source, destination) => {
        await fs.copyFile(fixture, destination);
        return {
          preview: {
            videoID: "jNQXAC9IVRw",
            title: "Fallback",
            author: "Uploader",
            durationSeconds: 1,
            thumbnailURL: null,
            sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
          },
          mediaSourceURL: "https://media.example/local-test.m4a",
          download: { path: destination, sha256: sourceSha256, size: sourceBytes.length },
        };
      },
    });
    assert.equal(imported.kind, "created");
    assert.equal(imported.sourceSha256, sourceSha256);
    assert.equal(imported.metadata.title, "Local Test");
    assert.equal(imported.sourceIdentity.providerID, "jNQXAC9IVRw");
    assert.equal(imported.sourceIdentity.sourcePageURL, `https://open.spotify.com/track/${spotifyTrackID}`);
    assert.equal(imported.sourceIdentity.mediaSourceURL, "https://media.example/local-test.m4a");
    assert.deepEqual(stages, ["inspecting_source", "processing", "saving_local"]);
    const tags = await metadata.readAudioMetadata(imported.filePath);
    assert.equal(tags.title, "Local Test");
    assert.equal(tags.artist, "Resonance");
    assert.equal(tags.album, "Device Library");
    assert.equal(duplicateTrack([{ id: "existing", sourceSha256 }], sourceSha256).id, "existing");

    const duplicate = await importConfirmedSource({
      sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
      sourceIdentity: imported.sourceIdentity,
      metadata: imported.metadata,
      existing: [{ id: "existing", sourceSha256 }],
      destinationDirectory: library,
      temporaryRoot: root,
    }, new AbortController().signal, () => {}, {
      downloadYouTubeAudio: async (_source, destination) => {
        await fs.copyFile(fixture, destination);
        return {
          preview: {
            videoID: "jNQXAC9IVRw",
            title: "Fallback",
            author: "Uploader",
            durationSeconds: 1,
            thumbnailURL: null,
            sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
          },
          mediaSourceURL: "https://media.example/local-test.m4a",
          download: { path: destination, sha256: sourceSha256, size: sourceBytes.length },
        };
      },
    });
    assert.equal(duplicate.kind, "duplicate");
    assert.equal(duplicate.sourceIdentity.providerID, "jNQXAC9IVRw");
    assert.equal(duplicate.sourceIdentity.mediaSourceURL, "https://media.example/local-test.m4a");
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("permits only known provider artwork hosts", () => {
  assert.equal(safeArtworkURL("https://i.scdn.co/image/example")?.hostname, "i.scdn.co");
  assert.equal(safeArtworkURL("https://i1.sndcdn.com/artworks-example-large.jpg")?.hostname, "i1.sndcdn.com");
  assert.equal(safeArtworkURL("https://i.ytimg.com/vi/example/hqdefault.jpg")?.hostname, "i.ytimg.com");
  assert.equal(safeArtworkURL("https://attacker.example/cover.jpg"), null);
  assert.equal(safeArtworkURL("http://i.ytimg.com/cover.jpg"), null);
});
