const { createHash } = require("node:crypto");
const fs = require("node:fs/promises");

const MAX_SERVER_MEDIA_BYTES = 512 * 1024 * 1024;

async function writeResponseToFile(response, destination, options = {}) {
  const { signal, onProgress } = options;
  const expectedSize = Number(options.expectedSize);
  const requestedMaximum = Number(options.maximumBytes);
  const maximumBytes = Math.min(
    MAX_SERVER_MEDIA_BYTES,
    Number.isSafeInteger(requestedMaximum) && requestedMaximum > 0 ? requestedMaximum : MAX_SERVER_MEDIA_BYTES,
  );
  const expectedSHA256 = String(options.expectedSHA256 || "").trim().toLowerCase();
  let reader;
  let handle;
  let cancellation;
  let complete = false;
  let total = 0;
  // The response body and its reader share the Web Streams cancellation API.
  const cancel = (reason) => cancellation ||= (reader || response.body)?.cancel(reason).catch(() => {});
  const abortDownload = () => { void cancel(signal.reason); };
  try {
    signal?.throwIfAborted();
    if (!Number.isSafeInteger(expectedSize) || expectedSize <= 0 || expectedSize > maximumBytes) {
      throw new Error("The server did not declare a supported download size.");
    }
    if (!/^[a-f0-9]{64}$/.test(expectedSHA256)) {
      throw new Error("The server did not provide a valid SHA-256 for this download.");
    }
    const declaredLength = Number(response.headers.get("content-length"));
    if (declaredLength !== expectedSize) {
      throw new Error("The download response size did not match the catalog.");
    }
    if (!response.body) throw new Error("The server returned an empty download.");
    reader = response.body.getReader();
    signal?.addEventListener("abort", abortDownload, { once: true });
    handle = await fs.open(destination, "wx");
    signal?.throwIfAborted();
    const hash = createHash("sha256");
    onProgress?.({ completed: 0, total: expectedSize });
    while (true) {
      const { done, value } = await reader.read();
      signal?.throwIfAborted();
      if (done) break;
      total += value.byteLength;
      if (total > expectedSize) {
        throw new Error("The download exceeded its declared or supported size.");
      }
      hash.update(value);
      let offset = 0;
      while (offset < value.byteLength) {
        const { bytesWritten } = await handle.write(value, offset, value.byteLength - offset);
        if (!bytesWritten) throw new Error("The downloaded file could not be written.");
        offset += bytesWritten;
      }
      onProgress?.({ completed: total, total: expectedSize });
    }
    if (total !== expectedSize) throw new Error("The downloaded file was incomplete.");
    if (hash.digest("hex") !== expectedSHA256) throw new Error("The downloaded file failed SHA-256 verification.");
    await handle.sync();
    await handle.close();
    signal?.throwIfAborted();
    complete = true;
    return { size: total, sha256: expectedSHA256 };
  } catch (error) {
    await cancel(error);
    throw error;
  } finally {
    signal?.removeEventListener("abort", abortDownload);
    reader?.releaseLock();
    if (handle && !complete) {
      await handle.close().catch(() => {});
      await fs.rm(destination, { force: true }).catch(() => {});
    }
  }
}

async function adoptDownloadedFile(temporary, destination, options = {}) {
  const assertAuthorized = options.assertAuthorized;
  const rename = options.rename || fs.rename;
  if (typeof assertAuthorized !== "function") throw new TypeError("An authorization assertion is required.");
  // This synchronous check is the authorization boundary for the single
  // atomic staging-to-library replacement. Expiry after rename begins cannot
  // retroactively revoke the committed file.
  assertAuthorized();
  await rename(temporary, destination);
  return destination;
}

module.exports = {
  MAX_SERVER_MEDIA_BYTES,
  adoptDownloadedFile,
  writeResponseToFile,
};
