import assert from "node:assert/strict";
import { createHash, createHmac } from "node:crypto";
import test from "node:test";
import clientConfig from "../client-config.cjs";

const {
  CLIENT_CONFIG_MAX_TTL_MS,
  CLIENT_CONFIG_REQUEST_HEADER_NAMES,
  ClientConfigVerificationError,
  SAFE_CLIENT_CONFIG,
  clientConfigRequestContext,
  configCacheKey,
  createClientConfigCacheRecord,
  deriveCohortBucket,
  monotonicClientConfigRevision,
  resolveClientConfigModes,
  resolveSameOriginURL,
  sameOriginBearerHeaders,
  tokenFingerprint,
  validCachedClientConfig,
  verifyClientConfigResponse,
} = clientConfig;

const TOKEN = "access-token-for-tests";
const COHORT_KEY = "ABEiM0RVZneImaq7zN3u_w";
const NOW = new Date("2026-08-06T18:00:00.000Z");

function expectedContext(overrides = {}) {
  return clientConfigRequestContext({
    origin: "https://music.example.test/library",
    profileID: "listener-a",
    appVersion: "1.1.4",
    appBuild: 17,
    cohortKey: COHORT_KEY,
    ...overrides,
  });
}

function basePayload(expected = expectedContext()) {
  return {
    schema_version: 1,
    revision: 23,
    issued_at: "2026-08-06T17:55:00.000Z",
    not_before: "2026-08-06T17:55:00.000Z",
    expires_at: "2026-08-06T18:05:00.000Z",
    audience: {
      origin: expected.origin,
      profile_id: expected.profile_id,
      platform: expected.platform,
      app_version: expected.app_version,
      app_build: expected.app_build,
      cohort_bucket: expected.cohort_bucket,
    },
    values: {
      "upload.local_file": true,
      "upload.server_source_link": true,
      "upload.reviewed_match": true,
      "upload.external_object": false,
      "download.offline_mode": "verified_file_cache",
      "download.playback_mode": "same_origin_resolver",
      "matcher.mode": "review",
      "storage.read_mode": "r2_only",
      "storage.r2_reclaim": false,
    },
    kill_switches: {
      all_uploads: false,
      link_imports: false,
      offline_downloads: false,
      external_reads: false,
      r2_reclaim: true,
    },
  };
}

function signPayload(payload, token = TOKEN) {
  const rawBody = Buffer.from(JSON.stringify(payload), "utf8");
  const contentDigest = `sha-256=:${createHash("sha256").update(rawBody).digest("base64")}:`;
  const signatureInput = [
    "resonance-client-config-v1",
    payload.audience.origin,
    payload.audience.profile_id,
    payload.audience.platform,
    String(payload.audience.app_build),
    contentDigest,
  ].join("\n");
  const signature = `v1=:${createHmac("sha256", Buffer.from(token, "utf8"))
    .update(signatureInput, "utf8")
    .digest("base64")}:`;
  return { rawBody, contentDigest, signature, token };
}

function verify(payload, options = {}) {
  const signed = signPayload(payload, options.signingToken || TOKEN);
  return verifyClientConfigResponse({
    ...signed,
    token: options.token || TOKEN,
    expected: options.expected || expectedContext(),
    now: options.now || NOW,
    etag: options.etag,
  });
}

test("builds the exact Windows request context and stable 10,000-bucket cohort", () => {
  const expected = expectedContext();
  assert.equal(expected.origin, "https://music.example.test");
  assert.equal(expected.platform, "windows");
  assert.equal(expected.cohort_bucket, 8512);
  assert.equal(deriveCohortBucket(COHORT_KEY), 8512);
  assert.deepEqual(expected.request_headers, {
    "X-Resonance-Config-Protocol": "1",
    "X-Resonance-Client-Platform": "windows",
    "X-Resonance-App-Version": "1.1.4",
    "X-Resonance-App-Build": "17",
    "X-Resonance-Cohort-Key": COHORT_KEY,
  });
  assert.equal(CLIENT_CONFIG_REQUEST_HEADER_NAMES.platform, "X-Resonance-Client-Platform");
  assert.throws(
    () => expectedContext({ cohortKey: "not-a-canonical-key" }),
    /base64url-encoded 128-bit/i,
  );
  assert.throws(() => expectedContext({ appBuild: 0 }), /positive integer/i);
});

