import assert from "node:assert/strict";
import test from "node:test";
import serverStream from "../server-stream.cjs";

const {
  ServerStreamValidationError,
  createExactLengthRelay,
  parseSingleByteRange,
  remoteStreamHistoryTrackID,
  serverStreamSongIsVideo,
  serverStreamURL,
  streamSessionIDFromURL,
  validateStreamResponse,
} = serverStream;

test("remote stream history identities are stable, bounded, and credential-free", () => {
  const identity = remoteStreamHistoryTrackID({
    serverOrigin: "https://music.example",
    profileID: "default",
    songID: "song-1",
  });
  assert.match(identity, /^remote-stream:[a-f0-9]{64}$/);
  assert.equal(identity, remoteStreamHistoryTrackID({
    serverOrigin: "https://music.example/path",
    profileID: "default",
    songID: "song-1",
  }));
  assert.notEqual(identity, remoteStreamHistoryTrackID({
    serverOrigin: "https://music.example",
    profileID: "other",
    songID: "song-1",
  }));
  assert.equal(identity.includes("song-1"), false);
});

test("remote video is rejected from the audio-only stream transport", () => {
  assert.equal(serverStreamSongIsVideo({ content_type: "video/mp4", filename: "asset.bin" }), true);
  assert.equal(serverStreamSongIsVideo({ filename: "clip.MOV" }), true);
  assert.equal(serverStreamSongIsVideo({ content_type: "audio/mp4", filename: "song.m4a" }), false);
  for (const contentType of ["video/mp4", "video/quicktime", "video/webm"]) {
    assert.throws(() => validateStreamResponse({
      status: 200,
      expectedSize: 1_000,
      headers: { "content-type": contentType, "content-length": "1000" },
    }), /media type/i);
  }
});

const SESSION_ID = "a".repeat(64);

test("parses one bounded canonical byte range", () => {
  assert.equal(parseSingleByteRange(null, 1000), null);
  assert.deepEqual(parseSingleByteRange("bytes=100-199", 1000), {
    start: 100,
    end: 199,
    length: 100,
    header: "bytes=100-199",
  });
  assert.deepEqual(parseSingleByteRange("bytes=900-", 1000), {
    start: 900,
    end: 999,
    length: 100,
    header: "bytes=900-999",
  });
  assert.deepEqual(parseSingleByteRange("bytes=-25", 1000), {
    start: 975,
    end: 999,
    length: 25,
    header: "bytes=975-999",
  });
  assert.deepEqual(parseSingleByteRange("bytes=0-9999", 1000), {
    start: 0,
    end: 999,
    length: 1000,
    header: "bytes=0-999",
  });
  for (const value of ["bytes=0-1,3-4", "bytes=1000-", "bytes=9-2", " bytes=0-1", "items=0-1"]) {
    assert.throws(() => parseSingleByteRange(value, 1000), (error) =>
      error instanceof ServerStreamValidationError && error.status === 416);
  }
});

test("validates full and partial media responses exactly", () => {
  assert.deepEqual(validateStreamResponse({
    status: 200,
    expectedSize: 1000,
    headers: { "content-type": "audio/mpeg", "content-length": "1000" },
  }), {
    status: 200,
    contentLength: 1000,
    headers: {
      "Accept-Ranges": "bytes",
      "Cache-Control": "no-store, private",
      "Content-Length": "1000",
      "Content-Type": "audio/mpeg",
      "X-Content-Type-Options": "nosniff",
    },
  });
  const requestedRange = parseSingleByteRange("bytes=100-199", 1000);
  assert.deepEqual(validateStreamResponse({
    status: 206,
    expectedSize: 1000,
    requestedRange,
    headers: {
      "content-type": "audio/mpeg",
      "content-length": "50",
      "content-range": "bytes 100-149/1000",
    },
  }), {
    status: 206,
    contentLength: 50,
    headers: {
      "Accept-Ranges": "bytes",
      "Cache-Control": "no-store, private",
      "Content-Length": "50",
      "Content-Type": "audio/mpeg",
      "Content-Range": "bytes 100-149/1000",
      "X-Content-Type-Options": "nosniff",
    },
  });
  assert.deepEqual(validateStreamResponse({
    status: 206,
    expectedSize: 1000,
    requestedRange,
    headers: {
      "content-type": "audio/mp4; charset=binary",
      "content-length": "100",
      "content-range": "bytes 100-199/1000",
    },
  }), {
    status: 206,
    contentLength: 100,
    headers: {
      "Accept-Ranges": "bytes",
      "Cache-Control": "no-store, private",
      "Content-Length": "100",
      "Content-Type": "audio/mp4",
      "Content-Range": "bytes 100-199/1000",
      "X-Content-Type-Options": "nosniff",
    },
  });
  assert.throws(() => validateStreamResponse({
    status: 302,
    expectedSize: 1000,
    headers: { "content-type": "audio/mpeg", "content-length": "1000" },
  }), /full stream response/i);
  assert.throws(() => validateStreamResponse({
    status: 206,
    expectedSize: 1000,
    requestedRange,
    headers: { "content-type": "text/html", "content-length": "100", "content-range": "bytes 100-199/1000" },
  }), /media type/i);
  assert.throws(() => validateStreamResponse({
    status: 206,
    expectedSize: 1000,
    requestedRange,
    headers: { "content-type": "audio/mpeg", "content-length": "100", "content-range": "bytes 101-200/1000" },
  }), /does not match/i);
});

