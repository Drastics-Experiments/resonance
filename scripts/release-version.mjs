#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");
const manifestPath = path.join(repositoryRoot, "release", "version.json");
const versionPattern = /^[0-9]+\.[0-9]+\.[0-9]+$/;

function fail(message) {
  console.error(`release-version: ${message}`);
  process.exit(1);
}

function read(relativePath) {
  return fs.readFileSync(path.join(repositoryRoot, relativePath), "utf8");
}

function write(relativePath, contents) {
  fs.writeFileSync(path.join(repositoryRoot, relativePath), contents);
}

function validateValues(version, build) {
  if (!versionPattern.test(version)) {
    fail(`invalid semantic version: ${version}`);
  }
  if (!Number.isInteger(build) || build < 1) {
    fail(`build must be a positive integer: ${build}`);
  }
}

function readManifest() {
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  validateValues(manifest.version, manifest.build);
  return manifest;
}

function matches(relativePath, expression) {
  return [...read(relativePath).matchAll(expression)].map((match) => match[1]);
}

function expectValues(label, actualValues, expectedValue, expectedCount = 1) {
  if (actualValues.length !== expectedCount) {
    fail(`${label} expected ${expectedCount} value(s), found ${actualValues.length}`);
  }
  for (const actualValue of actualValues) {
    if (actualValue !== String(expectedValue)) {
      fail(`${label} is ${actualValue}, expected ${expectedValue}`);
    }
  }
}

function check({ quiet = false } = {}) {
  const { version, build } = readManifest();

  expectValues(
    "Windows package version",
    matches("windows/package.json", /^\s*"version":\s*"([^"]+)",?$/gm),
    version,
  );
  expectValues(
    "Android versionName",
    matches("android/app/build.gradle.kts", /^\s*versionName\s*=\s*"([^"]+)"$/gm),
    version,
  );
  expectValues(
    "Android versionCode",
    matches("android/app/build.gradle.kts", /^\s*versionCode\s*=\s*([0-9]+)$/gm),
    build,
  );
  expectValues(
    "iOS MARKETING_VERSION",
    matches("ios/LikedSongsMobile.xcodeproj/project.pbxproj", /\bMARKETING_VERSION\s*=\s*([^;]+);/g),
    version,
    2,
  );
  expectValues(
    "iOS CURRENT_PROJECT_VERSION",
    matches("ios/LikedSongsMobile.xcodeproj/project.pbxproj", /\bCURRENT_PROJECT_VERSION\s*=\s*([^;]+);/g),
    build,
    2,
  );
  expectValues(
    "iOS Info.plist version",
    matches("ios/LikedSongsMobile/Info.plist", /<key>CFBundleShortVersionString<\/key><string>([^<]+)<\/string>/g),
    version,
  );
  expectValues(
    "iOS Info.plist build",
    matches("ios/LikedSongsMobile/Info.plist", /<key>CFBundleVersion<\/key><string>([^<]+)<\/string>/g),
    build,
  );
  expectValues(
    "macOS default version",
    matches("mac/scripts/build-release.sh", /^APP_VERSION="\$\{APP_VERSION:-([^}]+)\}"$/gm),
    version,
  );
  expectValues(
    "macOS default build",
    matches("mac/scripts/build-release.sh", /^BUILD_NUMBER="\$\{BUILD_NUMBER:-([^}]+)\}"$/gm),
    build,
  );

  if (!quiet) {
    console.log(`Release versions agree: ${version} (${build})`);
  }
  return { version, build };
}

function replace(relativePath, expression, replacement, expectedCount = 1) {
  const original = read(relativePath);
  let replacements = 0;
  const updated = original.replace(expression, (...arguments_) => {
    replacements += 1;
    return typeof replacement === "function" ? replacement(...arguments_) : replacement;
  });
  if (replacements !== expectedCount) {
    fail(`${relativePath} expected ${expectedCount} replacement(s), made ${replacements}`);
  }
  write(relativePath, updated);
}

function setVersion(version, buildText) {
  const build = Number(buildText);
  validateValues(version, build);

  replace(
    "windows/package.json",
    /(^\s*"version":\s*")[^"]+("\s*,?\s*$)/m,
    (_match, prefix, suffix) => `${prefix}${version}${suffix}`,
  );
  replace(
    "android/app/build.gradle.kts",
    /(^\s*versionName\s*=\s*")[^"]+("\s*$)/m,
    (_match, prefix, suffix) => `${prefix}${version}${suffix}`,
  );
  replace(
    "android/app/build.gradle.kts",
    /(^\s*versionCode\s*=\s*)[0-9]+(\s*$)/m,
    (_match, prefix, suffix) => `${prefix}${build}${suffix}`,
  );
  replace(
    "ios/LikedSongsMobile.xcodeproj/project.pbxproj",
    /\bMARKETING_VERSION\s*=\s*[^;]+;/g,
    `MARKETING_VERSION = ${version};`,
    2,
  );
  replace(
    "ios/LikedSongsMobile.xcodeproj/project.pbxproj",
    /\bCURRENT_PROJECT_VERSION\s*=\s*[^;]+;/g,
    `CURRENT_PROJECT_VERSION = ${build};`,
    2,
  );
  replace(
    "ios/LikedSongsMobile/Info.plist",
    /(<key>CFBundleShortVersionString<\/key><string>)[^<]+(<\/string>)/,
    (_match, prefix, suffix) => `${prefix}${version}${suffix}`,
  );
  replace(
    "ios/LikedSongsMobile/Info.plist",
    /(<key>CFBundleVersion<\/key><string>)[^<]+(<\/string>)/,
    (_match, prefix, suffix) => `${prefix}${build}${suffix}`,
  );
  replace(
    "mac/scripts/build-release.sh",
    /(^APP_VERSION="\$\{APP_VERSION:-)[^}]+(\}"$)/m,
    (_match, prefix, suffix) => `${prefix}${version}${suffix}`,
  );
  replace(
    "mac/scripts/build-release.sh",
    /(^BUILD_NUMBER="\$\{BUILD_NUMBER:-)[^}]+(\}"$)/m,
    (_match, prefix, suffix) => `${prefix}${build}${suffix}`,
  );

  fs.writeFileSync(manifestPath, `${JSON.stringify({ version, build }, null, 2)}\n`);
  check();
}

const [command = "--check", version, build] = process.argv.slice(2);

switch (command) {
  case "--check":
    check();
    break;
  case "--set":
    if (!version || !build) {
      fail("usage: release-version.mjs --set <version> <build>");
    }
    setVersion(version, build);
    break;
  case "--github-output": {
    const current = check({ quiet: true });
    console.log(`version=${current.version}`);
    console.log(`build=${current.build}`);
    console.log(`tag=v${current.version}`);
    console.log(`branch=release/v${current.version}`);
    break;
  }
  default:
    fail("usage: release-version.mjs [--check|--github-output|--set <version> <build>]");
}
