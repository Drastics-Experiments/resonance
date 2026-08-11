import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import downloadFile from "../download-file.cjs";

const { adoptDownloadedFile, writeResponseToFile } = downloadFile;

test("reports byte progress for the current downloaded file", async () => {
  const bytes = Buffer.from("current song bytes");
  const destination = path.join(tmpdir(), `resonance-download-progress-${randomUUID()}.part`);
  const progress = [];
  try {
    const result = await writeResponseToFile(new Response(bytes, {
      headers: { "content-length": String(bytes.length) },
    }), destination, {
      expectedSize: bytes.length,
      expectedSHA256: createHash("sha256").update(bytes).digest("hex"),
      onProgress: (value) => progress.push(value),
    });
    assert.equal(result.size, bytes.length);
    assert.deepEqual(progress[0], { completed: 0, total: bytes.length });
    assert.deepEqual(progress.at(-1), { completed: bytes.length, total: bytes.length });
  } finally {
    await rm(destination, { force: true });
  }
});

test("does not publish or adopt a chunk delivered after cancellation", async () => {
  const bytes = Buffer.from("late bytes");
  const destination = path.join(tmpdir(), `resonance-download-late-cancel-${randomUUID()}.part`);
  const controller = new AbortController();
  const progress = [];
  const reader = {
    async read() {
      controller.abort(new DOMException("Replaced by a newer download", "AbortError"));
      return { done: false, value: bytes };
    },
    async cancel() {},
    releaseLock() {},
  };
  const response = {
    headers: new Headers({ "content-length": String(bytes.length) }),
    body: { getReader: () => reader },
  };

  try {
    await assert.rejects(writeResponseToFile(response, destination, {
      signal: controller.signal,
      expectedSize: bytes.length,
      expectedSHA256: createHash("sha256").update(bytes).digest("hex"),
      onProgress: (value) => progress.push(value),
    }), { name: "AbortError" });
    assert.deepEqual(progress, [{ completed: 0, total: bytes.length }]);
  } finally {
    await rm(destination, { force: true });
  }
});

test("refuses adoption before rename when the captured authorization expired", async () => {
  let renamed = false;
  await assert.rejects(adoptDownloadedFile("song.part", "song.mp3", {
    assertAuthorized() { throw new Error("lease expired"); },
    async rename() { renamed = true; },
  }), /lease expired/);
  assert.equal(renamed, false);
});

test("treats the final pre-rename assertion as the atomic adoption boundary", async () => {
  let authorized = true;
  const calls = [];
  await adoptDownloadedFile("song.part", "song.mp3", {
    assertAuthorized() {
      assert.equal(authorized, true);
      calls.push("authorized");
    },
    async rename(source, destination) {
      calls.push(["rename", source, destination]);
      authorized = false;
    },
  });
  assert.deepEqual(calls, ["authorized", ["rename", "song.part", "song.mp3"]]);
});

test("a failed atomic replacement does not delete or move the old destination", async () => {
  const calls = [];
  await assert.rejects(adoptDownloadedFile("song.part", "song.mp3", {
    assertAuthorized() { calls.push("authorized"); },
    async rename(source, destination) {
      calls.push(["rename", source, destination]);
      throw Object.assign(new Error("replacement failed"), { code: "EPERM" });
    },
  }), /replacement failed/);
  assert.deepEqual(calls, ["authorized", ["rename", "song.part", "song.mp3"]]);
});
