const { createHash, createHmac, timingSafeEqual } = require("node:crypto");

const CLIENT_CONFIG_PROTOCOL_VERSION = 1;
const CLIENT_CONFIG_PLATFORM = "windows";
const CLIENT_CONFIG_COHORT_BUCKETS = 10_000;
const CLIENT_CONFIG_MAX_TTL_MS = 15 * 60 * 1_000;
const CLIENT_CONFIG_MAX_BYTES = 128 * 1_024;

const CLIENT_CONFIG_REQUEST_HEADER_NAMES = Object.freeze({
  protocol: "X-Resonance-Config-Protocol",
  platform: "X-Resonance-Client-Platform",
  appVersion: "X-Resonance-App-Version",
  appBuild: "X-Resonance-App-Build",
  cohortKey: "X-Resonance-Cohort-Key",
});

const CLIENT_CONFIG_RESPONSE_HEADER_NAMES = Object.freeze({
  contentDigest: "Content-Digest",
  signature: "X-Resonance-Config-Signature",
  etag: "ETag",
});

const SAFE_VALUES = Object.freeze({
  "upload.local_file": true,
  "upload.server_source_link": false,
  "upload.reviewed_match": false,
  "upload.external_object": false,
  "download.offline_mode": "verified_file_cache",
  "download.playback_mode": "same_origin_resolver",
  "matcher.mode": "off",
  "storage.read_mode": "r2_only",
  "storage.r2_reclaim": false,
});

const SAFE_KILL_SWITCHES = Object.freeze({
  all_uploads: false,
  link_imports: true,
  offline_downloads: false,
  external_reads: true,
  r2_reclaim: true,
});

class ClientConfigVerificationError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "ClientConfigVerificationError";
    this.code = code;
  }
}

function deepFreeze(value) {
  if (!value || typeof value !== "object" || Object.isFrozen(value)) return value;
  for (const child of Object.values(value)) deepFreeze(child);
  return Object.freeze(value);
}

function fail(code, message) {
  throw new ClientConfigVerificationError(code, message);
}

function requireNonEmptyString(value, name) {
  if (typeof value !== "string" || !value || value !== value.trim()) {
    fail("INVALID_CONTEXT", `${name} must be a non-empty string without surrounding whitespace.`);
  }
  return value;
}

function canonicalOrigin(value) {
  let url;
  try {
    url = new URL(requireNonEmptyString(value, "origin"));
  } catch (error) {
    if (error instanceof ClientConfigVerificationError) throw error;
    fail("INVALID_CONTEXT", "origin must be an absolute HTTP(S) URL.");
  }
  if (!url || (url.protocol !== "https:" && url.protocol !== "http:")) {
    fail("INVALID_CONTEXT", "origin must use HTTP or HTTPS.");
  }
  if (url.username || url.password) fail("INVALID_CONTEXT", "origin must not contain credentials.");
  return url.origin;
}

function positiveBuild(value) {
  const build = typeof value === "string" && /^\d+$/.test(value) ? Number(value) : value;
  if (!Number.isSafeInteger(build) || build <= 0) {
    fail("INVALID_CONTEXT", "appBuild must be a positive integer.");
  }
  return build;
}

function canonicalCohortKey(value) {
  const key = requireNonEmptyString(value, "cohortKey");
  if (!/^[A-Za-z0-9_-]{22}$/.test(key)) {
    fail("INVALID_CONTEXT", "cohortKey must be an unpadded base64url-encoded 128-bit value.");
  }
  const bytes = Buffer.from(key, "base64url");
  if (bytes.length !== 16 || bytes.toString("base64url") !== key) {
    fail("INVALID_CONTEXT", "cohortKey must be an unpadded base64url-encoded 128-bit value.");
  }
  return key;
}

function deriveCohortBucket(cohortKey) {
  const key = canonicalCohortKey(cohortKey);
  const digest = createHash("sha256")
    .update(`resonance-client-config-cohort-v1\n${key}`, "utf8")
    .digest();
  return digest.readUInt32BE(0) % CLIENT_CONFIG_COHORT_BUCKETS;
}

