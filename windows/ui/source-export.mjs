import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { deflateRaw } from "node:zlib";

export const SOURCE_MANIFEST_PATH = "/__resonance/preview/v1/manifest.json";
export const SOURCE_ARCHIVE_PREFIX = "/__resonance/preview/v1/source";
export const SOURCE_EXPORT_TTL_MS = 24 * 60 * 60 * 1000;
export const SOURCE_PROJECT = "resonance";
export const SOURCE_TARGET = "macos-electron-preview";

const MAX_SOURCE_FILES = 20_000;
const MAX_SOURCE_BYTES = 256 * 1024 * 1024;
const MAX_ARCHIVE_BYTES = 256 * 1024 * 1024;
const ZIP_UTF8_FLAG = 0x0800;
const ZIP_DEFLATE_METHOD = 8;
const deflateRawAsync = promisify(deflateRaw);
const REQUIRED_SOURCE_PATHS = Object.freeze([
  ".launcher-terminal.zsh",
  "windows/package.json",
  "windows/pnpm-lock.yaml",
]);

const EXCLUDED_DIRECTORY_NAMES = new Set([
  ".build",
  ".git",
  ".gradle",
  ".idea",
  ".memory",
  ".next",
  ".ssh",
  ".swiftpm",
  ".vscode",
  "application support",
  "build",
  "certificates",
  "coverage",
  "credentials",
  "deriveddata",
  "dist",
  "downloads",
  "local-artifacts",
  "local-projects",
  "local music",
  "logs",
  "music",
  "music libraries",
  "music library",
  "node_modules",
  "out",
  "secrets",
  "signing",
  "target",
  "user data",
  "user-data",
  "userdata",
  "xcuserdata",
]);

const EXCLUDED_FILE_NAMES = new Set([
  ".gitconfig",
  ".netrc",
  ".pypirc",
  "id_dsa",
  "id_ecdsa",
  "id_ed25519",
  "id_rsa",
  "account-session.json",
  "auth.json",
  "credentials.json",
  "keystore.properties",
  "library.json",
  "secrets.json",
  "server-credentials.json",
  "signing.properties",
  "token.json",
  "tokens.json",
]);

const SENSITIVE_CONFIG_FILE_NAMES = new Set([
  ".npmrc",
  "gradle.properties",
]);

const SENSITIVE_CONFIG_ASSIGNMENT = /^\s*(?:\/\/[^\r\n:=]+:)?[^\r\n=]*(?:_auth|auth[_-]?token|access[_-]?token|api[_-]?key|client[_-]?secret|password|private[_-]?key|signing|storefile|keyalias)[^\r\n=]*=/im;

const EXCLUDED_FILE_SUFFIXES = [
  ".cer",
  ".crt",
  ".der",
  ".gpg",
  ".jks",
  ".kdbx",
  ".key",
  ".keystore",
  ".log",
  ".mobileprovision",
  ".p12",
  ".p8",
  ".pem",
  ".pfx",
  ".asc",
  ".provisionprofile",
  ".xcuserstate",
  ".aac",
  ".aiff",
  ".alac",
  ".flac",
  ".m4a",
  ".m4v",
  ".mkv",
  ".mov",
  ".mp3",
  ".mp4",
  ".ogg",
  ".opus",
  ".wav",
  ".webm",
  ".wma",
];

function runGit(repoRoot, args, { allowFailure = false } = {}) {
  return new Promise((resolve, reject) => {
    execFile("git", ["-C", repoRoot, ...args], {
      encoding: "buffer",
      maxBuffer: 32 * 1024 * 1024,
      windowsHide: true,
    }, (error, stdout) => {
      if (error && !allowFailure) {
        reject(new Error(`Git could not prepare the source preview (${args[0]}).`, { cause: error }));
        return;
      }
      resolve(error ? null : stdout);
    });
  });
}

function decodedGitText(buffer) {
  return buffer ? buffer.toString("utf8").trim() : "";
}

function decodedGitPaths(buffer) {
  const paths = [];
  let start = 0;
  for (let index = 0; index <= buffer.length; index += 1) {
    if (index !== buffer.length && buffer[index] !== 0) continue;
    if (index > start) {
      const encoded = buffer.subarray(start, index);
      const decoded = encoded.toString("utf8");
      if (!Buffer.from(decoded, "utf8").equals(encoded)) {
        throw new Error("Source preview contains a file name that is not valid UTF-8.");
      }
      paths.push(decoded);
    }
    start = index + 1;
  }
  return paths.sort();
}

