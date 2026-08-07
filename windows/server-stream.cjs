const { MAX_SERVER_MEDIA_BYTES } = require("./download-file.cjs");
const { createHash } = require("node:crypto");

const SERVER_STREAM_SCHEME = "resonance-stream";
const SERVER_STREAM_SESSION_PATTERN = /^[a-f0-9]{64}$/;
const SERVER_STREAM_CONTENT_TYPES = new Set([
  "audio/aac",
  "audio/aiff",
  "audio/flac",
  "audio/mp3",
  "audio/mp4",
  "audio/mpeg",
  "audio/ogg",
  "audio/opus",
  "audio/wav",
  "audio/wave",
  "audio/x-aiff",
  "audio/x-flac",
  "audio/x-m4a",
  "audio/x-wav",
  "application/octet-stream",
  "application/ogg",
]);

class ServerStreamValidationError extends Error {
  constructor(code, message, status = 502) {
    super(message);
    this.name = "ServerStreamValidationError";
    this.code = code;
    this.status = status;
  }
}

function fail(code, message, status) {
  throw new ServerStreamValidationError(code, message, status);
}

function supportedMediaSize(value) {
  const size = Number(value);
  if (!Number.isSafeInteger(size) || size <= 0 || size > MAX_SERVER_MEDIA_BYTES) {
    fail("INVALID_MEDIA_SIZE", "The stream does not have a supported declared size.");
  }
  return size;
}

function safeInteger(value, label) {
  if (typeof value !== "string" || !/^\d+$/.test(value)) {
    fail("INVALID_RANGE", `${label} must be a non-negative decimal integer.`, 416);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) fail("INVALID_RANGE", `${label} is too large.`, 416);
  return parsed;
}

function parseSingleByteRange(value, totalSize) {
  const size = supportedMediaSize(totalSize);
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string" || value !== value.trim() || value.includes(",")) {
    fail("INVALID_RANGE", "Only one canonical byte range is supported.", 416);
  }
  let start;
  let end;
  let match = /^bytes=(\d+)-(\d*)$/.exec(value);
  if (match) {
    start = safeInteger(match[1], "Range start");
    end = match[2] ? safeInteger(match[2], "Range end") : size - 1;
    if (start >= size || end < start) {
      fail("UNSATISFIABLE_RANGE", "The requested byte range is outside this stream.", 416);
    }
    end = Math.min(end, size - 1);
  } else {
    match = /^bytes=-(\d+)$/.exec(value);
    if (!match) fail("INVALID_RANGE", "Only one canonical byte range is supported.", 416);
    const suffixLength = safeInteger(match[1], "Range suffix length");
    if (suffixLength <= 0) fail("INVALID_RANGE", "Range suffix length must be positive.", 416);
    const length = Math.min(suffixLength, size);
    start = size - length;
    end = size - 1;
  }
  return Object.freeze({
    start,
    end,
    length: end - start + 1,
    header: `bytes=${start}-${end}`,
  });
}

function headerValue(headers, name) {
  if (headers?.get) return headers.get(name);
  if (!headers || typeof headers !== "object") return null;
  const entry = Object.entries(headers).find(([key]) => key.toLocaleLowerCase() === name.toLocaleLowerCase());
  return entry ? String(entry[1]) : null;
}

function exactContentLength(headers) {
  const value = headerValue(headers, "content-length");
  if (typeof value !== "string" || !/^\d+$/.test(value)) {
    fail("INVALID_CONTENT_LENGTH", "The stream response is missing a canonical Content-Length.");
  }
  const length = Number(value);
  if (!Number.isSafeInteger(length) || length <= 0 || length > MAX_SERVER_MEDIA_BYTES) {
    fail("INVALID_CONTENT_LENGTH", "The stream response has an unsupported Content-Length.");
  }
  return length;
}

function safeContentType(headers) {
  const value = String(headerValue(headers, "content-type") || "");
  const type = value.split(";", 1)[0].trim().toLocaleLowerCase();
  if (!SERVER_STREAM_CONTENT_TYPES.has(type)) {
    fail("INVALID_CONTENT_TYPE", "The server returned an unsupported streaming media type.");
  }
  return type;
}