function clientConfigRequestContext({ origin, profileID, appVersion, appBuild, cohortKey }) {
  const stableCohortKey = canonicalCohortKey(cohortKey);
  const expected = {
    origin: canonicalOrigin(origin),
    profile_id: requireNonEmptyString(profileID, "profileID"),
    platform: CLIENT_CONFIG_PLATFORM,
    app_version: requireNonEmptyString(appVersion, "appVersion"),
    app_build: positiveBuild(appBuild),
    cohort_bucket: deriveCohortBucket(stableCohortKey),
    cohort_key: stableCohortKey,
  };
  expected.request_headers = Object.freeze({
    [CLIENT_CONFIG_REQUEST_HEADER_NAMES.protocol]: String(CLIENT_CONFIG_PROTOCOL_VERSION),
    [CLIENT_CONFIG_REQUEST_HEADER_NAMES.platform]: expected.platform,
    [CLIENT_CONFIG_REQUEST_HEADER_NAMES.appVersion]: expected.app_version,
    [CLIENT_CONFIG_REQUEST_HEADER_NAMES.appBuild]: String(expected.app_build),
    [CLIENT_CONFIG_REQUEST_HEADER_NAMES.cohortKey]: stableCohortKey,
  });
  return deepFreeze(expected);
}

function audienceFromExpected(expected) {
  if (!expected || typeof expected !== "object") fail("INVALID_CONTEXT", "Expected audience is required.");
  const cohortBucket = expected.cohort_bucket;
  if (!Number.isSafeInteger(cohortBucket) || cohortBucket < 0 || cohortBucket >= CLIENT_CONFIG_COHORT_BUCKETS) {
    fail("INVALID_CONTEXT", "cohort_bucket must be an integer from 0 through 9999.");
  }
  return {
    origin: canonicalOrigin(expected.origin),
    profile_id: requireNonEmptyString(expected.profile_id, "profile_id"),
    platform: requireNonEmptyString(expected.platform, "platform"),
    app_version: requireNonEmptyString(expected.app_version, "app_version"),
    app_build: positiveBuild(expected.app_build),
    cohort_bucket: cohortBucket,
  };
}

function strictInstant(value, field) {
  if (typeof value !== "string") fail("INVALID_TIME", `${field} must be a UTC RFC 3339 timestamp.`);
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$/.exec(value);
  if (!match) fail("INVALID_TIME", `${field} must be a UTC RFC 3339 timestamp.`);
  const [, year, month, day, hour, minute, second, fraction = ""] = match;
  const milliseconds = Number(fraction.padEnd(3, "0"));
  const timestamp = Date.UTC(
    Number(year), Number(month) - 1, Number(day), Number(hour), Number(minute), Number(second), milliseconds,
  );
  const date = new Date(timestamp);
  if (
    date.getUTCFullYear() !== Number(year)
    || date.getUTCMonth() !== Number(month) - 1
    || date.getUTCDate() !== Number(day)
    || date.getUTCHours() !== Number(hour)
    || date.getUTCMinutes() !== Number(minute)
    || date.getUTCSeconds() !== Number(second)
    || date.getUTCMilliseconds() !== milliseconds
  ) {
    fail("INVALID_TIME", `${field} is not a real UTC timestamp.`);
  }
  return timestamp;
}

function nowMilliseconds(now) {
  if (typeof now === "string") return strictInstant(now, "now");
  const value = now instanceof Date ? now.getTime() : Number(now ?? Date.now());
  if (!Number.isFinite(value)) fail("INVALID_TIME", "now must be a valid Date or millisecond timestamp.");
  return value;
}

function rawBytes(rawBody) {
  const body = Buffer.isBuffer(rawBody)
    ? Buffer.from(rawBody)
    : ArrayBuffer.isView(rawBody)
      ? Buffer.from(rawBody.buffer, rawBody.byteOffset, rawBody.byteLength)
      : typeof rawBody === "string"
        ? Buffer.from(rawBody, "utf8")
        : null;
  if (!body || body.length === 0 || body.length > CLIENT_CONFIG_MAX_BYTES) {
    fail("INVALID_BODY", `Client config must contain 1 to ${CLIENT_CONFIG_MAX_BYTES} bytes.`);
  }
  return body;
}

