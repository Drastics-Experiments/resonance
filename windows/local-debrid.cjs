const { createHash, randomUUID } = require("node:crypto");
const fs = require("node:fs/promises");
const path = require("node:path");
const { LocalImportError } = require("./local-import-core.cjs");
const { duplicateTrack, normalizedMetadata } = require("./local-import-platform.cjs");

const MAX_PROVIDER_JSON_BYTES = 1024 * 1024;
const MAX_EXTERNAL_AUDIO_BYTES = 350 * 1024 * 1024;
const AUDIO_EXTENSIONS = new Set([".aac", ".flac", ".m4a", ".mp3", ".oga", ".ogg", ".wav"]);
const CONTENT_TYPE_EXTENSIONS = new Map([
  ["application/ogg", ".ogg"],
  ["audio/aac", ".aac"],
  ["audio/flac", ".flac"],
  ["audio/mp4", ".m4a"],
  ["audio/mpeg", ".mp3"],
  ["audio/ogg", ".ogg"],
  ["audio/wav", ".wav"],
  ["audio/x-flac", ".flac"],
  ["audio/x-m4a", ".m4a"],
  ["audio/x-wav", ".wav"],
]);

function externalError(stage, code, message, retryAfter = null) {
  const error = new LocalImportError(stage, code, message);
  error.retryAfter = retryAfter;
  return error;
}

function normalizedServerSettings(value = {}) {
  const adminToken = String(value.adminToken || "").trim();
  if (!adminToken || !String(value.baseURL || "").trim()) return null;
  let base;
  try { base = new URL(String(value.baseURL).trim()); }
  catch { throw externalError("searching_candidates", "INVALID_SERVER_URL", "The configured Resonance server URL is invalid."); }
  if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password) {
    throw externalError("searching_candidates", "INVALID_SERVER_URL", "The configured Resonance server URL is invalid.");
  }
  base.pathname = base.pathname.replace(/\/+$/, "") + "/";
  base.search = "";
  base.hash = "";
  return { base, adminToken, profileID: String(value.profileID || "default").trim() || "default" };
}

function providerHeaders(settings) {
  return {
    Authorization: `Bearer ${settings.adminToken}`,
    "X-Resonance-Profile": settings.profileID,
    "Content-Type": "application/json",
    Accept: "application/json",
  };
}

async function readJSONWithLimit(response) {
  const declared = Number(response.headers.get("content-length") || 0);
  if (declared > MAX_PROVIDER_JSON_BYTES) {
    await response.body?.cancel().catch(() => undefined);
    throw externalError("searching_candidates", "PROVIDER_RESPONSE_TOO_LARGE", "The server returned an oversized source response.");
  }
  if (!response.body) return {};
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_PROVIDER_JSON_BYTES) {
      await reader.cancel().catch(() => undefined);
      throw externalError("searching_candidates", "PROVIDER_RESPONSE_TOO_LARGE", "The server returned an oversized source response.");
    }
    chunks.push(Buffer.from(value));
  }
  if (!total) return {};
  try { return JSON.parse(Buffer.concat(chunks, total).toString("utf8")); }
  catch { throw externalError("searching_candidates", "INVALID_PROVIDER_RESPONSE", "The server returned invalid source information."); }
}

function providerMessage(payload, fallback) {
  return typeof payload?.error === "string" && payload.error.trim() ? payload.error.trim().slice(0, 1_000) : fallback;
}

function releaseCandidate(track, release, index) {
  if (!release || typeof release !== "object") return null;
  const sourceURL = typeof release.magnet_link === "string" ? release.magnet_link.trim() : "";
  const title = typeof release.title === "string" ? release.title.trim().slice(0, 500) : "";
  if (!title || !/^magnet:\?/i.test(sourceURL) || sourceURL.length > 8_192) return null;
  const size = Number(release.size);
  const seeders = Number(release.seeders);
  return {
    candidateID: `debrid:${String(release.info_hash || index).slice(0, 128)}`,
    title,
    artist: track.artist,
    album: track.album,
    durationSeconds: null,
    thumbnailURL: track.artworkURL,
    sourceProvider: "debrid_vault",
    sourceKind: "server_file",
    sourceURL,
    officialArtist: false,
    score: null,
    confidence: "file",
    quality: typeof release.quality === "string" ? release.quality.slice(0, 128) : null,
    size: Number.isFinite(size) && size > 0 ? size : null,
    seeders: Number.isFinite(seeders) && seeders >= 0 ? seeders : null,
    indexer: typeof release.indexer === "string" ? release.indexer.slice(0, 128) : null,
    match: null,
    serverBacked: true,
  };
}

