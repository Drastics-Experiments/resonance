const SERVER_DOWNLOAD_ATTEMPTS = 3;
const SERVER_DOWNLOAD_RETRY_DELAYS_MS = Object.freeze([400, 1_200]);
const SERVER_DOWNLOAD_PROGRESS_INTERVAL_MS = 100;

function serverDownloadDisplayName(song, _remoteName, preferredTitle) {
  const preferred = typeof preferredTitle === "string" ? preferredTitle.trim() : "";
  if (preferred) return preferred;
  const title = typeof song?.title === "string" ? song.title.trim() : "";
  if (title) return title;
  return "Untitled song";
}

function serverDownloadMetadata(song, preferred = {}) {
  const text = (value, fallback, maximum = 500) => {
    const cleaned = typeof value === "string"
      ? value.replace(/[\u0000-\u001f]+/g, " ").replace(/\s+/g, " ").trim()
      : "";
    return (cleaned || fallback).slice(0, maximum);
  };
  const positiveNumber = (...values) => {
    const match = values.map(Number).find((value) => Number.isFinite(value) && value > 0);
    return match || null;
  };
  const title = text(preferred?.title, serverDownloadDisplayName(song));
  const artist = text(preferred?.artist, text(song?.artist, "Unknown Artist"));
  const album = text(preferred?.album, text(song?.album, "Server Library"));
  const artworkURL = text(
    preferred?.artworkURL,
    text(song?.artwork_url || song?.artworkURL, "", 2_048),
    2_048,
  ) || null;
  return {
    title,
    artist,
    album,
    durationSeconds: positiveNumber(
      preferred?.durationSeconds,
      preferred?.duration,
      song?.duration_seconds,
      song?.duration,
    ),
    artworkURL,
    sourceURL: typeof song?.source_url === "string" ? song.source_url : null,
  };
}

function serverDownloadMetadataSnapshot(value = {}) {
  const text = (candidate, maximum = 500) => {
    if (typeof candidate !== "string") return null;
    const cleaned = candidate.replace(/[\u0000-\u001f]+/g, " ").replace(/\s+/g, " ").trim();
    return cleaned ? cleaned.slice(0, maximum) : null;
  };
  const sourceURL = (() => {
    if (!Object.hasOwn(value, "sourceURL")) return undefined;
    if (value.sourceURL === null) return null;
    if (typeof value.sourceURL !== "string"
        || !value.sourceURL
        || value.sourceURL.length > 8_192
        || value.sourceURL.trim() !== value.sourceURL
        || /[\u0000-\u001f]/.test(value.sourceURL)) return undefined;
    try {
      const parsed = new URL(value.sourceURL);
      return parsed.protocol === "https:" && !parsed.username && !parsed.password
        ? value.sourceURL
        : undefined;
    } catch {
      return undefined;
    }
  })();
  const mediaKind = value.mediaKind === "video" || value.mediaKind === "audio"
    ? value.mediaKind
    : null;
  const duration = Number(value.durationSeconds ?? value.duration);
  return {
    title: text(value.title),
    artist: text(value.artist),
    album: text(value.album),
    duration: Number.isFinite(duration) && duration > 0 ? duration : null,
    artworkURL: text(value.artworkURL, 2_048),
    resolved: value.resolved === true,
    sourceURL,
    mediaKind,
  };
}

function serverDownloadMetadataContextMatches(song, preferred = {}) {
  const catalogSourceURL = song?.source_url == null ? null : song.source_url;
  const catalogMediaKind = song?.media_kind === "video" ? "video" : "audio";
  return preferred.sourceURL !== undefined
    && preferred.sourceURL === catalogSourceURL
    && preferred.mediaKind === catalogMediaKind;
}

function serverDownloadMetadataIsResolved(song, preferred = {}) {
  const usable = (title, artist) => {
    const normalizedTitle = String(title || "").trim().toLowerCase();
    const normalizedArtist = String(artist || "").trim().toLowerCase();
    return Boolean(
      normalizedTitle
      && normalizedArtist
      && normalizedTitle !== "resolving metadata…"
      && normalizedTitle !== "metadata unavailable"
      && normalizedArtist !== "automatic lookup"
    );
  };
  if (!serverDownloadMetadataContextMatches(song, preferred)) return false;
  return preferred?.resolved === true
    && (usable(preferred.title, preferred.artist) || usable(song?.title || song?.name, song?.artist));
}

function serverDownloadImportedMetadata(resolvedMetadata, preferredMetadata, metadataIsResolved, sourceURL) {
  const resolved = resolvedMetadata && typeof resolvedMetadata === "object" && !Array.isArray(resolvedMetadata)
    ? resolvedMetadata
    : {};
  const preferred = metadataIsResolved
    && preferredMetadata
    && typeof preferredMetadata === "object"
    && !Array.isArray(preferredMetadata)
    ? preferredMetadata
    : {};
  return { ...resolved, ...preferred, sourceURL };
}

