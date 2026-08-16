"use strict";

// Listen Along is deliberately a small, dependency-free contract module.  It
// is shared by the main process and tests so the renderer never has to repeat
// URL, room, revision, or clock validation.

const LISTEN_ALONG_SCHEMA_VERSION = 1;
const MAX_LISTEN_ALONG_SOURCE_LENGTH = 8_192;
const MAX_LISTEN_ALONG_CODE_LENGTH = 64;
const MAX_LISTEN_ALONG_POSITION_SECONDS = 7 * 24 * 60 * 60;
const LISTEN_ALONG_MEDIA_KINDS = new Set(["audio", "video"]);
const UNSAFE_MEDIA_HOSTS = [
  /(^|\.)googlevideo\.com$/i,
  /(^|\.)googleusercontent\.com$/i,
  /(^|\.)scdn\.co$/i,
  /(^|\.)sndcdn\.com$/i,
  /(^|\.)spotifycdn\.com$/i,
];

class ListenAlongValidationError extends Error {
  constructor(code, message, status = 400) {
    super(message);
    this.name = "ListenAlongValidationError";
    this.code = code;
    this.status = status;
  }
}

function boundedText(value, maximum) {
  if (typeof value !== "string") return null;
  const text = value.trim();
  if (!text || text.length > maximum || /[\u0000-\u001f\u007f]/.test(text)) return null;
  return text;
}

function canonicalListenAlongCode(value) {
  const code = boundedText(value, MAX_LISTEN_ALONG_CODE_LENGTH);
  if (!code || !/^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(code)) {
    throw new ListenAlongValidationError("INVALID_CODE", "Enter a valid Listen Along code.");
  }
  return code.toUpperCase();
}

function canonicalListenAlongSource(value, { allowNull = true } = {}) {
  if (value === null || value === undefined || value === "") {
    if (allowNull) return null;
    throw new ListenAlongValidationError("SOURCE_REQUIRED", "This track has no shareable source link.");
  }
  if (typeof value !== "string" || value.length > MAX_LISTEN_ALONG_SOURCE_LENGTH || value !== value.trim()) {
    throw new ListenAlongValidationError("INVALID_SOURCE", "The Listen Along source link is invalid.");
  }
  let url;
  try { url = new URL(value); }
  catch { throw new ListenAlongValidationError("INVALID_SOURCE", "The Listen Along source link is invalid."); }
  if (url.protocol !== "https:" || url.username || url.password || url.hash || !url.hostname) {
    throw new ListenAlongValidationError("INVALID_SOURCE", "Listen Along only accepts HTTPS source links without credentials.");
  }
  if (UNSAFE_MEDIA_HOSTS.some((pattern) => pattern.test(url.hostname))) {
    throw new ListenAlongValidationError("INVALID_SOURCE", "A temporary provider stream cannot be shared as a source link.");
  }
  const hostname = url.hostname.toLowerCase().replace(/\.$/, "");
  const privateIPv4 = /^\d{1,3}(?:\.\d{1,3}){3}$/.test(hostname)
    && hostname.split(".").map(Number).every((part) => part <= 255)
    && (() => {
      const [first, second] = hostname.split(".").map(Number);
      return first === 0 || first === 10 || first === 127 || (first === 169 && second === 254)
        || (first === 172 && second >= 16 && second <= 31)
        || (first === 192 && second === 168) || first >= 224;
    })();
  if (
    hostname === "localhost" || hostname.endsWith(".localhost") || hostname.endsWith(".local")
    || hostname.endsWith(".internal") || hostname.includes(":") || privateIPv4
  ) {
    throw new ListenAlongValidationError("INVALID_SOURCE", "Listen Along only accepts a public HTTPS source link.");
  }
  url.hash = "";
  return url.href;
}

function canonicalListenAlongMediaKind(value) {
  if (!LISTEN_ALONG_MEDIA_KINDS.has(value)) {
    throw new ListenAlongValidationError("INVALID_MEDIA_KIND", "Listen Along media kind must be audio or video.");
  }
  return value;
}

function canonicalListenAlongPosition(value) {
  const position = Number(value);
  if (!Number.isFinite(position) || position < 0 || position > MAX_LISTEN_ALONG_POSITION_SECONDS) {
    throw new ListenAlongValidationError("INVALID_POSITION", "Listen Along position is out of bounds.");
  }
  return Math.round(position * 1000) / 1000;
}

function canonicalListenAlongRevision(value, { fallback = 0 } = {}) {
  const revision = value === undefined || value === null || value === "" ? fallback : Number(value);
  if (!Number.isSafeInteger(revision) || revision < 0) {
    throw new ListenAlongValidationError("INVALID_REVISION", "Listen Along revision is invalid.");
  }
  return revision;
}