test("safe defaults keep only legacy verified file transfers enabled", () => {
  assert.equal(SAFE_CLIENT_CONFIG.verified, false);
  assert.deepEqual(SAFE_CLIENT_CONFIG.effective.available_upload_modes, ["local_file"]);
  assert.equal(SAFE_CLIENT_CONFIG.effective.download_offline_mode, "verified_file_cache");
  assert.equal(SAFE_CLIENT_CONFIG.effective.download_playback_mode, "same_origin_resolver");
  assert.equal(SAFE_CLIENT_CONFIG.effective.matcher_mode, "off");
  assert.equal(SAFE_CLIENT_CONFIG.effective.storage_read_mode, "r2_only");
  assert.equal(SAFE_CLIENT_CONFIG.effective.r2_reclaim, false);
  assert.equal(SAFE_CLIENT_CONFIG.kill_switches.link_imports, true);
  assert.equal(SAFE_CLIENT_CONFIG.kill_switches.external_reads, true);
  assert.equal(SAFE_CLIENT_CONFIG.kill_switches.r2_reclaim, true);
});

test("verifies exact digest, HMAC, audience, revision ETag, schema, and enums", () => {
  const payload = basePayload();
  payload.ignored_future_field = { allowed: true };
  payload.values["future.value"] = "ignored";
  const config = verify(payload, { etag: '"fflags-r23"' });
  assert.equal(config.verified, true);
  assert.equal(config.revision, 23);
  assert.equal(config.values["future.value"], undefined);
  assert.deepEqual(config.effective.available_upload_modes, ["local_file", "server_source_link", "reviewed_match"]);
  assert.equal(config.effective.matcher_mode, "review");
  assert.equal(config.effective.storage_read_mode, "r2_only");
  const noLocalFilePayload = basePayload();
  noLocalFilePayload.values["upload.local_file"] = false;
  assert.deepEqual(
    verify(noLocalFilePayload).effective.available_upload_modes,
    ["server_source_link"],
    "Windows must not offer reviewed-match upload when its verified-byte upload route is disabled",
  );
  assert.throws(() => verify(payload, { etag: '"fflags-r22"' }), (error) => {
    assert.equal(error.code, "ETAG_MISMATCH");
    return true;
  });
});

test("rejects body tampering, signature tampering, a different token, and noncanonical headers", () => {
  const payload = basePayload();
  const signed = signPayload(payload);
  assert.throws(() => verifyClientConfigResponse({
    ...signed,
    rawBody: Buffer.concat([signed.rawBody, Buffer.from(" ")]),
    expected: expectedContext(),
    now: NOW,
  }), /digest does not match/i);
  assert.throws(() => verifyClientConfigResponse({
    ...signed,
    signature: signed.signature.replace(/^v1=:/, "v2=:") ,
    expected: expectedContext(),
    now: NOW,
  }), /invalid format/i);
  assert.throws(() => verifyClientConfigResponse({
    ...signed,
    token: "different-token",
    expected: expectedContext(),
    now: NOW,
  }), /signature is invalid/i);
  assert.throws(() => verifyClientConfigResponse({
    ...signed,
    contentDigest: signed.contentDigest.replace("=:", ":"),
    expected: expectedContext(),
    now: NOW,
  }), /invalid format/i);
});

test("rejects every audience mismatch and signs the raw audience origin", () => {
  const expected = expectedContext();
  for (const [field, value] of [
    ["origin", "https://other.example.test"],
    ["profile_id", "listener-b"],
    ["platform", "macos"],
    ["app_version", "1.1.5"],
    ["app_build", 18],
    ["cohort_bucket", (expected.cohort_bucket + 1) % 10_000],
  ]) {
    const payload = basePayload(expected);
    payload.audience[field] = value;
    assert.throws(() => verify(payload), (error) => {
      assert.equal(error.code, "AUDIENCE_MISMATCH", field);
      return true;
    });
  }

  const noncanonical = basePayload(expected);
  noncanonical.audience.origin = `${expected.origin}/`;
  assert.throws(() => verify(noncanonical), /audience origin/i);
});

