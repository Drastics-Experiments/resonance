import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const {
  createServerDownloadPresentationCoordinator,
  serverDownloadPreparationTitle,
  serverDownloadProgressEvent,
} = require("../server-download.cjs");

const root = path.resolve(import.meta.dirname, "..");

test("the stable song owner is published before its first byte", () => {
  const events = [];
  const coordinator = createServerDownloadPresentationCoordinator(2, (event) => events.push(event));
  const starting = serverDownloadProgressEvent({
    song: { title: "Starting song" },
    itemIndex: 1,
    itemCount: 2,
    completedBytes: 0,
    totalBytes: 0,
    title: "Starting download",
  });

  assert.equal(coordinator.update(0, starting), true);
  assert.equal(events.length, 1);
  assert.equal(events[0].currentFile, "Starting song");
  assert.equal(events[0].itemCompleted, 0);
  assert.equal(events[0].itemTotal, 0);
});

test("the renderer no longer hides zero-byte download preparation", () => {
  const source = readFileSync(path.join(root, "ui", "app.js"), "utf8");
  assert.doesNotMatch(source, /direction === "download" && downloadBytes <= 0/);
  assert.match(source, /serverTransferProgressPresentation/);
});


test("a byte-active mixed-provider item replaces an earlier resolver", () => {
  const events = [];
  const coordinator = createServerDownloadPresentationCoordinator(3, (event) => events.push(event));
  coordinator.update(0, serverDownloadProgressEvent({
    song: { title: "Slow YouTube song" },
    itemIndex: 1,
    itemCount: 3,
    completedBytes: 0,
    totalBytes: 0,
    title: "Resolving YouTube",
  }));
  coordinator.update(1, serverDownloadProgressEvent({
    song: { title: "Direct server song" },
    itemIndex: 2,
    itemCount: 3,
    completedBytes: 256,
    totalBytes: 1_024,
    title: "Downloading",
  }));

  assert.equal(coordinator.currentIndex(), 1);
  assert.equal(events.at(-1).currentFile, "Direct server song");
  assert.equal(events.at(-1).itemCompleted, 256);
});

test("provider startup titles cover YouTube, SoundCloud, Spotify, and debrid", () => {
  assert.equal(
    serverDownloadPreparationTitle("https://www.youtube.com/watch?v=abcdefghijk", "inspecting_source"),
    "Inspecting YouTube",
  );
  assert.equal(
    serverDownloadPreparationTitle("https://soundcloud.com/artist/song", "resolving_metadata"),
    "Resolving SoundCloud",
  );
  assert.equal(
    serverDownloadPreparationTitle("https://open.spotify.com/track/0123456789012345678901", "searching_candidates"),
    "Finding a YouTube match",
  );
  assert.equal(serverDownloadPreparationTitle(null, "waiting_external"), "Waiting for debrid");
});