test("fails closed for redirects, encoded bodies, playlists, methods, and malformed lengths", () => {
  const fullHeaders = { "content-type": "audio/mpeg", "content-length": "1000" };
  assert.throws(() => validateStreamResponse({
    status: 302,
    expectedSize: 1000,
    headers: fullHeaders,
  }), /full stream response/i);
  assert.throws(() => validateStreamResponse({
    status: 200,
    expectedSize: 1000,
    headers: { ...fullHeaders, "content-encoding": "gzip" },
  }), /encoded/i);
  for (const contentType of ["audio/x-mpegurl", "application/vnd.apple.mpegurl", "application/dash+xml", "text/html"]) {
    assert.throws(() => validateStreamResponse({
      status: 200,
      expectedSize: 1000,
      headers: { ...fullHeaders, "content-type": contentType },
    }), /media type/i);
  }
  assert.throws(() => validateStreamResponse({
    status: 200,
    expectedSize: 1000,
    headers: { "content-type": "audio/mpeg" },
  }), /Content-Length/i);
  assert.throws(() => validateStreamResponse({
    status: 200,
    expectedSize: 1000,
    headers: fullHeaders,
    method: "POST",
  }), (error) => error instanceof ServerStreamValidationError && error.status === 405);
  assert.equal(validateStreamResponse({
    status: 200,
    expectedSize: 1000,
    headers: fullHeaders,
    method: "HEAD",
  }).status, 200);
});

test("uses unguessable capability URLs with no credentials", () => {
  const url = serverStreamURL(SESSION_ID);
  assert.equal(url, `resonance-stream://media/${SESSION_ID}`);
  assert.equal(streamSessionIDFromURL(url), SESSION_ID);
  for (const unsafe of [
    `resonance-stream://other/${SESSION_ID}`,
    `resonance-stream://media/${SESSION_ID}?token=secret`,
    `resonance-stream://user:secret@media/${SESSION_ID}`,
    `https://media/${SESSION_ID}`,
    `resonance-stream://media/${SESSION_ID}${"x".repeat(10_000)}`,
  ]) assert.equal(streamSessionIDFromURL(unsafe), null);
  assert.equal(streamSessionIDFromURL({ toString: () => url }), null);
});

test("relays stream bytes without buffering or accepting length mismatches", async () => {
  let completed = 0;
  const exact = createExactLengthRelay(new Response(Buffer.from("abcdef")).body, 6, () => { completed += 1; });
  assert.equal(Buffer.from(await new Response(exact).arrayBuffer()).toString("utf8"), "abcdef");
  assert.equal(completed, 1);

  const short = createExactLengthRelay(new Response(Buffer.from("abc")).body, 4);
  await assert.rejects(new Response(short).arrayBuffer(), /ended before/i);

  const oversized = createExactLengthRelay(new Response(Buffer.from("abcde")).body, 4);
  await assert.rejects(new Response(oversized).arrayBuffer(), /exceeded/i);
});

test("cancelling a relay cancels upstream and completes cleanup exactly once", async () => {
  let cancelled = 0;
  let completed = 0;
  const body = new ReadableStream({
    pull(controller) { controller.enqueue(Buffer.from("ab")); },
    cancel() { cancelled += 1; },
  });
  const relay = createExactLengthRelay(body, 4, () => { completed += 1; });
  const reader = relay.getReader();
  assert.equal(Buffer.from((await reader.read()).value).toString("utf8"), "ab");
  await reader.cancel("no longer needed");
  assert.equal(cancelled, 1);
  assert.equal(completed, 1);
});
