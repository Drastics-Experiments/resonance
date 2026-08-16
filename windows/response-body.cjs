const DEFAULT_MAX_RESPONSE_BYTES = 4 * 1024 * 1024;

function responseLength(response) {
  const value = Number(response?.headers?.get?.("content-length"));
  return Number.isSafeInteger(value) && value >= 0 ? value : null;
}

async function cancelResponseBody(response) {
  try {
    await response?.body?.cancel?.();
  } catch {
    // Cancellation is best effort. The caller still receives the size error.
  }
}

/**
 * Read a fetch response without allowing an unbounded body to enter memory.
 * Native fetch Responses always expose a body stream. The json fallback is
 * only for the tiny response doubles used by the Node tests; production
 * network responses take the bounded stream path above it.
 */
async function readResponseBytes(response, maximumBytes = DEFAULT_MAX_RESPONSE_BYTES, label = "Response") {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 1) {
    throw new RangeError("A positive response limit is required.");
  }
  const declaredLength = responseLength(response);
  if (declaredLength !== null && declaredLength > maximumBytes) {
    await cancelResponseBody(response);
    throw new Error(`${label} is too large.`);
  }

  const reader = response?.body?.getReader?.();
  if (reader) {
    const chunks = [];
    let total = 0;
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const chunk = value instanceof Uint8Array ? value : new Uint8Array(value || []);
        total += chunk.byteLength;
        if (total > maximumBytes) {
          await reader.cancel().catch(() => undefined);
          throw new Error(`${label} is too large.`);
        }
        chunks.push(Buffer.from(chunk));
      }
    } catch (error) {
      await reader.cancel().catch(() => undefined);
      throw error;
    }
    return Buffer.concat(chunks, total);
  }

  // Test doubles may omit a body stream. Keep this branch bounded after the
  // double has materialized its value; real fetch Responses never use it.
  if (typeof response?.json === "function") {
    const value = await response.json();
    const encoded = Buffer.from(JSON.stringify(value));
    if (encoded.length > maximumBytes) throw new Error(`${label} is too large.`);
    return encoded;
  }
  if (typeof response?.text === "function") {
    const text = await response.text();
    const encoded = Buffer.from(String(text));
    if (encoded.length > maximumBytes) throw new Error(`${label} is too large.`);
    return encoded;
  }
  return Buffer.alloc(0);
}

async function readResponseJSON(response, maximumBytes = DEFAULT_MAX_RESPONSE_BYTES, label = "Response") {
  const bytes = await readResponseBytes(response, maximumBytes, label);
  if (!bytes.length) return null;
  try {
    return JSON.parse(bytes.toString("utf8"));
  } catch {
    throw new Error(`${label} is not valid JSON.`);
  }
}

async function readResponseText(response, maximumBytes = DEFAULT_MAX_RESPONSE_BYTES, label = "Response") {
  return (await readResponseBytes(response, maximumBytes, label)).toString("utf8");
}

module.exports = {
  DEFAULT_MAX_RESPONSE_BYTES,
  readResponseBytes,
  readResponseJSON,
  readResponseText,
};
