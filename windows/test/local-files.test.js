import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  AUDIO_EXTENSIONS,
  VIDEO_EXTENSIONS,
  createScopedMediaPathTrust,
  expandSelectedMediaFiles,
  isSupportedMediaFile,
} from "../local-files.cjs";

async function temporaryDirectory() {
  return fs.mkdtemp(path.join(os.tmpdir(), "resonance-local-files-test-"));
}

test("local file policy recognizes the audio and video formats offered by the native picker", () => {
  assert.ok(AUDIO_EXTENSIONS.has(".caf"));
  assert.ok(AUDIO_EXTENSIONS.has(".mp3"));
  assert.ok(VIDEO_EXTENSIONS.has(".mov"));
  assert.ok(isSupportedMediaFile("/Music/Track.M4A"));
  assert.ok(isSupportedMediaFile("/Movies/Live.MP4"));
  assert.equal(isSupportedMediaFile("/Music/cover.jpg"), false);
  assert.equal(isSupportedMediaFile("/Music/track.mp3\0unsafe"), false);
});

test("selected folders expand recursively, skip hidden/package descendants, deduplicate, and sort", async () => {
  const root = await temporaryDirectory();
  try {
    await fs.mkdir(path.join(root, "nested", "deeper"), { recursive: true });
    await fs.mkdir(path.join(root, ".hidden"), { recursive: true });
    await fs.mkdir(path.join(root, "Library.pkg"), { recursive: true });
    await fs.writeFile(path.join(root, "zeta.mp3"), "z");
    await fs.writeFile(path.join(root, "nested", "alpha.MP4"), "a");
    await fs.writeFile(path.join(root, "nested", "deeper", "middle.flac"), "m");
    await fs.writeFile(path.join(root, ".hidden", "secret.mp3"), "h");
    await fs.writeFile(path.join(root, "Library.pkg", "package.mp3"), "p");
    await fs.writeFile(path.join(root, "nested", "notes.txt"), "n");
    // A symlink cycle must not hang a folder import. Platforms that do not
    // permit symlinks still exercise the rest of the recursive contract.
    await fs.symlink(root, path.join(root, "nested", "deeper", "loop"), "dir").catch(() => undefined);

    const expanded = await expandSelectedMediaFiles([root, path.join(root, "zeta.mp3")]);
    assert.deepEqual(expanded, [
      path.join(root, "nested", "alpha.MP4"),
      path.join(root, "nested", "deeper", "middle.flac"),
      path.join(root, "zeta.mp3"),
    ]);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("external media trust is exact-path scoped and bounded", () => {
  const trust = createScopedMediaPathTrust({ maxEntries: 2 });
  const first = path.resolve("/Users/example/Music/one.mp3");
  const second = path.resolve("/Users/example/Music/two.mp4");
  const third = path.resolve("/Users/example/Music/three.wav");
  trust.add([first, second]);
  assert.equal(trust.has(first), true);
  assert.equal(trust.has(path.dirname(first)), false);
  assert.equal(trust.has(`${first}.backup`), false);
  trust.add(third);
  assert.equal(trust.has(first), false);
  assert.equal(trust.has(second), true);
  assert.equal(trust.has(third), true);
  assert.equal(trust.size, 2);
});

test("Electron local-file IPC exposes folder/video import plus safe reveal/delete controls", async () => {
  const [main, preload] = await Promise.all([
    fs.readFile(new URL("../main.cjs", import.meta.url), "utf8"),
    fs.readFile(new URL("../preload.cjs", import.meta.url), "utf8"),
  ]);
  assert.match(main, /properties:\s*\["openFile",\s*"openDirectory",\s*"multiSelections"\]/);
  assert.match(main, /expandSelectedMediaFiles\(result\.filePaths\)/);
  assert.match(main, /storageLocation:\s*"external"/);
  assert.match(main, /request\.deleteOriginal !== true/);
  assert.match(main, /ipcMain\.handle\("library:reveal"/);
  assert.match(preload, /revealAudio:\s*\(filePath\)\s*=>\s*ipcRenderer\.invoke\("library:reveal"/);
});