function decodedGitIndexModes(buffer) {
  const modes = new Map();
  let start = 0;
  for (let index = 0; index <= buffer.length; index += 1) {
    if (index !== buffer.length && buffer[index] !== 0) continue;
    if (index > start) {
      const record = buffer.subarray(start, index);
      const separator = record.indexOf(0x09);
      if (separator < 0) throw new Error("Source preview Git index entry is invalid.");
      const metadata = record.subarray(0, separator).toString("ascii").split(" ");
      const encodedPath = record.subarray(separator + 1);
      const relativePath = encodedPath.toString("utf8");
      if (!Buffer.from(relativePath, "utf8").equals(encodedPath)) {
        throw new Error("Source preview contains a file name that is not valid UTF-8.");
      }
      if (!/^[0-7]{6}$/.test(metadata[0] || "") || metadata[2] !== "0") {
        throw new Error(`Source preview Git index entry is unsupported: ${relativePath}`);
      }
      modes.set(relativePath, Number.parseInt(metadata[0], 8) & 0o777);
    }
    start = index + 1;
  }
  return modes;
}

export function sourceExportPathAllowed(relativePath) {
  if (typeof relativePath !== "string" || !relativePath || relativePath.includes("\0")) return false;
  if (path.posix.isAbsolute(relativePath) || relativePath.includes("\\")) return false;
  if (/^[a-z]:\//i.test(relativePath)) return false;
  const segments = relativePath.split("/");
  if (segments.some((segment) => !segment || segment === "." || segment === "..")) return false;

  const loweredSegments = segments.map((segment) => segment.toLowerCase());
  if (loweredSegments.some((segment) => segment.startsWith(".env"))) return false;
  if (loweredSegments.some((segment) => EXCLUDED_DIRECTORY_NAMES.has(segment))) return false;

  const basename = loweredSegments.at(-1);
  if (EXCLUDED_FILE_NAMES.has(basename)) return false;
  if (EXCLUDED_FILE_SUFFIXES.some((suffix) => basename.endsWith(suffix))) return false;
  return true;
}

function containsSensitiveConfig(relativePath, contents) {
  const basename = path.posix.basename(relativePath).toLowerCase();
  return SENSITIVE_CONFIG_FILE_NAMES.has(basename)
    && SENSITIVE_CONFIG_ASSIGNMENT.test(contents.toString("utf8"));
}

async function collectSourceFiles(repoRoot, fileList, fileModes, mtime) {
  if (fileList.length > MAX_SOURCE_FILES) {
    throw new Error(`Source preview contains more than ${MAX_SOURCE_FILES} files.`);
  }

  const entries = [];
  let totalBytes = 0;
  for (const relativePath of fileList) {
    if (!sourceExportPathAllowed(relativePath)) continue;
    const absolutePath = path.resolve(repoRoot, ...relativePath.split("/"));
    if (absolutePath !== repoRoot && !absolutePath.startsWith(`${repoRoot}${path.sep}`)) {
      throw new Error("Source preview path escaped the repository root.");
    }

    let stat;
    try {
      stat = await fs.lstat(absolutePath);
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }

    if (stat.isSymbolicLink()) throw new Error(`Source preview cannot contain a symbolic link: ${relativePath}`);
    if (!stat.isFile()) continue;

    const contents = await fs.readFile(absolutePath);
    if (containsSensitiveConfig(relativePath, contents)) continue;
    totalBytes += contents.length;
    if (totalBytes > MAX_SOURCE_BYTES) {
      throw new Error(`Source preview is larger than ${MAX_SOURCE_BYTES} uncompressed bytes.`);
    }
    entries.push({
      relativePath,
      mode: fileModes.get(relativePath) ?? stat.mode,
      contents,
      mtime,
    });
  }
  const exportedPaths = new Set(entries.map((entry) => entry.relativePath));
  const missingRequired = REQUIRED_SOURCE_PATHS.filter((requiredPath) => !exportedPaths.has(requiredPath));
  if (missingRequired.length) {
    throw new Error(`Source preview is missing required launcher files: ${missingRequired.join(", ")}`);
  }
  return entries;
}

function sourceEntriesFingerprint(entries) {
  const fingerprint = createHash("sha256");
  for (const entry of entries) {
    const encodedPath = Buffer.from(entry.relativePath, "utf8");
    const metadata = Buffer.alloc(12);
    metadata.writeUInt32LE(encodedPath.length, 0);
    metadata.writeUInt32LE(entry.mode & 0o777, 4);
    metadata.writeUInt32LE(entry.contents.length, 8);
    fingerprint.update(metadata);
    fingerprint.update(encodedPath);
    fingerprint.update(entry.contents);
  }
  return fingerprint.digest("hex");
}

const CRC32_TABLE = Object.freeze(Array.from({ length: 256 }, (_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) {
    value = (value & 1) ? (0xedb88320 ^ (value >>> 1)) : (value >>> 1);
  }
  return value >>> 0;
}));

