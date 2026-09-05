const { execFile } = require("node:child_process");
const path = require("node:path");
const { promisify } = require("node:util");

const execFileAsync = promisify(execFile);
const WINDOWS_UPDATE_TEST_EXCEPTION = "RESONANCE_ALLOW_UNSIGNED_UPDATE_TESTS";
const WINDOWS_UPDATE_AUTHENTICITY_PRODUCTION = "production";
const WINDOWS_UPDATE_AUTHENTICITY_UNSIGNED = "unsigned";

function boundedSignatureText(value, maximum = 512) {
  const text = typeof value === "string" ? value.trim() : "";
  return text ? text.slice(0, maximum) : null;
}

function normalizedThumbprint(value) {
  const thumbprint = String(value || "").replace(/\s+/g, "").toUpperCase();
  return /^[A-F0-9]{40}$/.test(thumbprint) ? thumbprint : null;
}

function canonicalAuthenticodeSignature(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const status = boundedSignatureText(value.status || value.Status, 64);
  const subject = boundedSignatureText(value.subject || value.Subject, 2_048);
  const issuer = boundedSignatureText(value.issuer || value.Issuer, 2_048);
  const thumbprint = normalizedThumbprint(value.thumbprint || value.Thumbprint);
  if (status !== "Valid" || !subject || !issuer || !thumbprint || subject === issuer) return null;
  return Object.freeze({ status, subject, issuer, thumbprint });
}

function unsignedAuthenticodeSignature(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const status = boundedSignatureText(value.status || value.Status, 64);
  const subject = boundedSignatureText(value.subject || value.Subject, 2_048);
  const issuer = boundedSignatureText(value.issuer || value.Issuer, 2_048);
  const thumbprint = normalizedThumbprint(value.thumbprint || value.Thumbprint);
  return status === "NotSigned" && !subject && !issuer && !thumbprint;
}

function updateAuthenticityPolicy({
  authenticityMode,
  packaged = true,
  environment = process.env,
} = {}) {
  // Only a non-packaged test process may opt out. A packaged executable never
  // accepts an environment-controlled unsigned-update bypass. An unsigned
  // packaged build must declare that policy in its bundled package metadata.
  const testException = !packaged
    && String(environment?.NODE_ENV || "").toLowerCase() === "test"
    && String(environment?.[WINDOWS_UPDATE_TEST_EXCEPTION] || "") === "1";
  if (testException) {
    return Object.freeze({
      authenticityMode: "test",
      requirePublisher: false,
      exception: "test",
    });
  }
  if (authenticityMode === WINDOWS_UPDATE_AUTHENTICITY_PRODUCTION) {
    return Object.freeze({
      authenticityMode,
      requirePublisher: true,
      exception: null,
    });
  }
  if (authenticityMode === WINDOWS_UPDATE_AUTHENTICITY_UNSIGNED) {
    return Object.freeze({
      authenticityMode,
      requirePublisher: false,
      exception: "explicit-unsigned-release",
    });
  }
  throw new Error("The Windows build has no valid update authenticity policy.");
}

function verifyWindowsUpdatePublisher({
  currentSignature,
  updateSignature,
  authenticityMode,
  packaged = true,
  environment = process.env,
} = {}) {
  const policy = updateAuthenticityPolicy({ authenticityMode, packaged, environment });
  if (policy.exception === "test") {
    return Object.freeze({
      authenticityMode: policy.authenticityMode,
      verified: false,
      exception: policy.exception,
    });
  }

  if (policy.authenticityMode === WINDOWS_UPDATE_AUTHENTICITY_UNSIGNED) {
    if (!unsignedAuthenticodeSignature(currentSignature)) {
      throw new Error("The unsigned Windows update policy requires the installed executable to be explicitly unsigned.");
    }
    if (unsignedAuthenticodeSignature(updateSignature)) {
      return Object.freeze({
        authenticityMode: policy.authenticityMode,
        verified: true,
        authenticode: false,
        exception: policy.exception,
      });
    }
    const update = canonicalAuthenticodeSignature(updateSignature);
    if (!update) throw new Error("The Windows update is neither explicitly unsigned nor Authenticode-signed by a valid certificate.");
    return Object.freeze({
      authenticityMode: policy.authenticityMode,
      verified: true,
      authenticode: true,
      exception: "unsigned-build-signed-upgrade",
      subject: update.subject,
      issuer: update.issuer,
      thumbprint: update.thumbprint,
    });
  }

  const current = canonicalAuthenticodeSignature(currentSignature);
  const update = canonicalAuthenticodeSignature(updateSignature);
  if (!current || !update) throw new Error("The Windows update is not Authenticode-signed by a valid certificate.");
  if (current.thumbprint !== update.thumbprint
      || current.subject !== update.subject
      || current.issuer !== update.issuer) {
    throw new Error("The Windows update is signed by a different publisher identity.");
  }
  return Object.freeze({
    authenticityMode: policy.authenticityMode,
    verified: true,
    subject: update.subject,
    issuer: update.issuer,
    thumbprint: update.thumbprint,
  });
}