test("rejects expired, future, malformed, and overlong config time windows", () => {
  const expired = basePayload();
  expired.expires_at = "2026-08-06T18:00:00.000Z";
  assert.throws(() => verify(expired), (error) => error.code === "INACTIVE_CONFIG");

  const future = basePayload();
  future.issued_at = "2026-08-06T18:01:00.000Z";
  future.not_before = "2026-08-06T18:01:00.000Z";
  future.expires_at = "2026-08-06T18:05:00.000Z";
  assert.throws(() => verify(future), (error) => error.code === "INACTIVE_CONFIG");

  const tooLong = basePayload();
  tooLong.issued_at = "2026-08-06T17:49:59.999Z";
  assert.ok(Date.parse(tooLong.expires_at) - Date.parse(tooLong.issued_at) > CLIENT_CONFIG_MAX_TTL_MS);
  assert.throws(() => verify(tooLong), /exceed 15 minutes/i);

  const impossible = basePayload();
  impossible.issued_at = "2026-02-30T17:55:00.000Z";
  assert.throws(() => verify(impossible), /not a real UTC timestamp/i);
});

test("rejects unknown schemas, unknown enum cases, missing booleans, and unsafe reserved modes", () => {
  const schema = basePayload();
  schema.schema_version = 2;
  assert.throws(() => verify(schema), (error) => error.code === "UNSUPPORTED_SCHEMA");

  const enumPayload = basePayload();
  enumPayload.values["download.offline_mode"] = "unverified_external_file";
  assert.throws(() => verify(enumPayload), /verified_file_cache, stream_only/i);

  const externalStorage = basePayload();
  externalStorage.values["storage.read_mode"] = "external_with_r2_fallback";
  const parsedExternalStorage = verify(externalStorage);
  assert.equal(parsedExternalStorage.values["storage.read_mode"], "external_with_r2_fallback");
  assert.equal(
    parsedExternalStorage.effective.storage_read_mode,
    "r2_only",
    "Windows parses the complete v1 enum but keeps unsupported external reads safety-gated",
  );

  const missing = basePayload();
  delete missing.kill_switches.external_reads;
  assert.throws(() => verify(missing), /external_reads must be a boolean/i);

  for (const key of ["upload.external_object", "storage.r2_reclaim"]) {
    const unsafe = basePayload();
    unsafe.values[key] = true;
    assert.throws(() => verify(unsafe), (error) => error.code === "UNSAFE_CONFIG");
  }
});

test("kill switches override rollout values without weakening legacy safe behavior", () => {
  const linkKilledPayload = basePayload();
  linkKilledPayload.kill_switches.link_imports = true;
  const linkKilledConfig = verify(linkKilledPayload);
  assert.deepEqual(linkKilledConfig.effective.available_upload_modes, ["local_file", "reviewed_match"]);
  assert.equal(linkKilledConfig.effective.matcher_mode, "review");

  const payload = basePayload();
  payload.kill_switches.all_uploads = true;
  payload.kill_switches.offline_downloads = true;
  payload.kill_switches.external_reads = true;
  const config = verify(payload);
  assert.deepEqual(config.effective.available_upload_modes, []);
  assert.equal(config.effective.default_upload_mode, null);
  assert.equal(config.effective.download_offline_mode, "stream_only");
  assert.equal(config.effective.matcher_mode, "off");
  assert.equal(config.effective.storage_read_mode, "r2_only");

  const direct = resolveClientConfigModes({ values: payload.values, kill_switches: payload.kill_switches });
  assert.deepEqual(direct, config.effective);
  assert.equal(resolveClientConfigModes({
    values: { ...payload.values, "storage.read_mode": "external_with_r2_fallback" },
    kill_switches: { ...payload.kill_switches, external_reads: false },
  }).storage_read_mode, "r2_only");
});

test("cache records preserve signed raw bytes and fail closed across every scope dimension", () => {
  const expected = expectedContext();
  const signed = signPayload(basePayload(expected));
  const record = createClientConfigCacheRecord({
    ...signed,
    expected,
    token: TOKEN,
    storedAt: "2026-08-06T17:59:00.000Z",
    etag: '"fflags-r23"',
  });
  assert.equal(Buffer.from(record.raw_body_base64, "base64").equals(signed.rawBody), true);
  assert.equal(record.highest_revision, 23);
  assert.equal(record.cache_key, configCacheKey(expected, TOKEN));
  assert.doesNotMatch(JSON.stringify(record), /access-token-for-tests/);
  assert.match(tokenFingerprint(TOKEN), /^sha256:[A-Za-z0-9_-]{43}$/);
  assert.equal(validCachedClientConfig(record, { expected, token: TOKEN, now: NOW })?.source, "cache");
  assert.equal(validCachedClientConfig(record, { expected, token: "rotated-token", now: NOW }), null);

  for (const changed of [
    expectedContext({ origin: "https://different.example.test" }),
    expectedContext({ profileID: "listener-b" }),
    { ...expected, platform: "other" },
    expectedContext({ appVersion: "1.1.5" }),
    expectedContext({ appBuild: 18 }),
    { ...expected, cohort_bucket: (expected.cohort_bucket + 1) % 10_000 },
  ]) {
    assert.notEqual(configCacheKey(changed, TOKEN), record.cache_key);
    assert.equal(validCachedClientConfig(record, { expected: changed, token: TOKEN, now: NOW }), null);
  }
});