function exactBase64(value, expression, field, expectedBytes) {
  if (typeof value !== "string") fail("INVALID_HEADER", `${field} is missing.`);
  const match = expression.exec(value);
  if (!match) fail("INVALID_HEADER", `${field} has an invalid format.`);
  const encoded = match[1];
  if (encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) {
    fail("INVALID_HEADER", `${field} is not canonical standard base64.`);
  }
  const decoded = Buffer.from(encoded, "base64");
  if (decoded.length !== expectedBytes || decoded.toString("base64") !== encoded) {
    fail("INVALID_HEADER", `${field} has an invalid encoded length.`);
  }
  return decoded;
}

function contentDigestForBody(rawBody) {
  const body = rawBytes(rawBody);
  return `sha-256=:${createHash("sha256").update(body).digest("base64")}:`;
}

function signatureInput(audience, contentDigest) {
  if (!audience || typeof audience !== "object") fail("INVALID_CONTEXT", "Signature audience is required.");
  const origin = requireNonEmptyString(audience.origin, "audience.origin");
  const profileID = requireNonEmptyString(audience.profile_id, "audience.profile_id");
  const platform = requireNonEmptyString(audience.platform, "audience.platform");
  const appBuild = positiveBuild(audience.app_build);
  if (typeof contentDigest !== "string") fail("INVALID_HEADER", "Content-Digest is required.");
  return [
    "resonance-client-config-v1",
    origin,
    profileID,
    platform,
    String(appBuild),
    contentDigest,
  ].join("\n");
}

function signatureForBody({ audience, contentDigest, token }) {
  const secret = requireNonEmptyString(token, "token");
  return `v1=:${createHmac("sha256", Buffer.from(secret, "utf8"))
    .update(signatureInput(audience, contentDigest), "utf8")
    .digest("base64")}:`;
}

function exactBoolean(object, key, group) {
  if (typeof object?.[key] !== "boolean") fail("INVALID_CONFIG", `${group}.${key} must be a boolean.`);
  return object[key];
}

function exactEnum(object, key, values, group) {
  const value = object?.[key];
  if (!values.includes(value)) {
    fail("INVALID_CONFIG", `${group}.${key} must be one of: ${values.join(", ")}.`);
  }
  return value;
}

