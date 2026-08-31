import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), "utf8");

test("direct release workflow is dispatch-only and calls all platform builders", () => {
  const workflow = read(".github/workflows/direct-release-build.yml");
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /production_release:/);
  assert.match(workflow, /unsigned_desktop:/);
  assert.match(workflow, /replace_prerelease:/);
  assert.match(workflow, /environment: production-release/);
  assert.match(workflow, /github\.ref == 'refs\/heads\/main'/);
  assert.match(workflow, /\[\[ "\$\(git rev-parse origin\/main\)" == "\$SOURCE_SHA" \]\]/);
  assert.equal(
    (workflow.match(/production_signing: \$\{\{ needs\.prepare\.outputs\.unsigned_desktop != 'true' \}\}/g) || []).length,
    2,
  );
  assert.match(workflow, /android:[\s\S]+production_signing: true/);
  assert.match(workflow, /--allow-unsigned-desktop-release/);
  assert.match(
    workflow,
    /REPLACE_PRERELEASE[\s\S]+git show-ref --verify --quiet "refs\/tags\/\$\{TAG\}"[\s\S]+releases\/tags\/\$\{TAG\}[\s\S]+\.prerelease[\s\S]+== "true"/,
  );
  assert.match(workflow, /replacePrerelease: process\.env\.REPLACE_PRERELEASE === "true"/);
  assert.doesNotMatch(workflow, /^\s*pull_request:/m);
  assert.doesNotMatch(workflow, /gh pr|refs\/heads\/release\/|release\/v[0-9]/);
  assert.doesNotMatch(workflow, /gh release|contents:\s*write/);
  for (const platform of ["android", "ios", "macos", "windows", "iphone-installer"]) {
    assert.match(workflow, new RegExp(`uses: \\.\\/\\.github\\/workflows\\/${platform}\\.yml`));
  }
  assert.match(workflow, /iphone-installer:[\s\S]+release_candidate: true/);
  assert.match(workflow, /bundle:[\s\S]+- iphone-installer/);
  assert.equal((workflow.match(/^\s+version_override: true$/gm) || []).length, 4);
  assert.match(workflow, /No version file is committed|mode: "direct"/);
});

test("pull request release candidates are secretless and explicitly unsigned", () => {
  const workflow = read(".github/workflows/release-candidate.yml");
  assert.doesNotMatch(workflow, /^\s+secrets:/m);
  assert.doesNotMatch(workflow, /secrets\./);
  assert.match(workflow, /production_signing: false/);
  assert.match(workflow, /desktop_signing=unsigned/);
  assert.match(workflow, /--allow-unsigned-desktop-release/);
  assert.match(workflow, /iphone-installer:[\s\S]+uses: \.\/\.github\/workflows\/iphone-installer\.yml/);
});

test("iPhone installer release candidates publish versioned Windows and macOS companions", () => {
  const workflow = read(".github/workflows/iphone-installer.yml");
  const config = JSON.parse(read("installers/windows/iphone-installer/src-tauri/tauri.conf.json"));
  assert.match(workflow, /workflow_call:/);
  assert.match(workflow, /release_candidate:/);
  assert.match(workflow, /source_ref:/);
  assert.match(workflow, /Build NSIS installer/);
  assert.match(workflow, /Resonance-iPhone-Installer-Windows-\$\{\{ inputs\.version \}\}\.exe/);
  assert.match(workflow, /Resonance-iPhone-Installer-Windows-\$\{\{ inputs\.version \}\}\.exe\.sha256/);
  assert.match(workflow, /Build macOS app/);
  assert.doesNotMatch(workflow, /macos-installer:\n\s+name: Build macOS installer\n\s+if:/);
  assert.match(workflow, /args: --bundles app -- --locked/);
  assert.match(workflow, /Resonance-iPhone-Installer-macOS-\$\{\{ inputs\.version \}\}\.zip/);
  assert.match(workflow, /Resonance-iPhone-Installer-macOS-\$\{\{ inputs\.version \}\}\.zip\.sha256/);
  assert.match(workflow, /ditto -c -k --sequesterRsrc --keepParent/);
  assert.equal((workflow.match(/output_name="\$\(basename "\$output"\)"/g) || []).length, 2);
  assert.match(workflow, /cd "\$output_dir"[\s\S]+sha256sum "\$output_name" > "\$output_name\.sha256"/);
  assert.match(workflow, /cd "\$output_dir"[\s\S]+shasum -a 256 "\$output_name" > "\$output_name\.sha256"/);
  assert.ok(config.bundle.icon.includes("icons/resonance.icns"));
  assert.ok(fs.statSync(path.join(root, "installers/windows/iphone-installer/src-tauri/icons/resonance.icns")).size > 0);
});