async function searchFileBackedSources(track, settingsValue, signal, fetchImpl = fetch) {
  const settings = normalizedServerSettings(settingsValue);
  if (!settings) return [];
  const url = new URL("api/v1/admin/debrid/resolve", settings.base);
  let response;
  try {
    response = await fetchImpl(url, {
      method: "POST",
      headers: providerHeaders(settings),
      body: JSON.stringify({ source: track.sourceURL }),
      signal,
    });
  } catch (error) {
    if (error?.name === "AbortError") throw error;
    throw externalError("searching_candidates", "EXTERNAL_SOURCE_UNREACHABLE", "The configured source server could not be reached.");
  }
  const payload = await readJSONWithLimit(response);
  if (response.status === 404 || response.status === 503) return [];
  if (!response.ok) {
    throw externalError(
      "searching_candidates",
      "EXTERNAL_SOURCE_SEARCH_FAILED",
      providerMessage(payload, `The source server returned HTTP ${response.status}.`),
      response.headers.get("retry-after"),
    );
  }
  const releases = Array.isArray(payload.releases) ? payload.releases : [];
  return releases.map((release, index) => releaseCandidate(track, release, index)).filter(Boolean).slice(0, 12);
}

function externalMetadata(value) {
  const metadata = normalizedMetadata(value);
  return {
    title: metadata.title,
    artist: metadata.artist,
    ...(metadata.album ? { album: metadata.album } : {}),
    ...(Number(value?.durationSeconds) > 0 ? { duration_seconds: Number(value.durationSeconds) } : {}),
    ...(metadata.artworkURL ? { artwork_url: metadata.artworkURL } : {}),
    ...(metadata.sourceURL ? { source_url: metadata.sourceURL } : {}),
  };
}

function abortableDelay(milliseconds, signal) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, milliseconds);
    signal?.addEventListener("abort", () => {
      clearTimeout(timer);
      reject(signal.reason instanceof Error ? signal.reason : new DOMException("Import cancelled", "AbortError"));
    }, { once: true });
  });
}

function safeExternalFilename(value, contentType, metadata) {
  const sourceName = path.basename(String(value || "")).replace(/[<>:"/\\|?*\u0000-\u001f]/g, "-").replace(/\s+/g, " ").trim();
  const contentTypeExtension = CONTENT_TYPE_EXTENSIONS.get(String(contentType || "").split(";", 1)[0].trim().toLowerCase());
  const sourceExtension = path.extname(sourceName).toLowerCase();
  const extension = AUDIO_EXTENSIONS.has(sourceExtension) ? sourceExtension : contentTypeExtension;
  if (!extension) throw externalError("downloading", "UNSUPPORTED_EXTERNAL_AUDIO", "The selected source did not produce a supported audio file.");
  const metadataBase = `${metadata.artist} - ${metadata.title}`.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "-").replace(/\s+/g, " ").trim();
  const sourceBase = path.basename(sourceName, sourceExtension).slice(0, 220);
  return `${(metadataBase || sourceBase || `Track-${Date.now()}`).slice(0, 220)}${extension}`;
}

async function uniqueDestination(directory, preferred) {
  const extension = path.extname(preferred);
  const base = path.basename(preferred, extension);
  let candidate = path.join(directory, preferred);
  for (let counter = 2; ; counter += 1) {
    try { await fs.access(candidate); }
    catch { return candidate; }
    candidate = path.join(directory, `${base} ${counter}${extension}`);
  }
}

async function downloadPreparedFile(payload, input, settings, signal, onStage, fetchImpl) {
  const temporaryURL = String(payload.temporary_download_url || "");
  let url;
  try { url = new URL(temporaryURL); }
  catch { throw externalError("downloading", "INVALID_DOWNLOAD_URL", "The source server did not return a usable audio file URL."); }
  if (url.origin !== settings.base.origin || !['http:', 'https:'].includes(url.protocol) || url.username || url.password) {
    throw externalError("downloading", "UNSAFE_DOWNLOAD_URL", "The source server returned an unsafe audio file URL.");
  }
  let response;
  try { response = await fetchImpl(url, { headers: { Accept: "audio/*,application/ogg" }, signal }); }
  catch (error) {
    if (error?.name === "AbortError") throw error;
    throw externalError("downloading", "EXTERNAL_DOWNLOAD_UNREACHABLE", "The prepared audio file could not be reached.");
  }
  if (!response.ok || !response.body) {
    await response.body?.cancel().catch(() => undefined);
    throw externalError("downloading", "EXTERNAL_DOWNLOAD_FAILED", `The prepared audio file returned HTTP ${response.status}.`);
  }
  const declared = Number(response.headers.get("content-length") || 0);
  if (!Number.isFinite(declared) || declared <= 0 || declared > MAX_EXTERNAL_AUDIO_BYTES) {
    await response.body.cancel().catch(() => undefined);
    throw externalError("downloading", "INVALID_EXTERNAL_AUDIO_SIZE", "The prepared audio file has an invalid or unsupported size.");
  }
  const metadata = normalizedMetadata(input.metadata);
  const sourceFile = payload.source_file?.name || payload.song?.filename || payload.duplicate_of?.filename;
  const filename = safeExternalFilename(sourceFile, response.headers.get("content-type"), metadata);
  await fs.mkdir(input.destinationDirectory, { recursive: true });
  const destination = await uniqueDestination(input.destinationDirectory, filename);
  const temporary = `${destination}.${randomUUID()}.part`;
  const file = await fs.open(temporary, "wx");
  const hash = createHash("sha256");
  let completed = 0;
  let downloadFailure = null;
  try {
    const reader = response.body.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      completed += value.byteLength;
      if (completed > declared || completed > MAX_EXTERNAL_AUDIO_BYTES) {
        await reader.cancel().catch(() => undefined);
        throw externalError("downloading", "EXTERNAL_SIZE_MISMATCH", "The prepared audio file exceeded its verified size.");
      }
      const bytes = Buffer.from(value);
      hash.update(bytes);
      await file.write(bytes);
      onStage({ stage: "downloading", completed, total: declared, provider: "torbox" });
    }
  } catch (error) {
    downloadFailure = error;
  } finally {
    await file.close().catch(() => undefined);
  }
  if (downloadFailure) {
    await fs.rm(temporary, { force: true }).catch(() => undefined);
    throw downloadFailure;
  }
  if (completed !== declared) {
    await fs.rm(temporary, { force: true }).catch(() => undefined);
    throw externalError("downloading", "EXTERNAL_SIZE_MISMATCH", "The prepared audio file ended before its verified size.");
  }
  const sha256 = hash.digest("hex");
  const duplicate = duplicateTrack(input.existing, sha256, sha256);
  if (duplicate) {
    await fs.rm(temporary, { force: true }).catch(() => undefined);
    return { kind: "duplicate", track: duplicate, serverBacked: true, remoteSong: payload.song || payload.duplicate_of || null };
  }
  onStage({ stage: "saving_local" });
  await fs.rename(temporary, destination);
  return {
    kind: "created",
    filePath: destination,
    size: completed,
    sourceSha256: sha256,
    contentSha256: sha256,
    sourceURL: metadata.sourceURL,
    metadata,
    serverBacked: true,
    remoteSong: payload.song || payload.duplicate_of || null,
  };
}

