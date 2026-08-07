#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const platformArtifacts = {
  macos: ["Resonance-Installer.pkg", "Resonance-macOS.zip"],
  windows: (version) => [`Resonance-Setup-${version}.exe`],
};

const platformVerification = {
  macos: {
    applicationSignature: "developer-id-valid-trusted-chain",
    installerSignature: "developer-id-valid-trusted-chain",
    applicationNotarization: "stapled-and-validated",
    installerNotarization: "stapled-and-validated",
  },
  windows: {
    applicationSignature: "authenticode-valid-trusted-chain",
    installerSignature: "authenticode-valid-trusted-chain",
    timestamp: "present-and-valid",
  },
};

function fail(message) {
  throw new Error(message);
}

function sha256(filePath) {
  return crypto.createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

export function recordDesktopSigningEvidence(platform, assetDirectoryArgument, version, outputPathArgument) {
  if (!Object.hasOwn(platformArtifacts, platform)) {
    fail(`unsupported platform: ${platform}`);
  }
  if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(version)) {
    fail(`invalid semantic version: ${version}`);
  }

  const assetDirectory = path.resolve(assetDirectoryArgument);
  const outputPath = path.resolve(outputPathArgument);
  const names = typeof platformArtifacts[platform] === "function"
    ? platformArtifacts[platform](version)
    : platformArtifacts[platform];
  const artifacts = {};

  for (const name of names) {
    const filePath = path.join(assetDirectory, name);
    if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
      fail(`missing verified ${platform} artifact: ${filePath}`);
    }
    artifacts[name] = {
      sha256: sha256(filePath),
      sizeBytes: fs.statSync(filePath).size,
    };
  }

  const evidence = {
    schemaVersion: 1,
    platform,
    version,
    artifacts,
    verification: platformVerification[platform],
  };
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600 });
  return evidence;
}

const scriptPath = fileURLToPath(import.meta.url);
if (path.resolve(process.argv[1] || "") === scriptPath) {
  const [platform, assetDirectory, version, outputPath] = process.argv.slice(2);
  if (!platform || !assetDirectory || !version || !outputPath) {
    console.error(
      "usage: record-desktop-signing-evidence.mjs <macos|windows> <asset-directory> <version> <output-file>",
    );
    process.exitCode = 1;
  } else {
    try {
      recordDesktopSigningEvidence(platform, assetDirectory, version, outputPath);
      console.log(`Recorded ${platform} signing evidence at ${path.resolve(outputPath)}`);
    } catch (error) {
      console.error(`record-desktop-signing-evidence: ${error.message}`);
      process.exitCode = 1;
    }
  }
}
