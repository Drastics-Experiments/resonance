import assert from "node:assert/strict";
import test from "node:test";

import uploadNaming from "../server-upload.cjs";

const { policyBlockedUploadEntries, serverUploadFilename } = uploadNaming;

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

test("mid-batch policy revocation preserves prior commits and blocks every remaining retry", () => {
  const requested = [
    { retryID: "committed", trackID: "track-a", filePath: "C:\\Music\\A.mp3", uploadFilename: "A.mp3" },
    { retryID: "current", trackID: "track-b", filePath: "C:\\Music\\B.mp3", uploadFilename: "B.mp3" },
    { retryID: "pending", trackID: "track-c", filePath: "C:\\Music\\C.mp3", uploadFilename: "C.mp3" },
  ];
  const entries = policyBlockedUploadEntries(
    requested,
    new Set(["committed"]),
    new Map([["current", 1]]),
    "Local file uploads were revoked.",
  );
  assert.deepEqual(entries.map(({ item, failure }) => ({
    retryID: item.retryID,
    attempts: failure.attempts,
    status: failure.status,
  })), [
    { retryID: "current", attempts: 1, status: "policy_blocked" },
    { retryID: "pending", attempts: 0, status: "policy_blocked" },
  ]);
  assert.equal(entries.some(({ item }) => item.retryID === "committed"), false);
  assert.equal(entries.every(({ failure }) => failure.message === "Local file uploads were revoked."), true);
});