function createServerCatalogSnapshotStore() {
  const snapshots = new Map();
  const exactContext = (context = {}) => ({
    origin: String(context.origin || ""),
    profileID: String(context.profileID || "default"),
    credentialFingerprint: String(context.credentialFingerprint || ""),
  });
  return Object.freeze({
    remember(ownerID, context, catalog) {
      snapshots.set(ownerID, Object.freeze({ ...exactContext(context), catalog }));
      return catalog;
    },
    read(ownerID, context) {
      const expected = exactContext(context);
      const snapshot = snapshots.get(ownerID);
      return snapshot
        && snapshot.origin === expected.origin
        && snapshot.profileID === expected.profileID
        && snapshot.credentialFingerprint === expected.credentialFingerprint
        ? snapshot.catalog
        : null;
    },
    clear(ownerID) {
      return snapshots.delete(ownerID);
    },
    clearContext(context) {
      const expected = exactContext(context);
      let removed = 0;
      for (const [ownerID, snapshot] of snapshots) {
        if (snapshot.origin !== expected.origin || snapshot.profileID !== expected.profileID) continue;
        snapshots.delete(ownerID);
        removed += 1;
      }
      return removed;
    },
  });
}

function serverDownloadProgressEvent({
  song,
  preferredTitle,
  itemIndex,
  itemCount,
  completedBytes = 0,
  totalBytes = 0,
  completedItems = 0,
  title,
} = {}) {
  const count = Math.max(0, Math.floor(Number(itemCount) || 0));
  const index = Math.min(count, Math.max(count ? 1 : 0, Math.floor(Number(itemIndex) || 0)));
  const bytesTotal = Math.max(0, Number(totalBytes) || 0);
  return {
    direction: "download",
    currentFile: serverDownloadDisplayName(song, null, preferredTitle),
    completed: Math.max(0, Math.floor(Number(completedItems) || 0)),
    total: count,
    itemCompleted: Math.min(bytesTotal || Number.MAX_SAFE_INTEGER, Math.max(0, Number(completedBytes) || 0)),
    itemTotal: bytesTotal,
    itemIndex: index,
    itemCount: count,
    title: typeof title === "string" && title.trim() ? title.trim() : undefined,
    autoHide: false,
  };
}

function createServerDownloadProgressPublisher(publish, options = {}) {
  if (typeof publish !== "function") throw new TypeError("A progress publisher is required.");
  const now = typeof options.now === "function" ? options.now : Date.now;
  const minimumInterval = Math.max(0, Number(options.minimumInterval) || SERVER_DOWNLOAD_PROGRESS_INTERVAL_MS);
  let lastPublishedAt = Number.NEGATIVE_INFINITY;
  let publishedInitial = false;
  let publishedFinal = false;

  const publishProgress = (event, { force = false } = {}) => {
    const completed = Math.max(0, Number(event?.itemCompleted) || 0);
    const total = Math.max(0, Number(event?.itemTotal) || 0);
    const isInitial = completed === 0 && !publishedInitial;
    const isFinal = total > 0 && completed >= total && !publishedFinal;
    const timestamp = Number(now());
    const elapsed = Number.isFinite(timestamp) ? timestamp - lastPublishedAt : minimumInterval;
    if (!force && !isInitial && !isFinal && elapsed < minimumInterval) return false;

    publish(event);
    if (Number.isFinite(timestamp)) lastPublishedAt = timestamp;
    if (completed === 0) publishedInitial = true;
    if (total > 0 && completed >= total) publishedFinal = true;
    return true;
  };
  publishProgress.reset = () => {
    lastPublishedAt = Number.NEGATIVE_INFINITY;
    publishedInitial = false;
    publishedFinal = false;
  };
  return publishProgress;
}

function waitForServerDownloadRetry(milliseconds, signal) {
  signal?.throwIfAborted();
  if (!milliseconds) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(finish, milliseconds);
    function finish() {
      signal?.removeEventListener("abort", abort);
      resolve();
    }
    function abort() {
      clearTimeout(timer);
      reject(signal.reason || new DOMException("Download cancelled", "AbortError"));
    }
    signal?.addEventListener("abort", abort, { once: true });
  });
}

async function retryServerDownload(operation, options = {}) {
  const attempts = Math.max(1, Math.floor(Number(options.attempts) || SERVER_DOWNLOAD_ATTEMPTS));
  const delays = Array.isArray(options.delays) && options.delays.length
    ? options.delays
    : SERVER_DOWNLOAD_RETRY_DELAYS_MS;
  const pause = options.pause || waitForServerDownloadRetry;
  let lastError;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    options.signal?.throwIfAborted();
    try {
      return await operation(attempt);
    } catch (error) {
      if (options.signal?.aborted) options.signal.throwIfAborted();
      if (error?.name === "AbortError") throw error;
      if (error?.retryable === false) throw error;
      lastError = error;
      if (attempt >= attempts) break;
      options.onRetry?.({ attempt, nextAttempt: attempt + 1, error });
      await pause(delays[Math.min(attempt - 1, delays.length - 1)] || 0, options.signal);
    }
  }

  throw lastError;
}

module.exports = {
  SERVER_DOWNLOAD_ATTEMPTS,
  SERVER_DOWNLOAD_PROGRESS_INTERVAL_MS,
  SERVER_DOWNLOAD_RETRY_DELAYS_MS,
  createServerDownloadProgressPublisher,
  createServerCatalogSnapshotStore,
  retryServerDownload,
  serverDownloadDisplayName,
  serverDownloadImportedMetadata,
  serverDownloadMetadata,
  serverDownloadMetadataContextMatches,
  serverDownloadMetadataIsResolved,
  serverDownloadMetadataSnapshot,
  serverDownloadProgressEvent,
  waitForServerDownloadRetry,
};