function normalizePayload(payload, expected, now) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    fail("INVALID_CONFIG", "Client config must be a JSON object.");
  }
  if (payload.schema_version !== CLIENT_CONFIG_PROTOCOL_VERSION) {
    fail("UNSUPPORTED_SCHEMA", `Unsupported client config schema ${String(payload.schema_version)}.`);
  }
  if (!Number.isSafeInteger(payload.revision) || payload.revision < 0) {
    fail("INVALID_CONFIG", "revision must be a non-negative integer.");
  }

  const issuedAt = strictInstant(payload.issued_at, "issued_at");
  const notBefore = strictInstant(payload.not_before, "not_before");
  const expiresAt = strictInstant(payload.expires_at, "expires_at");
  const current = nowMilliseconds(now);
  if (issuedAt > notBefore || notBefore >= expiresAt || expiresAt - issuedAt > CLIENT_CONFIG_MAX_TTL_MS) {
    fail("INVALID_TIME", "Client config time bounds are invalid or exceed 15 minutes.");
  }
  if (issuedAt > current || current < notBefore || current >= expiresAt) {
    fail("INACTIVE_CONFIG", "Client config is not currently active.");
  }

  const expectedAudience = audienceFromExpected(expected);
  const actualAudience = payload.audience;
  if (!actualAudience || typeof actualAudience !== "object" || Array.isArray(actualAudience)) {
    fail("AUDIENCE_MISMATCH", "Client config audience is missing.");
  }
  for (const key of ["origin", "profile_id", "platform", "app_version", "app_build", "cohort_bucket"]) {
    if (actualAudience[key] !== expectedAudience[key]) {
      fail("AUDIENCE_MISMATCH", `Client config audience ${key} does not match this client.`);
    }
  }
  if (actualAudience.origin !== canonicalOrigin(actualAudience.origin)) {
    fail("AUDIENCE_MISMATCH", "Client config audience origin is not canonical.");
  }

  const values = {
    "upload.local_file": exactBoolean(payload.values, "upload.local_file", "values"),
    "upload.server_source_link": exactBoolean(payload.values, "upload.server_source_link", "values"),
    "upload.reviewed_match": exactBoolean(payload.values, "upload.reviewed_match", "values"),
    "upload.external_object": exactBoolean(payload.values, "upload.external_object", "values"),
    "download.offline_mode": exactEnum(
      payload.values, "download.offline_mode", ["verified_file_cache", "stream_only"], "values",
    ),
    "download.playback_mode": exactEnum(
      payload.values, "download.playback_mode", ["same_origin_resolver"], "values",
    ),
    "matcher.mode": exactEnum(payload.values, "matcher.mode", ["off", "shadow", "review"], "values"),
    "storage.read_mode": exactEnum(
      payload.values, "storage.read_mode", ["r2_only", "external_with_r2_fallback"], "values",
    ),
    "storage.r2_reclaim": exactBoolean(payload.values, "storage.r2_reclaim", "values"),
  };
  if (values["upload.external_object"] !== false || values["storage.r2_reclaim"] !== false) {
    fail("UNSAFE_CONFIG", "External-object upload and R2 reclaim are not supported by protocol v1.");
  }

  const killSwitches = {
    all_uploads: exactBoolean(payload.kill_switches, "all_uploads", "kill_switches"),
    link_imports: exactBoolean(payload.kill_switches, "link_imports", "kill_switches"),
    offline_downloads: exactBoolean(payload.kill_switches, "offline_downloads", "kill_switches"),
    external_reads: exactBoolean(payload.kill_switches, "external_reads", "kill_switches"),
    r2_reclaim: exactBoolean(payload.kill_switches, "r2_reclaim", "kill_switches"),
  };

  const normalized = {
    schema_version: CLIENT_CONFIG_PROTOCOL_VERSION,
    revision: payload.revision,
    issued_at: payload.issued_at,
    not_before: payload.not_before,
    expires_at: payload.expires_at,
    audience: expectedAudience,
    values,
    kill_switches: killSwitches,
    verified: true,
    source: "network",
  };
  normalized.effective = resolveClientConfigModes(normalized);
  return deepFreeze(normalized);
}

function verifyClientConfigResponse({ rawBody, contentDigest, signature, token, expected, now = Date.now(), etag }) {
  const body = rawBytes(rawBody);
  const suppliedDigest = exactBase64(
    contentDigest, /^sha-256=:([A-Za-z0-9+/]+={0,2}):$/, "Content-Digest", 32,
  );
  const actualDigest = createHash("sha256").update(body).digest();
  if (!timingSafeEqual(suppliedDigest, actualDigest)) fail("DIGEST_MISMATCH", "Client config digest does not match its body.");

  let payload;
  try {
    payload = JSON.parse(body.toString("utf8"));
  } catch {
    fail("INVALID_BODY", "Client config body is not valid UTF-8 JSON.");
  }
  if (!payload?.audience || typeof payload.audience !== "object") {
    fail("INVALID_CONFIG", "Client config audience is missing.");
  }

  const suppliedSignature = exactBase64(
    signature, /^v1=:([A-Za-z0-9+/]+={0,2}):$/, "X-Resonance-Config-Signature", 32,
  );
  const secret = requireNonEmptyString(token, "token");
  const expectedSignature = createHmac("sha256", Buffer.from(secret, "utf8"))
    .update(signatureInput(payload.audience, contentDigest), "utf8")
    .digest();
  if (!timingSafeEqual(suppliedSignature, expectedSignature)) {
    fail("SIGNATURE_MISMATCH", "Client config signature is invalid.");
  }

  const config = normalizePayload(payload, expected, now);
  if (etag !== undefined && etag !== `"fflags-r${config.revision}"`) {
    fail("ETAG_MISMATCH", "Client config ETag does not match its signed revision.");
  }
  return config;
}