async function readAuthenticodeSignature(filePath, execFileImpl = execFileAsync) {
  if (process.platform !== "win32") throw new Error("Authenticode verification is available only on Windows.");
  const resolvedPath = path.resolve(String(filePath || ""));
  if (!resolvedPath || path.extname(resolvedPath).toLowerCase() !== ".exe") {
    throw new Error("The Windows update package is not an executable.");
  }
  const escapedPath = resolvedPath.replace(/'/g, "''");
  const script = [
    `$signature = Get-AuthenticodeSignature -LiteralPath '${escapedPath}'`,
    "if ($null -eq $signature) { exit 2 }",
    "$certificate = $signature.SignerCertificate",
    "$subject = ''; $issuer = ''; $thumbprint = ''",
    "if ($null -ne $certificate) { $subject = [string]$certificate.Subject; $issuer = [string]$certificate.Issuer; $thumbprint = [string]$certificate.Thumbprint }",
    "[ordered]@{ Status = [string]$signature.Status; Subject = $subject; Issuer = $issuer; Thumbprint = $thumbprint } | ConvertTo-Json -Compress",
  ].join("; ");
  const result = await execFileImpl("powershell.exe", [
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-Command",
    script,
  ], { windowsHide: true, maxBuffer: 64 * 1024 });
  let payload;
  try { payload = JSON.parse(String(result?.stdout || "")); }
  catch { throw new Error("Windows could not read the update Authenticode signature."); }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("Windows returned an invalid update Authenticode signature.");
  }
  return Object.freeze({
    status: boundedSignatureText(payload.Status, 64),
    subject: boundedSignatureText(payload.Subject, 2_048),
    issuer: boundedSignatureText(payload.Issuer, 2_048),
    thumbprint: normalizedThumbprint(payload.Thumbprint),
  });
}

async function verifyDownloadedWindowsUpdate({
  downloadedFile,
  currentExecutable,
  authenticityMode,
  packaged = true,
  environment = process.env,
  readSignature = readAuthenticodeSignature,
} = {}) {
  const updatePath = path.resolve(String(downloadedFile || ""));
  const executablePath = path.resolve(String(currentExecutable || ""));
  if (!updatePath || !/\.exe$/i.test(updatePath) || !executablePath || !/\.exe$/i.test(executablePath)) {
    throw new Error("The downloaded Windows update package is invalid.");
  }
  const policy = updateAuthenticityPolicy({ authenticityMode, packaged, environment });
  if (policy.exception === "test") {
    return Object.freeze({
      authenticityMode: policy.authenticityMode,
      verified: false,
      exception: policy.exception,
    });
  }
  return verifyWindowsUpdatePublisher({
    currentSignature: await readSignature(executablePath),
    updateSignature: await readSignature(updatePath),
    authenticityMode,
    packaged,
    environment,
  });
}

module.exports = {
  WINDOWS_UPDATE_TEST_EXCEPTION,
  WINDOWS_UPDATE_AUTHENTICITY_PRODUCTION,
  WINDOWS_UPDATE_AUTHENTICITY_UNSIGNED,
  canonicalAuthenticodeSignature,
  unsignedAuthenticodeSignature,
  readAuthenticodeSignature,
  updateAuthenticityPolicy,
  verifyDownloadedWindowsUpdate,
  verifyWindowsUpdatePublisher,
};
