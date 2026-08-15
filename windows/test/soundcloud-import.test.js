import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import platform from "../local-import-platform.cjs";
import soundcloud from "../local-soundcloud.cjs";

const {
  downloadResolvedSoundCloudAudio,
  isSoundCloudURL,
  parseSoundCloudHydration,
  parseSoundCloudTrack,
  resolveSoundCloudAudio,
  resolveSoundCloudSource,
  soundCloudSourceURL,
} = soundcloud;
const { importConfirmedSource, m4aTagArguments, resolveLocalImportSource } = platform;

const clientID = "TwElDfIgW9RpAzLMUSy9g1VvI2Kao7my";

function trackRecord(id, title, artist, options = {}) {
  return {
    id,
    kind: "track",
    title,
    full_duration: options.duration ?? 213_886,
    artwork_url: `https://i1.sndcdn.com/artworks-${id}-large.jpg`,
    permalink_url: `https://soundcloud.com/${artist.toLowerCase().replaceAll(" ", "-")}/${title.toLowerCase().replaceAll(" ", "-")}`,
    public: true,
    streamable: true,
    policy: "ALLOW",
    track_authorization: `authorization-${id}`,
    user: { username: artist, avatar_url: "https://i1.sndcdn.com/avatar-large.jpg" },
    publisher_metadata: { artist, album_title: options.album ?? "SoundCloud Album" },
    media: {
      transcodings: options.direct === false ? [] : [{
        url: `https://api-v2.soundcloud.com/media/soundcloud:tracks:${id}/stream/progressive`,
        preset: "mp3_1_0",
        snipped: false,
        format: { protocol: "progressive", mime_type: "audio/mpeg" },
      }],
    },
  };
}

function hydrationHTML(values) {
  return `<html><script>window.__sc_hydration = ${JSON.stringify([
    { hydratable: "apiClient", data: { id: clientID, isExpiring: false } },
    ...values,
  ])};</script></html>`;
}

test("accepts only credential-free HTTPS SoundCloud source URLs", () => {
  assert.equal(isSoundCloudURL("https://soundcloud.com/forss/flickermood"), true);
  assert.equal(isSoundCloudURL("https://on.soundcloud.com/abc123"), true);
  assert.equal(isSoundCloudURL("http://soundcloud.com/forss/flickermood"), false);
  assert.equal(isSoundCloudURL("https://soundcloud.example/forss/flickermood"), false);
  assert.throws(() => soundCloudSourceURL("https://user:secret@soundcloud.com/forss/flickermood"), /SoundCloud track or playlist URL/);
});

test("parses bounded SoundCloud hydration and direct track metadata", () => {
  const record = trackRecord(293, "Flickermood", "Forss");
  const hydration = parseSoundCloudHydration(hydrationHTML([{ hydratable: "sound", data: record }]));
  const track = parseSoundCloudTrack(hydration.get("sound"));
  assert.equal(hydration.get("apiClient").id, clientID);
  assert.deepEqual({
    id: track.trackID,
    provider: track.provider,
    title: track.title,
    artist: track.artist,
    duration: track.durationSeconds,
    direct: track.directlyImportable,
  }, {
    id: "293",
    provider: "soundcloud",
    title: "Flickermood",
    artist: "Forss",
    duration: 214,
    direct: true,
  });
  assert.throws(() => parseSoundCloudHydration("<html></html>"), /invalid page metadata/);
  assert.equal(parseSoundCloudTrack({ ...record, track_authorization: null }).directlyImportable, false);
});

