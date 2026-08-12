const SERVER_DOWNLOAD_ATTEMPTS = 3;
const SERVER_DOWNLOAD_RETRY_DELAYS_MS = Object.freeze([400, 1_200]);
const SERVER_DOWNLOAD_PROGRESS_INTERVAL_MS = 100;

function serverDownloadDisplayName(song, preferredTitle) {
  const preferred = typeof preferredTitle === "string" ? preferredTitle.trim() : "";
  if (preferred) return preferred;
  const title = typeof song?.title === "string" ? song.title.trim() : "";
  if (title) return title;
  return "Untitled song";
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
    currentFile: serverDownloadDisplayName(song, preferredTitle),
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

  return (event, { force = false } = {}) => {
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
  retryServerDownload,
  serverDownloadDisplayName,
  serverDownloadProgressEvent,
  waitForServerDownloadRetry,
};