function canonicalListenAlongSnapshot(value, { sourceRequired = false } = {}) {
  const snapshot = value && typeof value === "object" && !Array.isArray(value) ? value : {};
  const sourceURL = canonicalListenAlongSource(snapshot.source_url ?? snapshot.sourceURL, { allowNull: !sourceRequired });
  const mediaKind = canonicalListenAlongMediaKind(snapshot.media_kind ?? snapshot.mediaKind ?? "audio");
  const result = Object.freeze({
    source_url: sourceURL,
    media_kind: mediaKind,
    position_seconds: canonicalListenAlongPosition(snapshot.position_seconds ?? snapshot.position ?? 0),
    is_playing: snapshot.is_playing === true || snapshot.isPlaying === true,
  });
  if (result.source_url === null && result.is_playing) {
    throw new ListenAlongValidationError("SOURCE_REQUIRED", "A source link is required while Listen Along is playing.");
  }
  return result;
}

function serverTimeMilliseconds(value, fallback = Date.now()) {
  if (typeof value === "number" && Number.isFinite(value)) {
    const milliseconds = value < 10_000_000_000 ? value * 1000 : value;
    if (Number.isFinite(milliseconds)) return milliseconds;
  }
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallback;
}

function canonicalListenAlongTimestamp(value, fallback = null) {
  if (value === null || value === undefined || value === "") return fallback;
  const milliseconds = serverTimeMilliseconds(value, NaN);
  if (!Number.isFinite(milliseconds)) return fallback;
  return new Date(milliseconds).toISOString();
}

function normalizeListenAlongResponse(payload, { role = null, fallbackCode = null, fallbackRevision = 0 } = {}) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new ListenAlongValidationError("INVALID_RESPONSE", "The server returned an invalid Listen Along response.", 502);
  }
  const rawCode = payload.formatted_code ?? payload.formattedCode ?? payload.code ?? fallbackCode;
  const code = canonicalListenAlongCode(rawCode);
  const responseRole = payload.role === "host" || payload.role === "guest" ? payload.role : role;
  if (!responseRole) throw new ListenAlongValidationError("INVALID_RESPONSE", "The server did not identify a Listen Along role.", 502);
  const rawSnapshot = payload.snapshot ?? payload.state ?? payload;
  const snapshot = canonicalListenAlongSnapshot(rawSnapshot);
  const revision = canonicalListenAlongRevision(payload.revision, { fallback: fallbackRevision });
  const schemaVersion = canonicalListenAlongRevision(payload.schema_version, { fallback: LISTEN_ALONG_SCHEMA_VERSION });
  if (schemaVersion !== LISTEN_ALONG_SCHEMA_VERSION) {
    throw new ListenAlongValidationError("UNSUPPORTED_SCHEMA", "This Listen Along server uses an unsupported protocol version.", 502);
  }
  const serverTime = canonicalListenAlongTimestamp(payload.server_time ?? payload.serverTime, new Date().toISOString());
  return Object.freeze({
    schema_version: schemaVersion,
    code,
    role: responseRole,
    revision,
    snapshot,
    updated_at: canonicalListenAlongTimestamp(payload.updated_at ?? payload.updatedAt),
    expires_at: canonicalListenAlongTimestamp(payload.expires_at ?? payload.expiresAt),
    server_time: serverTime,
    server_time_ms: serverTimeMilliseconds(serverTime),
  });
}

function projectListenAlongPosition(snapshot, serverTime, now = Date.now(), updatedAt = undefined) {
  const normalized = canonicalListenAlongSnapshot(snapshot);
  if (!normalized.is_playing) return normalized.position_seconds;
  const observedServerTime = serverTimeMilliseconds(serverTime, Number(now));
  const baseline = updatedAt === undefined ? observedServerTime : serverTimeMilliseconds(updatedAt, observedServerTime);
  const elapsed = updatedAt === undefined
    ? Math.max(0, (Number(now) - baseline) / 1000)
    : Math.max(0, (observedServerTime - baseline) / 1000);
  return canonicalListenAlongPosition(normalized.position_seconds + elapsed);
}

function isNewerListenAlongRevision(revision, previousRevision) {
  try {
    return canonicalListenAlongRevision(revision) > canonicalListenAlongRevision(previousRevision);
  } catch {
    return false;
  }
}

function publicListenAlongEvent(response, sessionID) {
  const normalized = normalizeListenAlongResponse(response, { role: response?.role || "guest" });
  return Object.freeze({
    session_id: boundedText(sessionID, 128),
    code: normalized.code,
    role: normalized.role,
    revision: normalized.revision,
    snapshot: normalized.snapshot,
    updated_at: normalized.updated_at,
    expires_at: normalized.expires_at,
    server_time: normalized.server_time,
    schema_version: normalized.schema_version,
  });
}

module.exports = {
  LISTEN_ALONG_SCHEMA_VERSION,
  MAX_LISTEN_ALONG_SOURCE_LENGTH,
  MAX_LISTEN_ALONG_CODE_LENGTH,
  ListenAlongValidationError,
  canonicalListenAlongCode,
  canonicalListenAlongSource,
  canonicalListenAlongMediaKind,
  canonicalListenAlongPosition,
  canonicalListenAlongRevision,
  canonicalListenAlongSnapshot,
  canonicalListenAlongTimestamp,
  normalizeListenAlongResponse,
  projectListenAlongPosition,
  isNewerListenAlongRevision,
  publicListenAlongEvent,
};
