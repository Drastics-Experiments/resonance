import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import packageValidator from "../validate-packaged-app.cjs";

const { validatePackagedWindowsApp } = packageValidator;

async function fixture(t, { includeHistory = true, authenticityMode = "unsigned" } = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "resonance-packaged-app-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(path.join(directory, "package.json"), JSON.stringify({
    main: "main.cjs",
    resonanceUpdateAuthenticity: authenticityMode,
  }));
  await writeFile(
    path.join(directory, "main.cjs"),
    'require("./listening-history.cjs"); require("./nested/feature.cjs");\n',
  );
  await writeFile(path.join(directory, "preload.cjs"), "module.exports = {};\n");
  await mkdir(path.join(directory, "nested"));
  await writeFile(path.join(directory, "nested/feature.cjs"), 'require("./helper.cjs");\n');
  await writeFile(path.join(directory, "nested/helper.cjs"), "module.exports = {};\n");
  if (includeHistory) {
    await writeFile(path.join(directory, "listening-history.cjs"), "module.exports = {};\n");
  }
  return directory;
}

test("validates the packaged startup module closure and embedded update policy", async (t) => {
  const directory = await fixture(t);
  const result = validatePackagedWindowsApp(directory, "unsigned");
  assert.equal(result.authenticityMode, "unsigned");
  assert.deepEqual(result.modules, [
    "listening-history.cjs",
    "main.cjs",
    "nested/feature.cjs",
    "nested/helper.cjs",
    "preload.cjs",
  ]);
});

test("rejects a packaged app with a missing transitive startup module", async (t) => {
  const directory = await fixture(t, { includeHistory: false });
  assert.throws(
    () => validatePackagedWindowsApp(directory, "unsigned"),
    /missing listening-history\.cjs, required by main\.cjs/,
  );
});

test("rejects a packaged app whose embedded updater policy does not match the build", async (t) => {
  const directory = await fixture(t, { authenticityMode: "production" });
  assert.throws(
    () => validatePackagedWindowsApp(directory, "unsigned"),
    /authenticity mode is production, expected unsigned/,
  );
});
