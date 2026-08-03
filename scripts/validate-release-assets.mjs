#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const [assetDirectoryArgument, version] = process.argv.slice(2);
if (!assetDirectoryArgument || !version) {
  console.error("usage: validate-release-assets.mjs <asset-directory> <version>");
  process.exit(1);
}

const assetDirectory = path.resolve(assetDirectoryArgument);
const windowsInstaller = `Resonance-Setup-${version}.exe`;
const androidPackage = `Resonance-Android-${version}.apk`;
const iosArchive = `Resonance-iOS-Simulator-${version}.zip`;
const expectedAssets = [
  "Resonance-Installer.pkg",
  "Resonance-macOS.zip",
  "Resonance-macOS.zip.sha256",
  "latest-mac.json",
  windowsInstaller,
  `${windowsInstaller}.blockmap`,
  "latest.yml",
  androidPackage,
  `${androidPackage}.sha256`,
  iosArchive,
  `${iosArchive}.sha256`,
].sort();

function fail(message) {
  console.error(`validate-release-assets: ${message}`);
  process.exit(1);
}

function readAsset(name) {
  return fs.readFileSync(path.join(assetDirectory, name));
}

function digest(name, algorithm, encoding) {
  return crypto.createHash(algorithm).update(readAsset(name)).digest(encoding);
}

function validateSha256Sidecar(assetName) {
  const sidecar = readAsset(`${assetName}.sha256`).toString("utf8").trim();
  const match = sidecar.match(/^([0-9a-fA-F]{64})\s+\*?(.+)$/);
  if (!match) {
    fail(`${assetName}.sha256 has an invalid format`);
  }
  if (path.basename(match[2]) !== assetName) {
    fail(`${assetName}.sha256 names ${match[2]}`);
  }
  const actual = digest(assetName, "sha256", "hex");
  if (match[1].toLowerCase() !== actual) {
    fail(`${assetName} SHA-256 does not match its sidecar`);
  }
  return actual;
}

if (!fs.existsSync(assetDirectory) || !fs.statSync(assetDirectory).isDirectory()) {
  fail(`${assetDirectory} is not a directory`);
}

const actualAssets = fs
  .readdirSync(assetDirectory, { withFileTypes: true })
  .filter((entry) => entry.isFile())
  .map((entry) => entry.name)
  .sort();

if (JSON.stringify(actualAssets) !== JSON.stringify(expectedAssets)) {
  fail(`asset set mismatch\nexpected: ${expectedAssets.join(", ")}\nactual: ${actualAssets.join(", ")}`);
}

for (const asset of expectedAssets) {
  if (fs.statSync(path.join(assetDirectory, asset)).size < 1) {
    fail(`${asset} is empty`);
  }
}

const macSha256 = validateSha256Sidecar("Resonance-macOS.zip");
validateSha256Sidecar(androidPackage);
validateSha256Sidecar(iosArchive);

const macManifest = JSON.parse(readAsset("latest-mac.json").toString("utf8"));
if (macManifest.version !== version) {
  fail(`latest-mac.json version is ${macManifest.version}, expected ${version}`);
}
if (macManifest.sha256 !== macSha256) {
  fail("latest-mac.json SHA-256 does not match Resonance-macOS.zip");
}
if (!String(macManifest.url).endsWith(`/releases/download/v${version}/Resonance-macOS.zip`)) {
  fail(`latest-mac.json has an unexpected URL: ${macManifest.url}`);
}

const windowsManifest = readAsset("latest.yml").toString("utf8");
const escapedVersion = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const escapedInstaller = windowsInstaller.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
if (!new RegExp(`^version:\\s*["']?${escapedVersion}["']?\\s*$`, "m").test(windowsManifest)) {
  fail("latest.yml does not contain the expected version");
}
if (!new RegExp(`^path:\\s*["']?${escapedInstaller}["']?\\s*$`, "m").test(windowsManifest)) {
  fail("latest.yml does not point to the expected installer");
}
const windowsSha512 = windowsManifest.match(/^sha512:\s*([^\s]+)\s*$/m)?.[1];
if (!windowsSha512 || windowsSha512 !== digest(windowsInstaller, "sha512", "base64")) {
  fail("latest.yml SHA-512 does not match the Windows installer");
}

console.log(`Validated ${expectedAssets.length} release assets for Resonance ${version}`);