function crc32(contents) {
  let value = 0xffffffff;
  for (const byte of contents) value = CRC32_TABLE[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

function zipTimestamp(unixSeconds) {
  const date = new Date(Math.max(315_532_800, unixSeconds) * 1000);
  const year = Math.min(2107, Math.max(1980, date.getUTCFullYear()));
  return {
    date: ((year - 1980) << 9) | ((date.getUTCMonth() + 1) << 5) | date.getUTCDate(),
    time: (date.getUTCHours() << 11) | (date.getUTCMinutes() << 5) | Math.floor(date.getUTCSeconds() / 2),
  };
}

async function buildZip(entries) {
  const localChunks = [];
  const centralChunks = [];
  let localOffset = 0;
  const { date, time } = zipTimestamp(entries[0]?.mtime || 315_532_800);

  for (const entry of entries) {
    const name = Buffer.from(entry.relativePath, "utf8");
    if (name.length > 0xffff) throw new Error(`Source preview path is too long: ${entry.relativePath}`);
    const compressed = await deflateRawAsync(entry.contents, { level: 9 });
    const checksum = crc32(entry.contents);
    if (entry.contents.length > 0xffffffff || compressed.length > 0xffffffff || localOffset > 0xffffffff) {
      throw new Error("Source preview exceeds the ZIP32 size limit.");
    }

    const localHeader = Buffer.alloc(30);
    localHeader.writeUInt32LE(0x04034b50, 0);
    localHeader.writeUInt16LE(20, 4);
    localHeader.writeUInt16LE(ZIP_UTF8_FLAG, 6);
    localHeader.writeUInt16LE(ZIP_DEFLATE_METHOD, 8);
    localHeader.writeUInt16LE(time, 10);
    localHeader.writeUInt16LE(date, 12);
    localHeader.writeUInt32LE(checksum, 14);
    localHeader.writeUInt32LE(compressed.length, 18);
    localHeader.writeUInt32LE(entry.contents.length, 22);
    localHeader.writeUInt16LE(name.length, 26);
    localHeader.writeUInt16LE(0, 28);
    localChunks.push(localHeader, name, compressed);

    const centralHeader = Buffer.alloc(46);
    centralHeader.writeUInt32LE(0x02014b50, 0);
    centralHeader.writeUInt16LE((3 << 8) | 20, 4);
    centralHeader.writeUInt16LE(20, 6);
    centralHeader.writeUInt16LE(ZIP_UTF8_FLAG, 8);
    centralHeader.writeUInt16LE(ZIP_DEFLATE_METHOD, 10);
    centralHeader.writeUInt16LE(time, 12);
    centralHeader.writeUInt16LE(date, 14);
    centralHeader.writeUInt32LE(checksum, 16);
    centralHeader.writeUInt32LE(compressed.length, 20);
    centralHeader.writeUInt32LE(entry.contents.length, 24);
    centralHeader.writeUInt16LE(name.length, 28);
    centralHeader.writeUInt16LE(0, 30);
    centralHeader.writeUInt16LE(0, 32);
    centralHeader.writeUInt16LE(0, 34);
    centralHeader.writeUInt16LE(0, 36);
    centralHeader.writeUInt32LE(((0o100000 | (entry.mode & 0o777)) << 16) >>> 0, 38);
    centralHeader.writeUInt32LE(localOffset, 42);
    centralChunks.push(centralHeader, name);
    localOffset += localHeader.length + name.length + compressed.length;
  }

  const centralDirectory = Buffer.concat(centralChunks);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralDirectory.length, 12);
  end.writeUInt32LE(localOffset, 16);
  const archive = Buffer.concat([...localChunks, centralDirectory, end]);
  if (archive.length > MAX_ARCHIVE_BYTES) {
    throw new Error(`Source preview ZIP is larger than ${MAX_ARCHIVE_BYTES} bytes.`);
  }
  return archive;
}

async function repositoryState(repoRoot) {
  const [commitBuffer, branchBuffer, statusBuffer, timestampBuffer, filesBuffer, indexBuffer] = await Promise.all([
    runGit(repoRoot, ["rev-parse", "HEAD"]),
    runGit(repoRoot, ["symbolic-ref", "--quiet", "--short", "HEAD"], { allowFailure: true }),
    runGit(repoRoot, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"]),
    runGit(repoRoot, ["show", "-s", "--format=%ct", "HEAD"]),
    runGit(repoRoot, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]),
    runGit(repoRoot, ["ls-files", "--stage", "-z"]),
  ]);
  const commit = decodedGitText(commitBuffer);
  const commitTimestamp = Number(decodedGitText(timestampBuffer));
  if (!/^[0-9a-f]{40,64}$/.test(commit)) throw new Error("Source preview Git commit is invalid.");
  if (!Number.isFinite(commitTimestamp)) throw new Error("Source preview Git timestamp is invalid.");
  return {
    branch: decodedGitText(branchBuffer) || null,
    commit,
    commitTimestamp,
    dirty: statusBuffer.length > 0,
    fingerprint: Buffer.concat([
      commitBuffer,
      Buffer.from([0]),
      statusBuffer,
      Buffer.from([0]),
      filesBuffer,
      Buffer.from([0]),
      indexBuffer,
    ]).toString("base64"),
    files: decodedGitPaths(filesBuffer),
    fileModes: decodedGitIndexModes(indexBuffer),
  };
}

export async function createSourceSnapshot({
  repoRoot,
  now = () => Date.now(),
  ttlMs = SOURCE_EXPORT_TTL_MS,
} = {}) {
  if (!repoRoot) throw new Error("Source preview repository root is required.");
  const root = await fs.realpath(path.resolve(repoRoot));
  if (!Number.isFinite(ttlMs) || ttlMs <= 0 || ttlMs > 24 * 60 * 60 * 1000) {
    throw new Error("Source preview expiration must be between 1 millisecond and 24 hours.");
  }

  let state;
  let entries;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    state = await repositoryState(root);
    const firstEntries = await collectSourceFiles(root, state.files, state.fileModes, state.commitTimestamp);
    const verifiedState = await repositoryState(root);
    const verifiedEntries = await collectSourceFiles(
      root,
      verifiedState.files,
      verifiedState.fileModes,
      verifiedState.commitTimestamp,
    );
    const finalState = await repositoryState(root);
    if (
      state.fingerprint === verifiedState.fingerprint
      && verifiedState.fingerprint === finalState.fingerprint
      && sourceEntriesFingerprint(firstEntries) === sourceEntriesFingerprint(verifiedEntries)
    ) {
      state = verifiedState;
      entries = verifiedEntries;
      break;
    }
    if (attempt === 1) throw new Error("The repository changed while creating the source preview. Try again.");
  }

  const archive = await buildZip(entries);
  const sha256 = createHash("sha256").update(archive).digest("hex");
  const createdAtMs = now();
  if (!Number.isFinite(createdAtMs)) throw new Error("Source preview creation time is invalid.");
  const revisionName = state.branch || "detached";
  const revisionLabel = `${revisionName} @ ${state.commit.slice(0, 7)}${state.dirty ? " + changes" : ""}`;
  const sourceURL = `${SOURCE_ARCHIVE_PREFIX}/${sha256}.zip`;
  const manifest = Object.freeze({
    schemaVersion: 1,
    project: SOURCE_PROJECT,
    target: SOURCE_TARGET,
    revision: Object.freeze({
      branch: state.branch,
      commit: state.commit,
      dirty: state.dirty,
      label: revisionLabel,
    }),
    source: Object.freeze({
      url: sourceURL,
      format: "zip",
      sha256,
      size: archive.length,
    }),
    createdAt: new Date(createdAtMs).toISOString(),
    expiresAt: new Date(createdAtMs + ttlMs).toISOString(),
  });
  return Object.freeze({
    manifest,
    manifestBody: Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`),
    archive,
  });
}

export function createSourceExporter({
  repoRoot,
  now = () => Date.now(),
  ttlMs = SOURCE_EXPORT_TTL_MS,
} = {}) {
  let snapshot = null;
  let pending = null;
  return {
    async getSnapshot() {
      if (snapshot && now() < Date.parse(snapshot.manifest.expiresAt)) return snapshot;
      if (!pending) {
        pending = createSourceSnapshot({ repoRoot, now, ttlMs })
          .then((result) => {
            snapshot = result;
            return result;
          })
          .finally(() => { pending = null; });
      }
      return pending;
    },
  };
}