test("hydrates stubbed SoundCloud playlist tracks in original order", async () => {
  const first = trackRecord(293, "Flickermood", "Forss");
  const second = trackRecord(294, "Second Song", "Second Artist", { duration: 125_000 });
  const playlist = {
    id: 9001,
    kind: "playlist",
    title: "Road Trip",
    track_count: 2,
    permalink_url: "https://soundcloud.com/forss/sets/road-trip",
    artwork_url: "https://i1.sndcdn.com/playlist-large.jpg",
    user: { username: "Forss" },
    tracks: [first, { id: second.id, kind: "track" }],
  };
  const requested = [];
  const resolved = await resolveSoundCloudSource(
    playlist.permalink_url,
    new AbortController().signal,
    async (input) => {
      const url = new URL(input);
      requested.push(url.hostname);
      if (url.hostname === "api-v2.soundcloud.com") {
        assert.equal(url.searchParams.get("ids"), "294");
        assert.equal(url.searchParams.get("client_id"), clientID);
        return new Response(JSON.stringify([second]), { status: 200, headers: { "content-type": "application/json" } });
      }
      return new Response(hydrationHTML([{ hydratable: "playlist", data: playlist }]), {
        status: 200,
        headers: { "content-type": "text/html" },
      });
    },
  );
  assert.deepEqual(requested, ["soundcloud.com", "api-v2.soundcloud.com"]);
  assert.equal(resolved.kind, "playlist");
  assert.deepEqual(resolved.playlist.items.map((item) => item.trackID), ["293", "294"]);
  assert.deepEqual(resolved.playlist.items.map((item) => item.trackNumber), [1, 2]);
  assert.equal(resolved.playlist.items[1].durationSeconds, 125);
  assert.equal(resolved.playlist.unavailableCount, 0);
});

test("returns direct SoundCloud candidates for tracks and ordered playlists", async () => {
  const first = { ...parseSoundCloudTrack(trackRecord(293, "Flickermood", "Forss")), trackNumber: 1 };
  const second = { ...parseSoundCloudTrack(trackRecord(294, "Second Song", "Second Artist", { direct: false })), trackNumber: 2 };
  const fallback = {
    videoID: "jNQXAC9IVRw",
    title: "Second Song",
    artist: "Second Artist",
    sourceProvider: "youtube",
    sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
  };
  const searchedTrackIDs = [];
  const adapters = {
    resolveSoundCloudSource: async (source) => source.includes("sets")
      ? { kind: "playlist", playlist: { playlistID: "9001", title: "Road Trip", author: "Forss", artworkURL: null, sourceURL: source, items: [first, second], unavailableCount: 0 } }
      : { kind: "track", track: first },
    searchYouTubeAudioSources: async (track) => {
      searchedTrackIDs.push(track.trackID);
      return track.trackID === "294" ? [fallback] : [];
    },
  };
  const single = await resolveLocalImportSource(
    first.sourceURL,
    new AbortController().signal,
    () => {},
    adapters,
    { mediaKind: "audio" },
  );
  assert.equal(single.kind, "soundcloud");
  assert.equal(single.candidates[0].sourceProvider, "soundcloud");
  assert.equal(single.candidates[0].sourceURL, first.sourceURL);

  const batch = await resolveLocalImportSource(
    "https://soundcloud.com/forss/sets/road-trip",
    new AbortController().signal,
    () => {},
    adapters,
    { mediaKind: "audio" },
  );
  assert.equal(batch.kind, "soundcloud_playlist");
  assert.deepEqual(batch.candidates.map((candidate) => candidate.playlistIndex), [1, 2]);
  assert.deepEqual(batch.candidates.map((candidate) => candidate.sourceProvider), ["soundcloud", "youtube"]);
  assert.deepEqual(searchedTrackIDs, ["294"]);
});

