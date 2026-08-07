import assert from "node:assert/strict";
import test from "node:test";
import downloadFile from "../download-file.cjs";

const { adoptDownloadedFile } = downloadFile;

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
