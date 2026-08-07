# Resonance client config protocol v1

This document is the byte-level contract shared by the Resonance API and the
macOS, iOS, Android, and Windows clients. Unknown JSON properties are ignored,
but unknown schema versions or enum values invalidate the snapshot.

## Request

Clients send an authenticated, same-origin `GET /api/v1/client-config` request
with these headers:

- `Authorization: Bearer <access-or-admin-token>`
- `X-Resonance-Profile: <profile-id>`
- `X-Resonance-Client-Platform: macos|ios|android|windows`
- `X-Resonance-App-Version: <semantic-version>`
- `X-Resonance-App-Build: <positive-integer>`
- `X-Resonance-Cohort-Key: <stable-per-install-128-bit-base64url>`
- `X-Resonance-Config-Protocol: 1`

The cohort key is random and anonymous. It is not an account identifier or a
hardware/device identifier. The audience bucket is calculated as SHA-256 over
the UTF-8 bytes of:

```text
resonance-client-config-cohort-v1
<cohort-key>
```

The first four digest bytes are read as an unsigned big-endian integer and
reduced modulo 10,000.

## Response body

The response is a compact JSON object with these required properties:

```json
{
  "schema_version": 1,
  "revision": 0,
  "issued_at": "ISO-8601",
  "not_before": "ISO-8601",
  "expires_at": "ISO-8601",
  "audience": {
    "origin": "https://music.example",
    "profile_id": "default",
    "platform": "macos",
    "app_version": "1.1.4",
    "app_build": 15,
    "cohort_bucket": 0
  },
  "values": {
    "upload.local_file": true,
    "upload.server_source_link": false,
    "upload.reviewed_match": false,
    "upload.external_object": false,
    "download.offline_mode": "verified_file_cache",
    "download.playback_mode": "same_origin_resolver",
    "matcher.mode": "off",
    "storage.read_mode": "r2_only",
    "storage.r2_reclaim": false
  },
  "kill_switches": {
    "all_uploads": false,
    "link_imports": true,
    "offline_downloads": false,
    "external_reads": true,
    "r2_reclaim": true
  }
}
```

Allowed enum values are:

- `download.offline_mode`: `verified_file_cache`, `stream_only`
- `download.playback_mode`: `same_origin_resolver`
- `matcher.mode`: `off`, `shadow`, `review`
- `storage.read_mode`: `r2_only`, `external_with_r2_fallback`

The signed lifetime must be no more than 15 minutes. The audience must exactly
match the request context. Protocol v1 always forces `upload.external_object`
and `storage.r2_reclaim` off. Until a renewable external-media adapter exists,
the server also forces `storage.read_mode` to `r2_only`.

## Digest and signature

`Content-Digest` is:

```text
sha-256=:<standard-base64-SHA256-of-the-exact-response-body-bytes>:
```

The signature input is the exact UTF-8 string below, including newlines and the
complete `Content-Digest` header value:

```text
resonance-client-config-v1
<audience.origin>
<audience.profile_id>
<audience.platform>
<audience.app_build>
<Content-Digest>
```

`X-Resonance-Config-Signature` is:

```text
v1=:<standard-base64-HMAC-SHA256>:
```

The HMAC key is the exact bearer token supplied by that request. Clients cache
only verified raw bytes and response headers. Cache scope includes normalized
origin, profile, platform, version, build, and a one-way token fingerprint. A
cached response cannot be used after its signed expiry or a 15-minute local age.
Within that exact scope, a client that has verified revision N rejects a later
response below N; an intentional server rollback is published as a new,
higher-numbered immutable revision.

## Safe fallback

Transport failures and HTTP `5xx` responses may reuse a still-fresh, fully
verified cache entry for the exact scope. Missing endpoints (`404`/`405`),
other non-success responses, invalid signatures, malformed bodies, audience
mismatches, future/expired snapshots, and unknown schemas or enums evict that
scope and use the baked safe policy: local-file upload, verified same-origin
offline files, same-origin server playback, matcher off, R2 reads, and no
external-object upload or R2 reclamation.

## Source-link import

When enabled, clients send the original user-entered page URL only to the same
Resonance origin:

```http
POST /api/v1/admin/source-imports
Content-Type: application/json
```

The request carries the same client-context headers, admin bearer/profile, and:

```json
{
  "schema_version": 1,
  "source_page_url": "https://www.youtube.com/watch?v=...",
  "filename": "optional.m4a",
  "metadata": {
    "title": "optional",
    "artist": "optional",
    "album": "optional",
    "duration_seconds": 0
  }
}
```

Protocol v1 accepts canonical HTTPS YouTube page URLs and ingests their bytes to
R2. It never accepts or returns a provider playback URL, signed object URL,
object key, transfer credential, magnet, or Resonance credential. Other source
providers require the separately gated reviewed-match flow.

`upload.reviewed_match` is independent of `upload.server_source_link`. It means
the user reviewed a locally discovered candidate before its bytes are uploaded
through the existing `PUT /api/v1/admin/songs` endpoint. It is effective only
when `matcher.mode` is `review` and `upload.local_file` remains enabled; the raw
song PUT is the authoritative byte-ingest policy gate.

Server-assisted reviewed discovery uses `POST /api/v1/admin/debrid/resolve`
with the same snapshotted client-context headers. The endpoint is disabled
unless the effective policy permits reviewed matches. It may return
metadata-only `review_candidates` for explicit selection, but never an
automatically selected candidate, provider playback URL, magnet, info hash,
object location, or upload credential. A client may instead use an equivalent
local matcher. In both cases, after review the client resolves and verifies the
selected bytes locally and uses the raw song PUT; it never turns a reviewed
result into a source-import request.

Server metadata candidates are marked `requires_review: true`,
`auto_selectable: false`, and `actionable: false`. The last value means the
server metadata alone does not authorize a transfer; the client may proceed
only after the user selects that exact candidate and the client resolves and
verifies its bytes locally.

An upload captures and revalidates its mode and context immediately before the
request begins; the server independently evaluates current policy when it
accepts the request. A committed `201` or duplicate `409` is reconciled when the
server/profile/token context still matches even if the client lease expires
while bytes are in flight. A retry or new upload requires a new valid lease.
Downloads and streaming are different: no new file or Range bytes may continue
after their captured lease expires or changes, though a same-context verified
renewal may extend an active stream. An offline download keeps its originally
captured signed expiry and must reauthorize again immediately before atomically
adopting the verified staging file; only the baked safe fallback has no signed
expiry.

Successful imports return HTTP 201 with
`{"schema_version":1,"status":"imported|restored","song":{...}}`. Exact
duplicates return HTTP 409 with
`{"schema_version":1,"status":"duplicate","duplicate_of":{...}}`.