test("resolves and verifies a bounded progressive SoundCloud audio download", async (context) => {
  const record = trackRecord(293, "Flickermood", "Forss");
  const page = hydrationHTML([{ hydratable: "sound", data: record }]);
  const audio = Buffer.from("verified SoundCloud mp3 bytes");
  const mediaURL = "https://cf-media.sndcdn.com/flickermood.mp3?Policy=test";
  const requests = [];
  const fetchImpl = async (input, options = {}) => {
    const url = new URL(input);
    requests.push(`${options.method || "GET"} ${url.hostname}`);
    if (url.hostname === "soundcloud.com") return new Response(page, { status: 200 });
    if (url.hostname === "api-v2.soundcloud.com") {
      assert.equal(url.searchParams.get("client_id"), clientID);
      assert.equal(url.searchParams.get("track_authorization"), "authorization-293");
      return new Response(JSON.stringify({ url: mediaURL }), { status: 200 });
    }
    if (options.headers?.Range === "bytes=0-0") {
      return new Response(audio.subarray(0, 1), {
        status: 206,
        headers: {
          "content-range": `bytes 0-0/${audio.length}`,
          "content-type": "audio/mpeg",
          "content-length": "1",
        },
      });
    }
    return new Response(audio, { status: 200, headers: { "content-type": "audio/mpeg", "content-length": String(audio.length) } });
  };
  const resolved = await resolveSoundCloudAudio(record.permalink_url, new AbortController().signal, fetchImpl);
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-soundcloud-test-"));
  context.after(() => fs.rm(directory, { recursive: true, force: true }));
  const destination = path.join(directory, "source.mp3");
  const download = await downloadResolvedSoundCloudAudio(
    resolved,
    destination,
    new AbortController().signal,
    () => {},
    fetchImpl,
  );
  assert.deepEqual(requests, [
    "GET soundcloud.com",
    "GET api-v2.soundcloud.com",
    "GET cf-media.sndcdn.com",
    "GET cf-media.sndcdn.com",
  ]);
  assert.equal(download.sha256, createHash("sha256").update(audio).digest("hex"));
  assert.deepEqual(await fs.readFile(destination), audio);
});

test("imports a confirmed SoundCloud source through the MP3 processing path", async (context) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-soundcloud-platform-test-"));
  context.after(() => fs.rm(directory, { recursive: true, force: true }));
  const sourceBytes = Buffer.from("source mp3 bytes");
  const taggedBytes = Buffer.from("tagged m4a bytes");
  let downloadedPath = null;
  const result = await importConfirmedSource({
    sourceURL: "https://soundcloud.com/forss/flickermood",
    mediaKind: "audio",
    metadata: { title: "Flickermood", artist: "Forss", sourceURL: "https://soundcloud.com/forss/flickermood" },
    existing: [],
    destinationDirectory: path.join(directory, "library"),
    temporaryRoot: directory,
  }, new AbortController().signal, () => {}, {
    downloadSoundCloudAudio: async (_source, destination) => {
      downloadedPath = destination;
      await fs.writeFile(destination, sourceBytes, { flag: "wx" });
      return {
        preview: { title: "Flickermood", author: "Forss", thumbnailURL: null, sourceURL: "https://soundcloud.com/forss/flickermood" },
        download: { sha256: createHash("sha256").update(sourceBytes).digest("hex") },
      };
    },
    fetchArtwork: async () => null,
    tagM4A: async (input, output) => {
      assert.equal(path.extname(input), ".mp3");
      await fs.writeFile(output, taggedBytes, { flag: "wx" });
    },
  });
  assert.equal(path.extname(downloadedPath), ".mp3");
  assert.equal(result.kind, "created");
  assert.equal(result.metadata.title, "Flickermood");
  assert.deepEqual(await fs.readFile(result.filePath), taggedBytes);
});

test("converts SoundCloud MP3 audio to AAC while preserving M4A stream-copy imports", () => {
  const metadata = { title: "Song", artist: "Artist", sourceURL: "https://soundcloud.com/artist/song" };
  const mp3 = m4aTagArguments("source.mp3", "tagged.m4a", metadata, null);
  const m4a = m4aTagArguments("source.m4a", "tagged.m4a", metadata, null);
  assert.deepEqual(mp3.slice(mp3.indexOf("-c:a"), mp3.indexOf("-c:a") + 4), ["-c:a", "aac", "-b:a", "192k"]);
  assert.deepEqual(m4a.slice(m4a.indexOf("-c:a"), m4a.indexOf("-c:a") + 2), ["-c:a", "copy"]);
});
