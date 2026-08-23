import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  createMediaSessionController,
  mediaSessionArtwork,
  mediaSessionMetadataInit,
  MEDIA_SESSION_ACTIONS,
} from "../ui/media-session.js";

test("Media Session metadata carries safe title, artist, album, and artwork", () => {
  const track = {
    title: "  Morning Signal ",
    artist: "Resonance Artist",
    album: "First Light",
    artwork: "data:image/png;base64,ZmFrZQ==",
    artworkURL: "https://cdn.example.test/artwork.png",
    artwork_url: "javascript:alert(1)",
  };
  assert.deepEqual(mediaSessionMetadataInit(track), {
    title: "  Morning Signal ",
    artist: "Resonance Artist",
    album: "First Light",
    artwork: [
      { src: "data:image/png;base64,ZmFrZQ==", sizes: "512x512", type: "image/png" },
      { src: "https://cdn.example.test/artwork.png", sizes: "512x512" },
    ],
  });
  assert.deepEqual(mediaSessionArtwork({ artwork: "data:image/png;base64,ZmFrZQ==", artworkURL: "data:image/png;base64,ZmFrZQ==" }).length, 1);
});

test("Media Session controller registers transport actions and syncs playback state", () => {
  const registered = new Map();
  const positionStates = [];
  const fakeMediaSession = {
    playbackState: "none",
    metadata: null,
    setActionHandler(action, handler) {
      registered.set(action, handler);
    },
    setPositionState(value) {
      positionStates.push(value);
    },
  };
  const metadataValues = [];
  class FakeMediaMetadata {
    constructor(value) {
      metadataValues.push(value);
      Object.assign(this, value);
    }
  }
  const calls = [];
  const controller = createMediaSessionController({
    navigatorObject: { mediaSession: fakeMediaSession },
    MediaMetadataConstructor: FakeMediaMetadata,
    actionHandlers: Object.fromEntries(MEDIA_SESSION_ACTIONS.map((action) => [action, () => calls.push(action)])),
  });

  assert.ok(controller);
  assert.deepEqual([...registered.keys()], MEDIA_SESSION_ACTIONS);
  controller.sync({
    track: { title: "Morning Signal", artist: "Resonance Artist", album: "First Light" },
    isPlaying: true,
    position: 12.5,
    duration: 180,
    playbackRate: 1.25,
  });
  assert.equal(fakeMediaSession.playbackState, "playing");
  assert.equal(metadataValues[0].title, "Morning Signal");
  assert.deepEqual(positionStates, [{ duration: 180, position: 12.5, playbackRate: 1.25 }]);

  registered.get("play")();
  registered.get("nexttrack")();
  assert.deepEqual(calls, ["play", "nexttrack"]);

  controller.sync({ track: null, isPlaying: false });
  assert.equal(fakeMediaSession.metadata, null);
  assert.equal(fakeMediaSession.playbackState, "none");
});

test("Media Session controller tolerates unsupported browser APIs and invalid position state", () => {
  assert.equal(createMediaSessionController({ navigatorObject: {} }), null);

  const fakeMediaSession = {
    setActionHandler() {},
    setPositionState() {
      throw new DOMException("Invalid state", "InvalidStateError");
    },
  };
  const controller = createMediaSessionController({
    navigatorObject: { mediaSession: fakeMediaSession },
  });
  assert.doesNotThrow(() => controller.syncPlayback({ duration: 0, position: 0 }));
});

test("shared renderer wires Media Session actions to its existing transport", async () => {
  const appSource = await readFile(new URL("../ui/app.js", import.meta.url), "utf8");
  assert.match(appSource, /createMediaSessionController\(/);
  for (const action of ["play", "pause", "seekbackward", "seekforward", "seekto", "nexttrack", "previoustrack"]) {
    assert.match(appSource, new RegExp(`${action}:`));
  }
  assert.match(appSource, /controller\.sync\(/);
  assert.match(appSource, /controller\.syncPlayback\(/);
  assert.match(appSource, /mediaSessionSeekTo\(/);
});
