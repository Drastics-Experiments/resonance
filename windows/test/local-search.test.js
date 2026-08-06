import assert from "node:assert/strict";
import test from "node:test";

import search from "../local-search.cjs";

const { looksLikeLink, parseSpotifySearch, searchAllPlatforms } = search;

const spotifyID = "4PTG3Z6ehGkBFwjybzWkR8";
const youtubeID = "jNQXAC9IVRw";

function youtubeSearchHTML() {
  return `<script>var ytInitialData = ${JSON.stringify({
    contents: [{
      musicResponsiveListItemRenderer: {
        playlistItemData: { videoId: youtubeID },
        flexColumns: [
          { musicResponsiveListItemFlexColumnRenderer: { text: { runs: [{ text: "Test Song" }] } } },
          { musicResponsiveListItemFlexColumnRenderer: { text: { runs: [
            { text: "Test Artist", navigationEndpoint: { browseEndpoint: { browseId: "UCtest" } } },
            { text: " • " },
            { text: "Test Album", navigationEndpoint: { browseEndpoint: { browseId: "MPREtest" } } },
            { text: " • " },
            { text: "3:34" },
          ] } } },
        ],
        thumbnail: { musicThumbnailRenderer: { thumbnail: { thumbnails: [{ url: "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg" }] } } },
      },
    }],
  })};</script>`;
}

test("distinguishes plain music searches from links", () => {
  assert.equal(looksLikeLink("Test Song Test Artist"), false);
  assert.equal(looksLikeLink("https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8"), true);
  assert.equal(looksLikeLink("www.youtube.com/watch?v=jNQXAC9IVRw"), true);
  assert.equal(looksLikeLink("example.com/song"), true);
});

test("parses bounded public Spotify search metadata", () => {
  const tracks = parseSpotifySearch({ data: { tracks: [{
    id: spotifyID,
    title: "Test Song",
    artist: "Test Artist",
    album: "Test Album",
    duration: 214,
    artworkURL: "https://i.scdn.co/image/cover",
  }] } });
  assert.equal(tracks.length, 1);
  assert.equal(tracks[0].sourceURL, `https://open.spotify.com/track/${spotifyID}`);
  assert.equal(tracks[0].durationSeconds, 214);
});

test("queries Spotify, SoundCloud, and YouTube and returns previewable grouped results", async () => {
  const requested = [];
  const fetchImpl = async (input) => {
    const url = new URL(input);
    requested.push(`${url.hostname}${url.pathname}`);
    if (url.hostname === "debridvault.elfhosted.com") {
      return new Response(JSON.stringify({ success: true, data: { tracks: [{
        id: spotifyID,
        title: "Test Song",
        artist: "Test Artist",
        album: "Test Album",
        duration: 214,
        artworkURL: "https://i.scdn.co/image/cover",
      }] } }), { status: 200, headers: { "content-type": "application/json" } });
    }
    if (url.hostname === "soundcloud.com") {
      return new Response(`<script>window.__sc_hydration = ${JSON.stringify([
        { hydratable: "apiClient", data: { id: "TwElDfIgW9RpAzLMUSy9g1VvI2Kao7my" } },
      ])};</script>`, { status: 200, headers: { "content-type": "text/html" } });
    }
    if (url.hostname === "api-v2.soundcloud.com") {
      return new Response(JSON.stringify({ collection: [{
        kind: "track",
        id: 123,
        title: "Test Song",
        permalink_url: "https://soundcloud.com/test-artist/test-song",
        duration: 214000,
        streamable: true,
        policy: "ALLOW",
        track_authorization: "authorization",
        user: { username: "Test Artist", avatar_url: "https://i1.sndcdn.com/avatars-test-large.jpg" },
        publisher_metadata: { artist: "Test Artist", album_title: "Test Album" },
        media: { transcodings: [{
          url: "https://api-v2.soundcloud.com/media/test/stream/progressive",
          snipped: false,
          format: { protocol: "progressive", mime_type: "audio/mpeg" },
        }] },
      }] }), { status: 200, headers: { "content-type": "application/json" } });
    }
    if (url.hostname === "music.youtube.com") {
      return new Response(youtubeSearchHTML(), { status: 200, headers: { "content-type": "text/html" } });
    }
    if (url.hostname === "www.youtube.com") {
      return new Response("<html></html>", { status: 200, headers: { "content-type": "text/html" } });
    }
    return new Response("Not found", { status: 404 });
  };

  const result = await searchAllPlatforms("Test Song Test Artist", new AbortController().signal, fetchImpl);
  assert.deepEqual(result.providerCounts, { spotify: 1, soundcloud: 1, youtube: 1 });
  assert.deepEqual(result.candidates.map((candidate) => candidate.searchProvider), ["spotify", "soundcloud", "youtube"]);
  assert.equal(result.candidates.every((candidate) => typeof candidate.sourceURL === "string"), true);
  assert.equal(result.candidates.every((candidate) => candidate.importMetadata?.title === "Test Song"), true);
  assert.equal(requested.includes("debridvault.elfhosted.com/api/search"), true);
  assert.equal(requested.includes("soundcloud.com/search/sounds"), true);
  assert.equal(requested.includes("api-v2.soundcloud.com/search/tracks"), true);
  assert.equal(requested.includes("music.youtube.com/search"), true);
  assert.equal(requested.includes("www.youtube.com/results"), true);
});
