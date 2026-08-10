import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), "utf8");

test("direct release workflow is dispatch-only and calls all four platform builders", () => {
  const workflow = read(".github/workflows/direct-release-build.yml");
  assert.match(workflow, /workflow_dispatch:/);
  assert.doesNotMatch(workflow, /^\s*pull_request:/m);
  assert.doesNotMatch(workflow, /gh pr|refs\/heads\/release\/|release\/v[0-9]/);
  assert.doesNotMatch(workflow, /gh release|contents:\s*write/);
  for (const platform of ["android", "ios", "macos", "windows"]) {
    assert.match(workflow, new RegExp(`uses: \\.\\/\\.github\\/workflows\\/${platform}\\.yml`));
  }
  assert.equal((workflow.match(/^\s+version_override: true$/gm) || []).length, 4);
  assert.match(workflow, /No version file is committed|mode: "direct"/);
});

for (const platform of ["android", "ios", "macos", "windows"]) {
  test(`${platform} supports an in-run direct version override`, () => {
    const workflow = read(`.github/workflows/${platform}.yml`);
    assert.match(workflow, /^\s+version_override:$/m);
    assert.match(workflow, /inputs\.release_candidate && inputs\.version_override/);
    assert.match(workflow, /node scripts\/release-version\.mjs --set/);
  });
}

test("direct version override synchronizes every platform only in an isolated workspace", () => {
  const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "resonance-direct-version-test-"));
  const files = [
    "scripts/release-version.mjs",
    "release/version.json",
    "windows/package.json",
    "android/app/build.gradle.kts",
    "ios/Resonance.xcodeproj/project.pbxproj",
    "ios/Resonance/Info.plist",
    "mac/scripts/build-release.sh",
  ];
  try {
    for (const relativePath of files) {
      const destination = path.join(workspace, relativePath);
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.copyFileSync(path.join(root, relativePath), destination);
    }
    const setResult = spawnSync(
      process.execPath,
      ["scripts/release-version.mjs", "--set", "9.8.7", "999"],
      { cwd: workspace, encoding: "utf8" },
    );
    assert.equal(setResult.status, 0, setResult.stderr || setResult.stdout);
    const checkResult = spawnSync(process.execPath, ["scripts/release-version.mjs", "--check"], {
      cwd: workspace,
      encoding: "utf8",
    });
    assert.equal(checkResult.status, 0, checkResult.stderr || checkResult.stdout);
    assert.match(checkResult.stdout, /9\.8\.7 \(999\)/);
  } finally {
    fs.rmSync(workspace, { recursive: true, force: true });
  }
});