async function importFileBackedSource(input, signal, onStage = () => {}, fetchImpl = fetch) {
  const settings = normalizedServerSettings(input);
  if (!settings) throw externalError("preparing_external", "ADMIN_KEY_REQUIRED", "Add a Resonance server admin key to use file-backed source results.");
  let body = input.resume
    ? { ...input.resume, ...(Number.isSafeInteger(input.fileID) ? { file_id: input.fileID } : {}) }
    : { source: String(input.sourceURL || ""), metadata: externalMetadata(input.metadata) };
  const url = new URL("api/v1/admin/debrid/import", settings.base);
  for (let attempt = 0; attempt < 60; attempt += 1) {
    onStage({ stage: attempt ? "waiting_external" : "preparing_external", provider: "torbox", attempt });
    let response;
    try {
      response = await fetchImpl(url, {
        method: "POST",
        headers: providerHeaders(settings),
        body: JSON.stringify(body),
        signal,
      });
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      throw externalError("preparing_external", "EXTERNAL_IMPORT_UNREACHABLE", "The file-backed source server could not be reached.");
    }
    const payload = await readJSONWithLimit(response);
    if (response.status === 202 && payload.resume) {
      const seconds = Math.max(2, Math.min(15, Number(payload.retry_after_seconds) || 5));
      body = payload.resume;
      onStage({ stage: "waiting_external", provider: "torbox", retryAfter: seconds, transfer: payload.transfer || null });
      await abortableDelay(seconds * 1000, signal);
      continue;
    }
    if (response.status === 409 && payload.status === "selection_required" && payload.resume) {
      const files = (Array.isArray(payload.audio_files) ? payload.audio_files : []).map((file) => ({
        id: Number(file?.id),
        name: typeof file?.name === "string" ? file.name.slice(0, 500) : "Audio file",
        size: Number(file?.size) > 0 ? Number(file.size) : null,
        contentType: typeof file?.content_type === "string" ? file.content_type.slice(0, 128) : null,
      })).filter((file) => Number.isSafeInteger(file.id));
      if (!files.length) throw externalError("awaiting_selection", "NO_EXTERNAL_AUDIO_FILES", "The selected release did not expose a supported audio file.");
      return { kind: "selection_required", files, resume: payload.resume, serverBacked: true };
    }
    const duplicateReady = response.status === 409 && payload.duplicate_of && payload.temporary_download_url;
    if (!response.ok && !duplicateReady) {
      throw externalError(
        "preparing_external",
        "EXTERNAL_IMPORT_FAILED",
        providerMessage(payload, `The file-backed source server returned HTTP ${response.status}.`),
        response.headers.get("retry-after"),
      );
    }
    if (!payload.temporary_download_url) {
      throw externalError("downloading", "MISSING_EXTERNAL_FILE", "The source server did not return the prepared audio file.");
    }
    return downloadPreparedFile(payload, input, settings, signal, onStage, fetchImpl);
  }
  throw externalError("waiting_external", "EXTERNAL_IMPORT_TIMEOUT", "The file-backed source is still preparing. Try again in a few minutes.");
}

module.exports = {
  importFileBackedSource,
  releaseCandidate,
  searchFileBackedSources,
};
