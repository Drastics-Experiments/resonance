import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";

import {
  compareVersions,
  expectedAssetNames,
  nextPatchVersion,
  parseArguments,
  porcelainChangedPaths,
  requiredReleaseSecretNames,
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
    parseArguments([
      "--version",
      "2.4.0",
      "--build",
      "91",
      "--retry-failed",
      "--dry-run",
    ]),
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

test("legacy PR release command fails closed before any mutation", () => {
  const result = spawnSync(process.execPath, ["scripts/release-now.mjs"], {
    cwd: new URL("..", import.meta.url),
    encoding: "utf8",
  });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /legacy PR release path is disabled/);
});

test("next patch and semantic comparisons are deterministic", () => {
  assert.equal(nextPatchVersion("1.1.3"), "1.1.4");
  assert.equal(nextPatchVersion("2.9.99"), "2.9.100");
  assert.equal(compareVersions("1.2.0", "1.1.99"), 1);
  assert.equal(compareVersions("1.1.3", "1.1.3"), 0);
  assert.equal(compareVersions("1.0.9", "1.1.0"), -1);
});

test("public release contract contains exactly eighteen assets", () => {
  const assets = expectedAssetNames("1.2.3");
  assert.equal(assets.length, 18);
  assert.ok(assets.includes("Resonance-Android-1.2.3.apk"));
  assert.ok(assets.includes("Resonance-Setup-1.2.3.exe"));
  assert.ok(assets.includes("Resonance-iOS-Simulator-1.2.3.zip"));
  assert.ok(assets.includes("Resonance-iOS-Device-1.2.3.ipa"));
  assert.ok(assets.includes("Resonance-iPhone-Installer-Windows-1.2.3.exe"));
  assert.ok(assets.includes("Resonance-iPhone-Installer-macOS-1.2.3.zip"));
  assert.ok(assets.includes("latest-android.json"));
});

test("every publishable release requires all platform signing credentials", () => {
  const requiredSecrets = requiredReleaseSecretNames();
  assert.deepEqual(requiredSecrets.sort(), [
    "RESONANCE_ANDROID_KEYSTORE_BASE64",
    "RESONANCE_ANDROID_KEYSTORE_PASSWORD",
    "RESONANCE_ANDROID_KEY_ALIAS",
    "RESONANCE_ANDROID_KEY_PASSWORD",
    "RESONANCE_MACOS_APP_CERTIFICATE_BASE64",
    "RESONANCE_MACOS_APP_CERTIFICATE_PASSWORD",
    "RESONANCE_MACOS_APP_IDENTITY",
    "RESONANCE_MACOS_INSTALLER_CERTIFICATE_BASE64",
    "RESONANCE_MACOS_INSTALLER_CERTIFICATE_PASSWORD",
    "RESONANCE_MACOS_INSTALLER_IDENTITY",
    "RESONANCE_MACOS_NOTARY_ISSUER_ID",
    "RESONANCE_MACOS_NOTARY_KEY_BASE64",
    "RESONANCE_MACOS_NOTARY_KEY_ID",
    "RESONANCE_WINDOWS_CERTIFICATE_BASE64",
    "RESONANCE_WINDOWS_CERTIFICATE_PASSWORD",
    "RESONANCE_WINDOWS_CERTIFICATE_SHA1",
  ]);
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
    porcelainChangedPaths("M android/app/build.gradle.kts\n M ios/Resonance/Info.plist"),
    ["android/app/build.gradle.kts", "ios/Resonance/Info.plist"],
  );
});