test("Windows packages embed the update authenticity policy selected by the build", () => {
  const workflow = read(".github/workflows/windows.yml");
  const packageJSON = JSON.parse(read("windows/package.json"));
  assert.equal(packageJSON.resonanceUpdateAuthenticity, "production");
  assert.match(packageJSON.scripts["installer:win"], /extraMetadata\.resonanceUpdateAuthenticity=unsigned/);
  assert.match(workflow, /Verify unsigned installer state[\s\S]+Status -ne "NotSigned"/);
  assert.match(
    workflow,
    /Verify packaged startup modules and update policy[\s\S]+ELECTRON_RUN_AS_NODE[\s\S]+Start-Process[\s\S]+ExitCode/,
  );
  assert.match(
    workflow,
    /Build signed release candidate[\s\S]+extraMetadata\.resonanceUpdateAuthenticity=production/,
  );
});

test("macOS builds the shared Electron client and keeps the release asset contract", () => {
  const workflow = read(".github/workflows/macos.yml");
  assert.match(workflow, /windows\/pnpm-lock\.yaml/);
  assert.match(workflow, /pnpm install --frozen-lockfile/);
  assert.match(workflow, /working-directory: windows/);
  assert.match(workflow, /pnpm test/);
  assert.match(workflow, /mac\/scripts\/build-electron\.sh/);
  assert.match(workflow, /MAC_ARCH=universal/);
  assert.match(workflow, /com\.gavindietrich\.LikedSongsFocus/);
  assert.match(workflow, /Resonance-macOS\.zip/);
  assert.match(workflow, /Resonance-Installer\.pkg/);
  assert.match(workflow, /latest-mac\.json/);
  assert.doesNotMatch(workflow, /swift (?:build|package|test|--version)/i);
  assert.doesNotMatch(workflow, /mac\/scripts\/(?:build-release|test)\.sh/);
});

test("release version synchronization uses the shared Electron package for macOS", () => {
  const versionScript = read("scripts/release-version.mjs");
  const legacyReleaseScript = read("scripts/release-now.mjs");
  assert.match(versionScript, /windows\/package\.json/);
  assert.doesNotMatch(versionScript, /mac\/scripts\/build-release\.sh/);
  assert.doesNotMatch(legacyReleaseScript, /mac\/scripts\/build-release\.sh/);
});

test("publish workflow is trusted-dispatch-only and fails closed on unsigned policy", () => {
  const workflow = read(".github/workflows/publish-release.yml");
  assert.doesNotMatch(workflow, /^\s+pull_request:/m);
  assert.match(workflow, /environment: production-release/);
  assert.match(workflow, /candidate_run_id:/);
  assert.match(workflow, /request_id:/);
  assert.match(workflow, /direct-release-build\.yml/);
  assert.match(workflow, /\[\[ "\$MERGED_SHA" == "\$CANDIDATE_SHA" \]\]/);
  assert.match(workflow, /\[\[ "\$DESKTOP_SIGNING" == "production" \]\]/);
  assert.doesNotMatch(workflow, /allow-unsigned-desktop-release/);
});

test("all third-party actions are pinned and checkout does not persist credentials", () => {
  for (const file of [
    ".github/workflows/android.yml",
    ".github/workflows/direct-release-build.yml",
    ".github/workflows/ios.yml",
    ".github/workflows/iphone-installer.yml",
    ".github/workflows/macos.yml",
    ".github/workflows/publish-release.yml",
    ".github/workflows/release-candidate.yml",
    ".github/workflows/windows.yml",
  ]) {
    const workflow = read(file);
    for (const match of workflow.matchAll(/^\s+uses:\s+([^\s#]+)/gm)) {
      if (match[1].startsWith("./")) continue;
      assert.match(match[1], /@[0-9a-f]{40}$/i, `${file} has an unpinned action: ${match[1]}`);
    }
    const checkouts = workflow.match(/uses: actions\/checkout@[0-9a-f]{40}[\s\S]*?persist-credentials: false/gi) || [];
    const checkoutCount = (workflow.match(/uses: actions\/checkout@/g) || []).length;
    assert.equal(checkouts.length, checkoutCount, `${file} checkout credentials are not disabled`);
  }
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
