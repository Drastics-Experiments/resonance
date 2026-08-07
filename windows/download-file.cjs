const { createHash } = require("node:crypto");
const fs = require("node:fs/promises");

const MAX_SERVER_MEDIA_BYTES = 512 * 1024 * 1024;

async function writeResponseToFile(response, destination, options = {}) {
  const { signal } = options;
  const expectedSize = Number(options.expectedSize);
  const requestedMaximum = Number(options.maximumBytes);
  const maximumBytes = Math.min(
    MAX_SERVER_MEDIA_BYTES,
    Number.isSafeInteger(requestedMaximum) && requestedMaximum > 0 ? requestedMaximum : MAX_SERVER_MEDIA_BYTES,
  );
  const expectedSHA256 = String(options.expectedSHA256 || "").trim().toLocaleLowerCase();
  if (!Number.isSafeInteger(expectedSize) || expectedSize <= 0 || expectedSize > maximumBytes) {
    await response.body?.cancel?.().catch(() => undefined);
    throw new Error("The server did not declare a supported download size.");
  }
  if (!/^[a-f0-9]{64}$/.test(expectedSHA256)) {
    await response.body?.cancel?.().catch(() => undefined);
    throw new Error("The server did not provide a valid SHA-256 for this download.");
  }

  const declaredLength = Number(response.headers?.get?.("content-length"));
  if (!Number.isSafeInteger(declaredLength) || declaredLength <= 0 || declaredLength !== expectedSize) {
    await response.body?.cancel?.().catch(() => undefined);
    throw new Error("The download response size did not match the catalog.");
  }
  const reader = response.body?.getReader();
  if (!reader) throw new Error("The server returned an empty download.");
  let handle = null;
  try {
    handle = await fs.open(destination, "wx");
  } catch (error) {
    await reader.cancel(error).catch(() => undefined);
    reader.releaseLock();
    throw error;
  }
  const hash = createHash("sha256");
  let total = 0;
  let result = null;
  let failure = null;
  try {
    while (true) {
      signal?.throwIfAborted();
      const { done, value } = await reader.read();
      if (done) break;
      const buffer = Buffer.from(value);
      total += buffer.length;
      if (total > expectedSize || total > maximumBytes) {
        throw new Error("The download exceeded its declared or supported size.");
      }
      hash.update(buffer);
      let offset = 0;
      while (offset < buffer.length) {
        const { bytesWritten } = await handle.write(buffer, offset, buffer.length - offset);
        if (!bytesWritten) throw new Error("The downloaded file could not be written.");
        offset += bytesWritten;
      }
    }
    signal?.throwIfAborted();
    if (total !== expectedSize) throw new Error("The downloaded file was incomplete.");
    const sha256 = hash.digest("hex");
    if (sha256 !== expectedSHA256) throw new Error("The downloaded file failed SHA-256 verification.");
    await handle.sync();
    result = { size: total, sha256 };
  } catch (error) {
    await reader.cancel(error).catch(() => undefined);
    failure = error;
  } finally {
    reader.releaseLock();
    try { await handle.close(); }
    catch (error) { failure ||= error; }
  }
  if (failure) {
    await fs.rm(destination, { force: true }).catch(() => undefined);
    throw failure;
  }
  return result;
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