function resolveClientConfigModes(config) {
  const values = config?.values || SAFE_VALUES;
  const kills = config?.kill_switches || SAFE_KILL_SWITCHES;
  const uploadsDisabled = kills.all_uploads === true;
  const linksDisabled = uploadsDisabled || kills.link_imports === true;
  const uploadModes = {
    local_file: !uploadsDisabled && values["upload.local_file"] === true,
    server_source_link: !linksDisabled && values["upload.server_source_link"] === true,
    reviewed_match: !uploadsDisabled
      && values["upload.local_file"] === true
      && values["upload.reviewed_match"] === true
      && values["matcher.mode"] === "review",
    external_object: false,
  };
  const availableUploadModes = Object.entries(uploadModes)
    .filter(([, available]) => available)
    .map(([mode]) => mode);
  const offlineMode = kills.offline_downloads === true
    ? "stream_only"
    : values["download.offline_mode"] === "stream_only"
      ? "stream_only"
      : "verified_file_cache";
  const matcherMode = uploadsDisabled ? "off" : ["shadow", "review"].includes(values["matcher.mode"])
    ? values["matcher.mode"]
    : "off";
  const storageReadMode = "r2_only";

  return deepFreeze({
    upload_modes: uploadModes,
    available_upload_modes: availableUploadModes,
    default_upload_mode: uploadModes.local_file ? "local_file" : availableUploadModes[0] || null,
    download_offline_mode: offlineMode,
    download_playback_mode: "same_origin_resolver",
    matcher_mode: matcherMode,
    storage_read_mode: storageReadMode,
    r2_reclaim: false,
  });
}

const SAFE_CLIENT_CONFIG = deepFreeze({
  schema_version: CLIENT_CONFIG_PROTOCOL_VERSION,
  revision: 0,
  values: SAFE_VALUES,
  kill_switches: SAFE_KILL_SWITCHES,
  verified: false,
  source: "safe_defaults",
  effective: resolveClientConfigModes({ values: SAFE_VALUES, kill_switches: SAFE_KILL_SWITCHES }),
});

function safeClientConfig(expected) {
  return deepFreeze({
    ...SAFE_CLIENT_CONFIG,
    audience: expected ? audienceFromExpected(expected) : undefined,
  });
}

function tokenFingerprint(token) {
  const secret = requireNonEmptyString(token, "token");
  return `sha256:${createHash("sha256").update(secret, "utf8").digest("base64url")}`;
}

function configCacheKey(expected, token) {
  const audience = audienceFromExpected(expected);
  const scope = [
    "resonance-client-config-cache-v1",
    audience.origin,
    audience.profile_id,
    audience.platform,
    audience.app_version,
    String(audience.app_build),
    String(audience.cohort_bucket),
    tokenFingerprint(token),
  ].join("\n");
  return `client-config-v1-${createHash("sha256").update(scope, "utf8").digest("hex")}`;
}

function createClientConfigCacheRecord({
  rawBody,
  contentDigest,
  signature,
  expected,
  token,
  storedAt = Date.now(),
  etag,
  highestRevision,
}) {
  const body = rawBytes(rawBody);
  const stored = nowMilliseconds(storedAt);
  let bodyRevision = 0;
  try {
    const parsed = JSON.parse(body.toString("utf8"));
    if (Number.isSafeInteger(parsed?.revision) && parsed.revision >= 0) bodyRevision = parsed.revision;
  } catch {
    // Signature verification rejects invalid JSON before production callers cache it.
  }
  const record = {
    cache_version: 1,
    cache_key: configCacheKey(expected, token),
    stored_at: new Date(stored).toISOString(),
    raw_body_base64: body.toString("base64"),
    content_digest: contentDigest,
    signature,
    highest_revision: Math.max(
      bodyRevision,
      Number.isSafeInteger(highestRevision) && highestRevision >= 0 ? highestRevision : 0,
    ),
  };
  if (etag !== undefined) record.etag = etag;
  return deepFreeze(record);
}

