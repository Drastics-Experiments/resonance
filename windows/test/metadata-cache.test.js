import assert from "node:assert/strict";
import test from "node:test";
import metadataModule from "../metadata.cjs";

const { createMetadataReader, pictureDataURL } = metadataModule;

function statFor(overrides = {}) {
  return {
    dev: 1,
    ino: 2,
    size: 100,
    mtimeMs: 10,
    ctimeMs: 10,
    ...overrides,
  };
}

function parsed(title, artworkBytes = 0) {
  return {
    common: {
      title,
      artist: "Artist",
      picture: artworkBytes ? [{ format: "image/png", data: Buffer.alloc(artworkBytes, 1) }] : undefined,
    },
    format: { duration: 12.5 },
  };
}

test("metadata reader deduplicates concurrent parses and returns independent records", async () => {
  let parseCalls = 0;
  let resolveParse;
  const parseStarted = new Promise((resolve) => {
    resolveParse = resolve;
  });
  const reader = createMetadataReader({
    stat: async () => statFor(),
    parseFile: async () => {
      parseCalls += 1;
      resolveParse();
      await new Promise((resolve) => setTimeout(resolve, 5));
      return parsed("Shared");
    },
  });

  const first = reader.readAudioMetadata("track.mp3");
  await parseStarted;
  const second = reader.readAudioMetadata("track.mp3");
  const [one, two] = await Promise.all([first, second]);

  assert.equal(parseCalls, 1);
  assert.deepEqual(one, two);
  assert.notStrictEqual(one, two);
  one.title = "mutated";
  assert.equal((await reader.readAudioMetadata("track.mp3")).title, "Shared");
  assert.equal(parseCalls, 1);
});

test("each parser call receives a mutable, independent options object", async () => {
  const optionsSeen = [];
  let parseCalls = 0;
  const reader = createMetadataReader({
    stat: async () => statFor(),
    parseFile: async (_filePath, options) => {
      optionsSeen.push(options);
      options.apeHeader = parseCalls;
      parseCalls += 1;
      return parsed("Mutable options");
    },
  });

  await Promise.all([
    reader.readAudioMetadata("one.mp3"),
    reader.readAudioMetadata("two.mp3"),
  ]);
  assert.equal(parseCalls, 2);
  assert.notStrictEqual(optionsSeen[0], optionsSeen[1]);
  assert.deepEqual(optionsSeen.map(({ duration, skipCovers }) => ({ duration, skipCovers })), [
    { duration: true, skipCovers: false },
    { duration: true, skipCovers: false },
  ]);
});

test("metadata cache invalidates a same-size file when its signature changes", async () => {
  let currentStat = statFor();
  let parseCalls = 0;
  const reader = createMetadataReader({
    stat: async () => currentStat,
    parseFile: async () => {
      parseCalls += 1;
      return parsed(parseCalls === 1 ? "Before" : "After");
    },
  });

  assert.equal((await reader.readAudioMetadata("track.mp3")).title, "Before");
  assert.equal((await reader.readAudioMetadata("track.mp3")).title, "Before");
  currentStat = statFor({ mtimeMs: 11, ctimeMs: 11 });
  assert.equal((await reader.readAudioMetadata("track.mp3")).title, "After");
  assert.equal((await reader.readAudioMetadata("track.mp3")).title, "After");
  assert.equal(parseCalls, 2);
});

test("stale in-flight completion cannot repopulate the cache after a file changes", async () => {
  let currentStat = statFor();
  let parseCalls = 0;
  const pending = [];
  const reader = createMetadataReader({
    stat: async () => currentStat,
    parseFile: () => {
      parseCalls += 1;
      return new Promise((resolve) => pending.push(resolve));
    },
  });

  const oldRead = reader.readAudioMetadata("track.mp3");
  await new Promise((resolve) => setImmediate(resolve));
  currentStat = statFor({ mtimeMs: 11, ctimeMs: 11 });
  const newRead = reader.readAudioMetadata("track.mp3");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(parseCalls, 2);

  pending[1](parsed("New"));
  assert.equal((await newRead).title, "New");
  pending[0](parsed("Old"));
  assert.equal((await oldRead).title, "Old");
  assert.equal((await reader.readAudioMetadata("track.mp3")).title, "New");
  assert.equal(parseCalls, 2);
});

test("metadata cache evicts least recently used entries and respects artwork bytes", async () => {
  const stats = new Map([
    ["one.mp3", statFor({ ino: 1 })],
    ["two.mp3", statFor({ ino: 2 })],
    ["three.mp3", statFor({ ino: 3 })],
  ]);
  const titles = new Map([
    ["one.mp3", "One"],
    ["two.mp3", "Two"],
    ["three.mp3", "Three"],
  ]);
  let parseCalls = 0;
  const reader = createMetadataReader({
    maxEntries: 2,
    maxArtworkBytes: 50,
    stat: async (filePath) => stats.get(filePath),
    parseFile: async (filePath) => {
      parseCalls += 1;
      return parsed(titles.get(filePath), 0);
    },
  });

  await reader.readAudioMetadata("one.mp3");
  await reader.readAudioMetadata("two.mp3");
  await reader.readAudioMetadata("one.mp3");
  await reader.readAudioMetadata("three.mp3");
  await reader.readAudioMetadata("two.mp3");
  assert.equal(parseCalls, 4);

  let artworkCalls = 0;
  const artworkReader = createMetadataReader({
    maxEntries: 4,
    maxArtworkBytes: 80,
    stat: async (filePath) => stats.get(filePath),
    parseFile: async (filePath) => {
      artworkCalls += 1;
      return parsed(titles.get(filePath), 30);
    },
  });
  await artworkReader.readAudioMetadata("one.mp3");
  await artworkReader.readAudioMetadata("two.mp3");
  await artworkReader.readAudioMetadata("one.mp3");
  assert.equal(artworkCalls, 3);
});

test("stat and parser failures are never cached", async () => {
  let statCalls = 0;
  let parseCalls = 0;
  const statFailureReader = createMetadataReader({
    stat: async () => {
      statCalls += 1;
      throw new Error("unavailable");
    },
    parseFile: async () => {
      parseCalls += 1;
      return parsed("Uncached");
    },
  });
  await statFailureReader.readAudioMetadata("track.mp3");
  await statFailureReader.readAudioMetadata("track.mp3");
  assert.equal(statCalls, 2);
  assert.equal(parseCalls, 2);

  parseCalls = 0;
  const parseFailureReader = createMetadataReader({
    stat: async () => statFor(),
    parseFile: async () => {
      parseCalls += 1;
      throw new Error("invalid audio");
    },
  });
  assert.deepEqual(await parseFailureReader.readAudioMetadata("track.mp3"), {
    title: null,
    artist: null,
    album: null,
    duration: 0,
    artwork: null,
  });
  await parseFailureReader.readAudioMetadata("track.mp3");
  assert.equal(parseCalls, 2);
});

test("pictureDataURL preserves supported formats and falls back safely", () => {
  assert.equal(pictureDataURL({ format: "image/webp", data: Buffer.from("cover") }), "data:image/webp;base64,Y292ZXI=");
  assert.equal(pictureDataURL({ format: "text/plain", data: Buffer.from("cover") }), "data:image/jpeg;base64,Y292ZXI=");
  assert.equal(pictureDataURL(null), null);
});
