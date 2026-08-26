const fs = require("node:fs/promises");
const path = require("node:path");

// Keep this list deliberately extension based. Electron's native open panel
// accepts a filter, but folders and files selected through aliases/symlinks
// still need the same deterministic check after the panel returns.
const AUDIO_EXTENSIONS = new Set([
  ".aac", ".ac3", ".aif", ".aiff", ".alac", ".caf", ".flac", ".m4a", ".m4b",
  ".mp3", ".oga", ".ogg", ".opus", ".wav",
]);
const VIDEO_EXTENSIONS = new Set([".mp4", ".mov", ".m4v", ".webm"]);
const MEDIA_EXTENSIONS = new Set([...AUDIO_EXTENSIONS, ...VIDEO_EXTENSIONS]);

// macOS's NSDirectoryEnumerationOptions.skipsPackageDescendants prevents a
// selected package (for example an app or a media bundle) from being treated
// as a music folder. Node does not expose that flag, so mirror the safe,
// user-visible package extensions here. A package selected directly is still
// inspected as a root; only its descendants are skipped.
const PACKAGE_EXTENSIONS = new Set([
  ".app", ".bundle", ".framework", ".kext", ".mdimporter", ".nuspack", ".nspack",
  ".osax", ".パッケージ", ".pkg", ".plugin", ".prefpane", ".qlgenerator", ".rtfd",
  ".saver", ".service", ".xpc",
]);

const DEFAULT_MAX_FILES = 10_000;

function normalizedMediaPath(value) {
  if (typeof value !== "string") return null;
  const text = value.trim();
  if (!text || text.length > 32_767 || /[\u0000-\u001f\u007f]/.test(text)) return null;
  return path.resolve(text);
}

function isSupportedMediaFile(value) {
  const candidate = normalizedMediaPath(value) || String(value || "");
  return MEDIA_EXTENSIONS.has(path.extname(candidate).toLowerCase());
}

function isPathWithin(filePath, root) {
  const candidate = normalizedMediaPath(filePath);
  const base = normalizedMediaPath(root);
  if (!candidate || !base) return false;
  const relative = path.relative(base, candidate);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative));
}

function isHiddenName(name) {
  return typeof name === "string" && name.startsWith(".");
}

function isPackageDirectory(filePath) {
  return PACKAGE_EXTENSIONS.has(path.extname(filePath).toLowerCase());
}

async function statEntry(filePath, fsAPI) {
  try {
    return await fsAPI.stat(filePath);
  } catch {
    return null;
  }
}

/**
 * Expand native file/folder selections into supported regular media files.
 *
 * This function intentionally resolves symlinks only for directory-cycle
 * detection. Returned paths remain absolute paths selected by the user, so a
 * persisted external track keeps the path that the renderer can play/reveal.
 */
async function expandSelectedMediaFiles(selectedPaths, {
  fsAPI = fs,
  maxFiles = DEFAULT_MAX_FILES,
} = {}) {
  const roots = Array.isArray(selectedPaths) ? selectedPaths : [];
  const limit = Number.isSafeInteger(maxFiles) && maxFiles > 0 ? maxFiles : DEFAULT_MAX_FILES;
  const files = new Map();
  const visitedDirectories = new Set();

  const visit = async (value, { root = false } = {}) => {
    const candidate = normalizedMediaPath(value);
    if (!candidate || files.size >= limit) return;
    const information = await statEntry(candidate, fsAPI);
    if (!information) return;
    if (information.isFile()) {
      if (isSupportedMediaFile(candidate)) files.set(candidate, candidate);
      return;
    }
    if (!information.isDirectory()) return;
    if (!root && isHiddenName(path.basename(candidate))) return;
    if (!root && isPackageDirectory(candidate)) return;

    let identity = candidate;
    try { identity = await fsAPI.realpath(candidate); } catch { /* use the selected path */ }
    if (visitedDirectories.has(identity)) return;
    visitedDirectories.add(identity);
    let entries;
    try { entries = await fsAPI.readdir(candidate, { withFileTypes: true }); }
    catch { return; }
    entries.sort((left, right) => left.name.localeCompare(right.name, undefined, { numeric: true, sensitivity: "base" }));
    for (const entry of entries) {
      if (files.size >= limit) break;
      if (isHiddenName(entry.name) || (!entry.isFile() && isPackageDirectory(entry.name))) continue;
      await visit(path.join(candidate, entry.name));
    }
  };

  for (const value of roots) {
    if (files.size >= limit) break;
    await visit(value, { root: true });
  }
  return [...files.values()].sort((left, right) => left.localeCompare(right, undefined, { numeric: true, sensitivity: "base" }));
}

function createScopedMediaPathTrust({ maxEntries = DEFAULT_MAX_FILES } = {}) {
  const limit = Number.isSafeInteger(maxEntries) && maxEntries > 0 ? maxEntries : DEFAULT_MAX_FILES;
  const trusted = new Map();
  return {
    add(paths) {
      for (const value of Array.isArray(paths) ? paths : [paths]) {
        const candidate = normalizedMediaPath(value);
        if (!candidate || !isSupportedMediaFile(candidate)) continue;
        trusted.delete(candidate);
        trusted.set(candidate, true);
      }
      while (trusted.size > limit) trusted.delete(trusted.keys().next().value);
      return trusted.size;
    },
    has(value) {
      const candidate = normalizedMediaPath(value);
      return Boolean(candidate && trusted.has(candidate));
    },
    delete(value) {
      const candidate = normalizedMediaPath(value);
      return Boolean(candidate && trusted.delete(candidate));
    },
    clear() { trusted.clear(); },
    values() { return [...trusted.keys()]; },
    get size() { return trusted.size; },
  };
}

module.exports = {
  AUDIO_EXTENSIONS,
  DEFAULT_MAX_FILES,
  MEDIA_EXTENSIONS,
  PACKAGE_EXTENSIONS,
  VIDEO_EXTENSIONS,
  createScopedMediaPathTrust,
  expandSelectedMediaFiles,
  isPathWithin,
  isSupportedMediaFile,
  normalizedMediaPath,
};
