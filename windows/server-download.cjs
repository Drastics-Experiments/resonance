const SERVER_DOWNLOAD_ATTEMPTS = 3;
const SERVER_DOWNLOAD_RETRY_DELAYS_MS = Object.freeze([400, 1_200]);

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
  SERVER_DOWNLOAD_RETRY_DELAYS_MS,
  retryServerDownload,
  waitForServerDownloadRetry,
};
