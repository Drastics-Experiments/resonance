#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

function fail(message) {
  throw new Error(message);
}

export function expectedAssetNames(version) {
  const windowsInstaller = `Resonance-Setup-${version}.exe`;
  const iphoneWindowsInstaller = `Resonance-iPhone-Installer-Windows-${version}.exe`;
  const iphoneMacArchive = `Resonance-iPhone-Installer-macOS-${version}.zip`;
  const androidPackage = `Resonance-Android-${version}.apk`;
  const iosArchive = `Resonance-iOS-Simulator-${version}.zip`;
  const iosDevicePackage = `Resonance-iOS-Device-${version}.ipa`;
  return [
    "Resonance-Installer.pkg",
    "Resonance-macOS.zip",
    "Resonance-macOS.zip.sha256",
    "latest-mac.json",
    windowsInstaller,
    `${windowsInstaller}.blockmap`,
    "latest.yml",
    iphoneWindowsInstaller,
    `${iphoneWindowsInstaller}.sha256`,
    iphoneMacArchive,
    `${iphoneMacArchive}.sha256`,
    androidPackage,
    `${androidPackage}.sha256`,
    "latest-android.json",
    iosArchive,
    `${iosArchive}.sha256`,
    iosDevicePackage,
    `${iosDevicePackage}.sha256`,
  ].sort();
}

