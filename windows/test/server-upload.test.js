import assert from "node:assert/strict";
import test from "node:test";

import uploadNaming from "../server-upload.cjs";

const { serverUploadFilename } = uploadNaming;

test("server uploads use a track title instead of a managed cache hash", () => {
  assert.equal(
    serverUploadFilename("/ServerCache/980026786a7d6c4928bb9b3fdd9e42b9b53eb7432473cac2b.m4a", "No Dogs Allowed"),
    "No Dogs Allowed.m4a",
  );
});

test("server upload filenames preserve direct file names and sanitize track titles", () => {
  assert.equal(serverUploadFilename("/Music/Real Song.mp3"), "Real Song.mp3");
  assert.equal(serverUploadFilename("/Music/cache.mp3", "Real/Song?.mp3"), "Real-Song-.mp3");
});