function monotonicClientConfigRevision(config, record) {
  if (!config || config.verified !== true || !Number.isSafeInteger(config.revision) || config.revision < 0) {
    fail("INVALID_CONFIG", "A verified client config revision is required.");
  }
  const highest = Number.isSafeInteger(record) && record >= 0
    ? record
    : Number.isSafeInteger(record?.highest_revision) && record.highest_revision >= 0
      ? record.highest_revision
      : 0;
  if (config.revision < highest) {
    fail("REVISION_ROLLBACK", "Client config revision rollback is not allowed for this cache scope.");
  }
  return Math.max(config.revision, highest);
}

function decodeCachedBody(value) {
  if (typeof value !== "string" || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) return null;
  const body = Buffer.from(value, "base64");
  if (!body.length || body.length > CLIENT_CONFIG_MAX_BYTES || body.toString("base64") !== value) return null;
  return body;
}

function validCachedClientConfig(record, { expected, token, now = Date.now() }) {
  try {
    if (!record || typeof record !== "object" || Array.isArray(record) || record.cache_version !== 1) return null;
    if (record.cache_key !== configCacheKey(expected, token)) return null;
    const current = nowMilliseconds(now);
    const stored = strictInstant(record.stored_at, "stored_at");
    if (stored > current || current - stored > CLIENT_CONFIG_MAX_TTL_MS) return null;
    const body = decodeCachedBody(record.raw_body_base64);
    if (!body) return null;
    const config = verifyClientConfigResponse({
      rawBody: body,
      contentDigest: record.content_digest,
      signature: record.signature,
      token,
      expected,
      now: current,
      etag: record.etag,
    });
    return deepFreeze({ ...config, source: "cache" });
  } catch {
    return null;
  }
}

function resolveSameOriginURL(candidate, serverOrigin) {
  let origin;
  let url;
  try {
    origin = canonicalOrigin(serverOrigin);
    url = new URL(requireNonEmptyString(candidate, "candidate"), `${origin}/`);
  } catch {
    return null;
  }
  if (
    url.origin !== origin
    || (url.protocol !== "https:" && url.protocol !== "http:")
    || url.username
    || url.password
    || url.hash
  ) return null;
  return url.href;
}

function sameOriginBearerHeaders(candidate, serverOrigin, token) {
  const resolvedURL = resolveSameOriginURL(candidate, serverOrigin);
  if (!resolvedURL) return null;
  try {
    return deepFreeze({
      url: resolvedURL,
      headers: Object.freeze({ Authorization: `Bearer ${requireNonEmptyString(token, "token")}` }),
    });
  } catch {
    return null;
  }
}

module.exports = {
  CLIENT_CONFIG_COHORT_BUCKETS,
  CLIENT_CONFIG_MAX_BYTES,
  CLIENT_CONFIG_MAX_TTL_MS,
  CLIENT_CONFIG_PLATFORM,
  CLIENT_CONFIG_PROTOCOL_VERSION,
  CLIENT_CONFIG_REQUEST_HEADER_NAMES,
  CLIENT_CONFIG_RESPONSE_HEADER_NAMES,
  ClientConfigVerificationError,
  SAFE_CLIENT_CONFIG,
  clientConfigRequestContext,
  configCacheKey,
  contentDigestForBody,
  createClientConfigCacheRecord,
  deriveCohortBucket,
  monotonicClientConfigRevision,
  resolveClientConfigModes,
  resolveSameOriginURL,
  safeClientConfig,
  sameOriginBearerHeaders,
  signatureForBody,
  signatureInput,
  tokenFingerprint,
  validCachedClientConfig,
  verifyClientConfigResponse,
};