function readJSON(filePath, label) {
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`);
  }
}

function validateDesktopSigningEvidence(assetDirectory, version, signingEvidenceDirectory) {
  if (!signingEvidenceDirectory) {
    fail("desktop signing evidence is required for a production release");
  }
  const evidenceDirectory = path.resolve(signingEvidenceDirectory);
  if (!fs.existsSync(evidenceDirectory) || !fs.statSync(evidenceDirectory).isDirectory()) {
    fail(`${evidenceDirectory} is not a desktop signing evidence directory`);
  }
  const actualEvidenceFiles = fs
    .readdirSync(evidenceDirectory, { withFileTypes: true })
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .sort();
  const expectedEvidenceFiles = ["macos.json", "windows.json"];
  if (JSON.stringify(actualEvidenceFiles) !== JSON.stringify(expectedEvidenceFiles)) {
    fail(
      `desktop signing evidence set mismatch\n` +
        `expected: ${expectedEvidenceFiles.join(", ")}\n` +
        `actual: ${actualEvidenceFiles.join(", ")}`,
    );
  }

  const policies = {
    macos: {
      artifacts: ["Resonance-Installer.pkg", "Resonance-macOS.zip"],
      verification: {
        applicationSignature: "developer-id-valid-trusted-chain",
        installerSignature: "developer-id-valid-trusted-chain",
        applicationNotarization: "stapled-and-validated",
        installerNotarization: "stapled-and-validated",
      },
    },
    windows: {
      artifacts: [`Resonance-Setup-${version}.exe`],
      verification: {
        applicationSignature: "authenticode-valid-trusted-chain",
        installerSignature: "authenticode-valid-trusted-chain",
        timestamp: "present-and-valid",
      },
    },
  };

  for (const [platform, policy] of Object.entries(policies)) {
    const reportPath = path.join(evidenceDirectory, `${platform}.json`);
    if (!fs.existsSync(reportPath) || !fs.statSync(reportPath).isFile()) {
      fail(`missing ${platform} desktop signing evidence`);
    }
    const report = readJSON(reportPath, `${platform} desktop signing evidence`);
    if (report.schemaVersion !== 1 || report.platform !== platform || report.version !== version) {
      fail(`${platform} desktop signing evidence has unexpected identity or version`);
    }
    const reportedArtifacts = Object.keys(report.artifacts || {}).sort();
    const expectedArtifacts = [...policy.artifacts].sort();
    if (JSON.stringify(reportedArtifacts) !== JSON.stringify(expectedArtifacts)) {
      fail(`${platform} desktop signing evidence has an unexpected artifact set`);
    }
    for (const name of expectedArtifacts) {
      const filePath = path.join(assetDirectory, name);
      const actualSha256 = crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
      const actualSize = fs.statSync(filePath).size;
      if (report.artifacts[name]?.sha256 !== actualSha256) {
        fail(`${platform} desktop signing evidence SHA-256 does not match ${name}`);
      }
      if (report.artifacts[name]?.sizeBytes !== actualSize) {
        fail(`${platform} desktop signing evidence size does not match ${name}`);
      }
    }
    if (JSON.stringify(report.verification) !== JSON.stringify(policy.verification)) {
      fail(`${platform} desktop signing evidence does not satisfy the production policy`);
    }
  }
}

export function validateReleaseAssets(
  assetDirectoryArgument,
  version,
  {
    requireDesktopSignatures = true,
    signingEvidenceDirectory,
    releaseTag = `v${version}`,
    windowsVersion = version,
  } = {},
) {
  if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(version)) {
    fail(`invalid semantic version: ${version}`);
  }
  const escapedBaseVersion = version.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  if (!new RegExp(`^v${escapedBaseVersion}(?:-pre\\.[1-9][0-9]{9,11})?$`).test(releaseTag)) {
    fail(`invalid release tag for ${version}: ${releaseTag}`);
  }
  const prereleaseTimestamp = releaseTag.match(/-pre\.([1-9][0-9]{9,11})$/)?.[1];
  const expectedWindowsVersion = prereleaseTimestamp ? `${version}-pre.${prereleaseTimestamp}` : version;
  if (windowsVersion !== expectedWindowsVersion) {
    fail(`invalid Windows updater version for ${releaseTag}: ${windowsVersion}`);
  }
  const assetDirectory = path.resolve(assetDirectoryArgument);
  const windowsInstaller = `Resonance-Setup-${version}.exe`;
  const iphoneWindowsInstaller = `Resonance-iPhone-Installer-Windows-${version}.exe`;
  const iphoneMacArchive = `Resonance-iPhone-Installer-macOS-${version}.zip`;
  const androidPackage = `Resonance-Android-${version}.apk`;
  const iosArchive = `Resonance-iOS-Simulator-${version}.zip`;
  const iosDevicePackage = `Resonance-iOS-Device-${version}.ipa`;
  const expectedAssets = expectedAssetNames(version);

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
  validateSha256Sidecar(iphoneWindowsInstaller);
  validateSha256Sidecar(iphoneMacArchive);
  validateSha256Sidecar(androidPackage);
  validateSha256Sidecar(iosArchive);
  validateSha256Sidecar(iosDevicePackage);

  const macManifest = JSON.parse(readAsset("latest-mac.json").toString("utf8"));
  if (macManifest.version !== version) {
    fail(`latest-mac.json version is ${macManifest.version}, expected ${version}`);
  }
  if (macManifest.releaseTag !== releaseTag) {
    fail(`latest-mac.json release tag is ${macManifest.releaseTag}, expected ${releaseTag}`);
  }
  if (macManifest.sha256 !== macSha256) {
    fail("latest-mac.json SHA-256 does not match Resonance-macOS.zip");
  }
  if (!String(macManifest.url).endsWith(`/releases/download/${releaseTag}/Resonance-macOS.zip`)) {
    fail(`latest-mac.json has an unexpected URL: ${macManifest.url}`);
  }

  const androidManifest = JSON.parse(readAsset("latest-android.json").toString("utf8"));
  if (androidManifest.versionName !== version) {
    fail(`latest-android.json version is ${androidManifest.versionName}, expected ${version}`);
  }
  if (androidManifest.releaseTag !== releaseTag) {
    fail(`latest-android.json release tag is ${androidManifest.releaseTag}, expected ${releaseTag}`);
  }
  if (!Number.isSafeInteger(androidManifest.versionCode) || androidManifest.versionCode < 1) {
    fail("latest-android.json has an invalid versionCode");
  }
  if (androidManifest.sha256 !== digest(androidPackage, "sha256", "hex")) {
    fail("latest-android.json SHA-256 does not match the Android package");
  }
  if (androidManifest.sizeBytes !== fs.statSync(path.join(assetDirectory, androidPackage)).size) {
    fail("latest-android.json size does not match the Android package");
  }
  if (!String(androidManifest.apkUrl).endsWith(`/releases/download/${releaseTag}/${androidPackage}`)) {
    fail(`latest-android.json has an unexpected URL: ${androidManifest.apkUrl}`);
  }

  const windowsManifest = readAsset("latest.yml").toString("utf8");
  const escapedVersion = windowsVersion.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
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

  if (requireDesktopSignatures) {
    validateDesktopSigningEvidence(assetDirectory, version, signingEvidenceDirectory);
  }
  return expectedAssets;
}

const scriptPath = fileURLToPath(import.meta.url);
if (path.resolve(process.argv[1] || "") === scriptPath) {
  const arguments_ = process.argv.slice(2);
  const unsignedFlags = [
    "--allow-unsigned-development",
    "--allow-unsigned-desktop-release",
  ];
  const selectedUnsignedFlags = unsignedFlags.filter((flag) => arguments_.includes(flag));
  const allowUnsignedIndex = selectedUnsignedFlags.length === 1
    ? arguments_.indexOf(selectedUnsignedFlags[0])
    : -1;
  if (selectedUnsignedFlags.length > 1) {
    console.error("validate-release-assets: specify only one unsigned desktop mode");
    process.exitCode = 1;
  }
  const allowUnsignedDevelopment = allowUnsignedIndex !== -1;
  if (allowUnsignedDevelopment) arguments_.splice(allowUnsignedIndex, 1);
  const signingEvidenceIndex = arguments_.indexOf("--signing-evidence");
  let signingEvidenceDirectory;
  if (signingEvidenceIndex !== -1) {
    signingEvidenceDirectory = arguments_[signingEvidenceIndex + 1];
    arguments_.splice(signingEvidenceIndex, 2);
  }
  const releaseTagIndex = arguments_.indexOf("--release-tag");
  const releaseTag = releaseTagIndex === -1 ? undefined : arguments_[releaseTagIndex + 1];
  if (releaseTagIndex !== -1) arguments_.splice(releaseTagIndex, 2);
  const windowsVersionIndex = arguments_.indexOf("--windows-version");
  const windowsVersion = windowsVersionIndex === -1 ? undefined : arguments_[windowsVersionIndex + 1];
  if (windowsVersionIndex !== -1) arguments_.splice(windowsVersionIndex, 2);
  const [assetDirectory, version] = arguments_;
  if (
    process.exitCode ||
    !assetDirectory ||
    !version ||
    arguments_.length !== 2 ||
    (signingEvidenceIndex !== -1 && !signingEvidenceDirectory) ||
    (releaseTagIndex !== -1 && !releaseTag) ||
    (windowsVersionIndex !== -1 && !windowsVersion)
  ) {
    console.error(
      "usage: validate-release-assets.mjs <asset-directory> <version> " +
        "[--release-tag <tag>] [--windows-version <version>] " +
        "[--signing-evidence <directory> | --allow-unsigned-desktop-release]",
    );
    process.exitCode = 1;
  } else if (allowUnsignedDevelopment && signingEvidenceDirectory) {
    console.error("validate-release-assets: unsigned development mode cannot accept signing evidence");
    process.exitCode = 1;
  } else {
    try {
      const assets = validateReleaseAssets(assetDirectory, version, {
        requireDesktopSignatures: !allowUnsignedDevelopment,
        signingEvidenceDirectory,
        releaseTag,
        windowsVersion,
      });
      const suffix = allowUnsignedDevelopment
        ? " (explicit unsigned desktop release mode)"
        : " with desktop signing evidence";
      console.log(`Validated ${assets.length} release assets for Resonance ${version}${suffix}`);
    } catch (error) {
      console.error(`validate-release-assets: ${error.message}`);
      process.exitCode = 1;
    }
  }
}