function validateStreamResponse({ status, headers, expectedSize, requestedRange, method = "GET" }) {
  const size = supportedMediaSize(expectedSize);
  const requestMethod = String(method || "GET").toLocaleUpperCase();
  if (requestMethod !== "GET" && requestMethod !== "HEAD") {
    fail("METHOD_NOT_ALLOWED", "Only GET and HEAD stream requests are supported.", 405);
  }
  const encoding = String(headerValue(headers, "content-encoding") || "identity").trim().toLocaleLowerCase();
  if (encoding !== "identity") fail("ENCODED_MEDIA", "Encoded stream responses are not supported.");
  const contentType = safeContentType(headers);
  const contentLength = exactContentLength(headers);
  const forwarded = {
    "Accept-Ranges": "bytes",
    "Cache-Control": "no-store, private",
    "Content-Length": String(contentLength),
    "Content-Type": contentType,
    "X-Content-Type-Options": "nosniff",
  };

  if (!requestedRange) {
    if (status !== 200 || contentLength !== size) {
      fail("INVALID_FULL_RESPONSE", "The full stream response does not match the catalog size.");
    }
    return Object.freeze({ status: 200, contentLength, headers: Object.freeze(forwarded) });
  }

  if (status !== 206) fail("INVALID_PARTIAL_RESPONSE", "The server did not return a partial stream response.");
  const contentRange = String(headerValue(headers, "content-range") || "");
  const match = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(contentRange);
  if (!match) fail("INVALID_CONTENT_RANGE", "The partial stream response has an invalid Content-Range.");
  const start = safeInteger(match[1], "Content-Range start");
  const end = safeInteger(match[2], "Content-Range end");
  const total = safeInteger(match[3], "Content-Range total");
  if (start !== requestedRange.start
      || end < start
      || end > requestedRange.end
      || total !== size
      || contentLength !== end - start + 1) {
    fail("CONTENT_RANGE_MISMATCH", "The partial stream response does not match the requested media bytes.");
  }
  forwarded["Content-Range"] = `bytes ${start}-${end}/${total}`;
  return Object.freeze({ status: 206, contentLength, headers: Object.freeze(forwarded) });
}

function serverStreamURL(sessionID) {
  const id = String(sessionID || "");
  if (!SERVER_STREAM_SESSION_PATTERN.test(id)) fail("INVALID_SESSION", "Invalid stream session.", 404);
  return `${SERVER_STREAM_SCHEME}://media/${id}`;
}

function remoteStreamHistoryTrackID({ serverOrigin, profileID, songID }) {
  let origin;
  try { origin = new URL(String(serverOrigin || "")).origin; }
  catch { fail("INVALID_HISTORY_IDENTITY", "Invalid remote stream history origin.", 400); }
  const profile = String(profileID || "default");
  const song = String(songID || "");
  if (!origin
      || origin.length > 2_048
      || !profile
      || profile.length > 128
      || !song
      || song.length > 128
      || /[\u0000-\u001f\u007f]/.test(`${profile}${song}`)) {
    fail("INVALID_HISTORY_IDENTITY", "Invalid remote stream history identity.", 400);
  }
  const digest = createHash("sha256")
    .update("resonance-remote-stream-history-v1\n", "utf8")
    .update(origin, "utf8")
    .update("\n", "utf8")
    .update(profile, "utf8")
    .update("\n", "utf8")
    .update(song, "utf8")
    .digest("hex");
  return `remote-stream:${digest}`;
}

function serverStreamSongIsVideo(song) {
  const contentType = String(song?.content_type || "").split(";", 1)[0].trim().toLowerCase();
  if (contentType.startsWith("video/")) return true;
  return /\.(?:avi|mkv|mov|mp4|m4v|webm)$/i.test(String(song?.filename || song?.name || "").split(/[?#]/, 1)[0]);
}

function streamSessionIDFromURL(value) {
  if (typeof value !== "string"
      || value.length !== `${SERVER_STREAM_SCHEME}://media/`.length + 64) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== `${SERVER_STREAM_SCHEME}:`
        || url.hostname !== "media"
        || url.username
        || url.password
        || url.port
        || url.search
        || url.hash) return null;
    const match = /^\/([a-f0-9]{64})$/.exec(url.pathname);
    return match?.[1] || null;
  } catch {
    return null;
  }
}

function createExactLengthRelay(body, expectedLength, onDone = () => {}, onChunk = () => {}) {
  const length = Number(expectedLength);
  if (!body?.getReader || !Number.isSafeInteger(length) || length <= 0 || length > MAX_SERVER_MEDIA_BYTES) {
    fail("INVALID_STREAM_BODY", "The server returned an invalid stream body.");
  }
  const reader = body.getReader();
  let total = 0;
  let finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    try { reader.releaseLock(); } catch { /* already released */ }
    onDone();
  };
  return new ReadableStream({
    async pull(controller) {
      try {
        const { done, value } = await reader.read();
        if (done) {
          if (total !== length) fail("TRUNCATED_STREAM", "The streaming response ended before its declared length.");
          finish();
          controller.close();
          return;
        }
        total += value.byteLength;
        if (total > length) fail("OVERSIZED_STREAM", "The streaming response exceeded its declared length.");
        onChunk(value.byteLength);
        controller.enqueue(value);
      } catch (error) {
        await reader.cancel(error).catch(() => undefined);
        finish();
        controller.error(error);
      }
    },
    async cancel(reason) {
      await reader.cancel(reason).catch(() => undefined);
      finish();
    },
  });
}

module.exports = {
  SERVER_STREAM_SCHEME,
  ServerStreamValidationError,
  createExactLengthRelay,
  parseSingleByteRange,
  remoteStreamHistoryTrackID,
  serverStreamSongIsVideo,
  serverStreamURL,
  streamSessionIDFromURL,
  supportedMediaSize,
  validateStreamResponse,
};
