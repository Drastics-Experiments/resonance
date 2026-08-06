import assert from "node:assert/strict";
import test from "node:test";

import {
  compareVersions,
  expectedAssetNames,
  nextPatchVersion,
  parseArguments,
  porcelainChangedPaths,
  selectLatestRun,
} from "./release-now.mjs";

test("defaults require no arguments", () => {
  assert.deepEqual(parseArguments([]), {
    build: undefined,
    dryRun: false,
    help: false,
    retryFailed: false,
    version: undefined,
  });
});

test("explicit release arguments are parsed", () => {
  assert.deepEqual(
    parseArguments(["--version", "2.4.0", "--build", "91", "--retry-failed", "--dry-run"]),
    {
      build: 91,
      dryRun: true,
      help: false,
      retryFailed: true,
      version: "2.4.0",
    },
  );
});

test("invalid arguments fail before mutation", () => {
  assert.throws(() => parseArguments(["--version", "2.4"]), /semantic version/);
  assert.throws(() => parseArguments(["--build", "0"]), /positive integer/);
  assert.throws(() => parseArguments(["--unknown"]), /unknown argument/);
});

test("next patch and semantic comparisons are deterministic", () => {
  assert.equal(nextPatchVersion("1.1.3"), "1.1.4");
  assert.equal(nextPatchVersion("2.9.99"), "2.9.100");
  assert.equal(compareVersions("1.2.0", "1.1.99"), 1);
  assert.equal(compareVersions("1.1.3", "1.1.3"), 0);
  assert.equal(compareVersions("1.0.9", "1.1.0"), -1);
});

test("public release contract contains exactly twelve assets", () => {
  const assets = expectedAssetNames("1.2.3");
  assert.equal(assets.length, 12);
  assert.ok(assets.includes("Resonance-Android-1.2.3.apk"));
  assert.ok(assets.includes("Resonance-Setup-1.2.3.exe"));
  assert.ok(assets.includes("Resonance-iOS-Simulator-1.2.3.zip"));
  assert.ok(assets.includes("latest-android.json"));
});

test("workflow discovery selects the newest exact-SHA run", () => {
  const selected = selectLatestRun(
    [
      { databaseId: 5, headSha: "other" },
      { databaseId: 7, headSha: "wanted" },
      { databaseId: 9, headSha: "wanted" },
    ],
    "wanted",
  );
  assert.equal(selected.databaseId, 9);
  assert.equal(selectLatestRun([], "wanted"), undefined);
});

test("porcelain paths survive trimming of the first status line", () => {
  assert.deepEqual(
    porcelainChangedPaths("M android/app/build.gradle.kts\n M ios/LikedSongsMobile/Info.plist"),
    ["android/app/build.gradle.kts", "ios/LikedSongsMobile/Info.plist"],
  );
});
