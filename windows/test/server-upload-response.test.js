import assert from "node:assert/strict";
import test from "node:test";
import uploadResponse from "../server-upload-response.cjs";

const { MAX_SERVER_UPLOAD_RESPONSE_BYTES, readServerUploadResponse } = uploadResponse;
const origin = "https://music.example";

function response(payload, status = 201, headers = {}) {
  return new Response(typeof payload === "string" ? payload : JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json", ...headers },
  });
}

test("accepts and sanitizes a bounded created-song response", async () => {
  const result = await readServerUploadResponse(response({
    id: "remote-1",
    title: " Song ",
    artist: "Artist",
    size: 123,
    duration_seconds: 4.5,
    content_sha256: "A".repeat(64),
    download_url: "/api/v1/songs/remote-1/download",
    ignored_secret: "do not cross IPC",
  }), { serverOrigin: origin });
  assert.equal(result.status, 201);
  assert.equal(result.duplicate, false);
  assert.equal(result.song.title, "Song");
  assert.equal(result.song.content_sha256, "a".repeat(64));
  assert.equal(result.song.download_url, `${origin}/api/v1/songs/remote-1/download`);
  assert.equal("ignored_secret" in result.song, false);
});

test("accepts only the exact duplicate_of shape for HTTP 409", async () => {
  const accepted = await readServerUploadResponse(response({ duplicate_of: { id: "existing", title: "Existing" } }, 409), { serverOrigin: origin });
  assert.equal(accepted.duplicate, true);
  assert.equal(accepted.song.id, "existing");
  await assert.rejects(
    readServerUploadResponse(response({ duplicateOf: { id: "legacy" } }, 409), { serverOrigin: origin }),
    /uploaded song object/,
  );
});

test("rejects malformed, non-JSON, oversized, and unsafe upload responses", async () => {
  await assert.rejects(
    readServerUploadResponse(new Response("not json", { status: 201, headers: { "content-type": "application/json" } }), { serverOrigin: origin }),
    /malformed upload JSON/,
  );
  await assert.rejects(
    readServerUploadResponse(new Response("ok", { status: 201, headers: { "content-type": "text/plain" } }), { serverOrigin: origin }),
    /was not JSON/,
  );
  await assert.rejects(
    readServerUploadResponse(response({ id: "song" }, 201, { "content-length": String(MAX_SERVER_UPLOAD_RESPONSE_BYTES + 1) }), { serverOrigin: origin }),
    /too large/,
  );
  await assert.rejects(
    readServerUploadResponse(response({ id: "song", stream_url: "https://attacker.example/audio" }), { serverOrigin: origin }),
    /unsafe media URL/,
  );
});

test("bounds and sanitizes an HTTP error without exposing arbitrary fields", async () => {
  await assert.rejects(
    readServerUploadResponse(response({ error: "Nope", private: "secret" }, 403), { serverOrigin: origin }),
    (error) => error.status === 403 && error.message === "Server returned HTTP 403: Nope",
  );
});