test("rejects signed revision rollback within one exact cache scope", () => {
  const expected = expectedContext();
  const newerPayload = basePayload(expected);
  newerPayload.revision = 24;
  const newerSigned = signPayload(newerPayload);
  const record = createClientConfigCacheRecord({
    ...newerSigned,
    expected,
    token: TOKEN,
    storedAt: "2026-08-06T17:59:00.000Z",
    etag: '"fflags-r24"',
  });
  const older = verify(basePayload(expected));
  assert.throws(() => monotonicClientConfigRevision(older, record), (error) =>
    error instanceof ClientConfigVerificationError && error.code === "REVISION_ROLLBACK");
  assert.equal(monotonicClientConfigRevision(verify(newerPayload), record), 24);
  const nextPayload = basePayload(expected);
  nextPayload.revision = 25;
  assert.equal(monotonicClientConfigRevision(verify(nextPayload), record), 25);

  const revisionFloor = monotonicClientConfigRevision(verify(newerPayload), 0);
  const invalid = basePayload(expected);
  invalid.revision = 25;
  const invalidSigned = signPayload(invalid);
  assert.throws(() => verifyClientConfigResponse({
    ...invalidSigned,
    signature: invalidSigned.signature.replace(/^v1=:/, "v2=:"),
    expected,
    now: NOW,
  }));
  assert.throws(() => monotonicClientConfigRevision(older, revisionFloor), (error) =>
    error instanceof ClientConfigVerificationError && error.code === "REVISION_ROLLBACK");
});

test("cached configs expire after 15 minutes and any corruption returns null", () => {
  const expected = expectedContext();
  const payload = basePayload(expected);
  payload.issued_at = "2026-08-06T17:50:00.000Z";
  payload.not_before = "2026-08-06T17:50:00.000Z";
  payload.expires_at = "2026-08-06T18:05:00.000Z";
  const signed = signPayload(payload);
  const record = createClientConfigCacheRecord({
    ...signed,
    expected,
    token: TOKEN,
    storedAt: "2026-08-06T17:44:59.999Z",
  });
  assert.equal(validCachedClientConfig(record, { expected, token: TOKEN, now: NOW }), null);
  assert.equal(validCachedClientConfig({ ...record, raw_body_base64: "!!!!" }, { expected, token: TOKEN, now: NOW }), null);
  assert.equal(validCachedClientConfig({ ...record, stored_at: "tomorrow" }, { expected, token: TOKEN, now: NOW }), null);
});

test("bearer headers are available only for same-origin HTTP(S) resolver URLs", () => {
  const origin = "https://music.example.test/base";
  assert.equal(
    resolveSameOriginURL("/api/v1/songs/song-a/media", origin),
    "https://music.example.test/api/v1/songs/song-a/media",
  );
  assert.equal(resolveSameOriginURL("https://music.example.test:443/audio", origin), "https://music.example.test/audio");
  for (const candidate of [
    "https://cdn.example.test/audio",
    "http://music.example.test/audio",
    "https://user:password@music.example.test/audio",
    "javascript:alert(1)",
    "/audio#fragment",
  ]) {
    assert.equal(resolveSameOriginURL(candidate, origin), null, candidate);
    assert.equal(sameOriginBearerHeaders(candidate, origin, TOKEN), null, candidate);
  }
  assert.deepEqual(sameOriginBearerHeaders("/audio/song-a", origin, TOKEN), {
    url: "https://music.example.test/audio/song-a",
    headers: { Authorization: `Bearer ${TOKEN}` },
  });
});

test("verification failures use a typed error without including credentials", () => {
  const payload = basePayload();
  const signed = signPayload(payload);
  let caught;
  try {
    verifyClientConfigResponse({
      ...signed,
      token: "wrong-secret-that-must-not-appear",
      expected: expectedContext(),
      now: NOW,
    });
  } catch (error) {
    caught = error;
  }
  assert.ok(caught instanceof ClientConfigVerificationError);
  assert.equal(caught.code, "SIGNATURE_MISMATCH");
  assert.doesNotMatch(caught.message, /wrong-secret/);
});
