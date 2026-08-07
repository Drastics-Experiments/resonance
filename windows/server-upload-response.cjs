const MAX_SERVER_UPLOAD_RESPONSE_BYTES = 256 * 1024;

class ServerUploadResponseError extends Error {
  constructor(message, status = 0) {
    super(message);
    this.name = "ServerUploadResponseError";
    this.status = status;
  }
}

function boundedText(value, maximum) {
  if (typeof value !== "string") return null;
  const text = value.trim();
  return text && text.length <= maximum && !/[\u0000-\u001f\u007f]/.test(text) ? text : null;
}

function sameOriginURL(value, serverOrigin) {
  if (value === undefined || value === null || value === "") return null;
  if (typeof value !== "string" || value.length > 2_048) {
    throw new ServerUploadResponseError("The server returned an invalid media URL.");
  }
  let url;
  try { url = new URL(value, `${serverOrigin}/`); }
  catch { throw new ServerUploadResponseError("The server returned an invalid media URL."); }
  if (!["http:", "https:"].includes(url.protocol)
      || url.origin !== serverOrigin
      || url.username
      || url.password
      || url.hash) {
    throw new ServerUploadResponseError("The server returned an unsafe media URL.");
  }
  return url.href;
}

function sanitizedUploadSong(value, serverOrigin) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ServerUploadResponseError("The server did not return an uploaded song object.");
  }
  const id = boundedText(value.id, 128);
  if (!id) throw new ServerUploadResponseError("The uploaded song is missing a valid id.");
  const filename = boundedText(value.filename || value.name, 500);
  const name = boundedText(value.name || value.filename, 500);
  const title = boundedText(value.title, 500) || name || filename || "Untitled song";
  const duration = Number(value.duration_seconds ?? value.duration);
  const size = Number(value.size);
  const sha256 = String(value.content_sha256 || value.sha256 || "").trim().toLowerCase();
  return {
    id,
    filename,
    name,
    title,
    artist: boundedText(value.artist, 500),
    album: boundedText(value.album, 500),
    size: Number.isSafeInteger(size) && size >= 0 ? size : 0,
    duration_seconds: Number.isFinite(duration) && duration >= 0 && duration <= 7 * 24 * 60 * 60
      ? duration
      : null,
    content_sha256: /^[a-f0-9]{64}$/.test(sha256) ? sha256 : null,
    content_type: boundedText(value.content_type, 128),
    modified_at: boundedText(value.modified_at, 128),
    modified_utc: boundedText(value.modified_utc, 128),
    download_url: sameOriginURL(value.download_url, serverOrigin),
    stream_url: sameOriginURL(value.stream_url, serverOrigin),
    artwork_url: sameOriginURL(value.artwork_url, serverOrigin),
  };
}

async function responseBytesWithLimit(response, maximumBytes = MAX_SERVER_UPLOAD_RESPONSE_BYTES) {
  const declaredLength = Number(response.headers?.get?.("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > maximumBytes) {
    await response.body?.cancel?.().catch(() => undefined);
    throw new ServerUploadResponseError("The server upload response was too large.", response.status);
  }
  const reader = response.body?.getReader?.();
  if (!reader) return Buffer.alloc(0);
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maximumBytes) {
        await reader.cancel().catch(() => undefined);
        throw new ServerUploadResponseError("The server upload response was too large.", response.status);
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    reader.releaseLock();
  }
  return Buffer.concat(chunks, total);
}

async function readServerUploadResponse(response, options = {}) {
  const serverOrigin = new URL(options.serverOrigin).origin;
  const rawBody = await responseBytesWithLimit(response);
  const contentType = String(response.headers?.get?.("content-type") || "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
  const jsonContent = contentType === "application/json" || /^application\/[a-z0-9.+-]+\+json$/.test(contentType);
  let payload = null;
  if (jsonContent && rawBody.length) {
    try { payload = JSON.parse(rawBody.toString("utf8")); }
    catch { throw new ServerUploadResponseError("The server returned malformed upload JSON.", response.status); }
  }
  if (response.status !== 201 && response.status !== 409) {
    const detail = boundedText(payload?.error, 500);
    throw new ServerUploadResponseError(
      `Server returned HTTP ${response.status}${detail ? `: ${detail}` : ""}`,
      response.status,
    );
  }
  if (!jsonContent || !rawBody.length) {
    throw new ServerUploadResponseError("The server upload response was not JSON.", response.status);
  }
  const songValue = response.status === 409 ? payload?.duplicate_of : payload;
  if (response.status === 409 && (!payload || typeof payload !== "object" || Array.isArray(payload))) {
    throw new ServerUploadResponseError("The duplicate upload response was invalid.", response.status);
  }
  return {
    status: response.status,
    duplicate: response.status === 409,
    song: sanitizedUploadSong(songValue, serverOrigin),
  };
}

module.exports = {
  MAX_SERVER_UPLOAD_RESPONSE_BYTES,
  ServerUploadResponseError,
  readServerUploadResponse,
  sanitizedUploadSong,
};
