import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { recordDesktopSigningEvidence } from "./record-desktop-signing-evidence.mjs";
import { validateReleaseAssets } from "./validate-release-assets.mjs";

const version = "1.2.3";
const validatorPath = fileURLToPath(new URL("./validate-release-assets.mjs", import.meta.url));

function digest(filePath, algorithm, encoding) {
  return crypto.createHash(algorithm).update(fs.readFileSync(filePath)).digest(encoding);
}

function writeFixture(root) {
  const assets = path.join(root, "assets");
  const signing = path.join(root, "signing");
  fs.mkdirSync(assets, { recursive: true });
  const windowsInstaller = `Resonance-Setup-${version}.exe`;
  const androidPackage = `Resonance-Android-${version}.apk`;
  const iosArchive = `Resonance-iOS-Simulator-${version}.zip`;
  const contents = {
    "Resonance-Installer.pkg": "signed and notarized package",
    "Resonance-macOS.zip": "signed and notarized app archive",
    [windowsInstaller]: "signed Windows installer",
    [`${windowsInstaller}.blockmap`]: "block map",
    [androidPackage]: "signed Android package",
    [iosArchive]: "iOS Simulator archive",
  };
  for (const [name, value] of Object.entries(contents)) {
    fs.writeFileSync(path.join(assets, name), value);
  }
  for (const name of ["Resonance-macOS.zip", androidPackage, iosArchive]) {
    fs.writeFileSync(path.join(assets, `${name}.sha256`), `${digest(path.join(assets, name), "sha256", "hex")}  ${name}\n`);
  }
  fs.writeFileSync(
    path.join(assets, "latest-mac.json"),
    `${JSON.stringify({
      version,
      build: "99",
      url: `https://github.com/Drastics-Experiments/resonance/releases/download/v${version}/Resonance-macOS.zip`,
      sha256: digest(path.join(assets, "Resonance-macOS.zip"), "sha256", "hex"),
    })}\n`,
  );
  fs.writeFileSync(
    path.join(assets, "latest-android.json"),
    `${JSON.stringify({
      versionName: version,
      versionCode: 99,
      apkUrl: `https://github.com/Drastics-Experiments/resonance/releases/download/v${version}/${androidPackage}`,
      sha256: digest(path.join(assets, androidPackage), "sha256", "hex"),
      sizeBytes: fs.statSync(path.join(assets, androidPackage)).size,
    })}\n`,
  );
  fs.writeFileSync(
    path.join(assets, "latest.yml"),
    `version: ${version}\npath: ${windowsInstaller}\nsha512: ${digest(path.join(assets, windowsInstaller), "sha512", "base64")}\n`,
  );
  recordDesktopSigningEvidence("macos", assets, version, path.join(signing, "macos.json"));
  recordDesktopSigningEvidence("windows", assets, version, path.join(signing, "windows.json"));
  return { assets, signing };
}

function withFixture(callback) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "resonance-release-validator-"));
  try {
    return callback(writeFixture(root));
  } finally {
    fs.rmSync(root, { force: true, recursive: true });
  }
}

test("production validation requires hash-bound desktop signing evidence", () => {
  withFixture(({ assets, signing }) => {
    assert.equal(validateReleaseAssets(assets, version, { signingEvidenceDirectory: signing }).length, 12);
  });
});

test("production validation fails closed when signing evidence is absent", () => {
  withFixture(({ assets }) => {
    assert.throws(() => validateReleaseAssets(assets, version), /desktop signing evidence is required/);
  });
});

test("production validation requires both native verification reports", () => {
  withFixture(({ assets, signing }) => {
    fs.rmSync(path.join(signing, "windows.json"));
    assert.throws(
      () => validateReleaseAssets(assets, version, { signingEvidenceDirectory: signing }),
      /evidence set mismatch/,
    );
  });
});

test("production validation rejects evidence copied from different bytes", () => {
  withFixture(({ assets, signing }) => {
    fs.appendFileSync(path.join(assets, "Resonance-Installer.pkg"), "tampered");
    assert.throws(
      () => validateReleaseAssets(assets, version, { signingEvidenceDirectory: signing }),
      /evidence (SHA-256|size) does not match/,
    );
  });
});

test("production validation rejects incomplete verification policy", () => {
  withFixture(({ assets, signing }) => {
    const reportPath = path.join(signing, "windows.json");
    const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
    report.verification.timestamp = "missing";
    fs.writeFileSync(reportPath, JSON.stringify(report));
    assert.throws(
      () => validateReleaseAssets(assets, version, { signingEvidenceDirectory: signing }),
      /does not satisfy the production policy/,
    );
  });
});

test("unsigned desktop release fixtures require an explicit opt-out", () => {
  withFixture(({ assets }) => {
    assert.equal(validateReleaseAssets(assets, version, { requireDesktopSignatures: false }).length, 12);
    const production = spawnSync(process.execPath, [validatorPath, assets, version], { encoding: "utf8" });
    assert.equal(production.status, 1);
    assert.match(production.stderr, /desktop signing evidence is required/);
    const unsignedRelease = spawnSync(
      process.execPath,
      [validatorPath, assets, version, "--allow-unsigned-desktop-release"],
      { encoding: "utf8" },
    );
    assert.equal(unsignedRelease.status, 0);
    assert.match(unsignedRelease.stdout, /explicit unsigned desktop release mode/);
  });
});
