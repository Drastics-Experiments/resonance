# Listen Along protocol

Listen Along is a host-authoritative, transient playback session. The host sends
the canonical public source page for the current track to Resonance Core. Joined
clients resolve that link locally and play it without persisting the session track.

The protocol deliberately does not send local file paths, provider playback URLs,
track metadata, account credentials, or Resonance bearer tokens to other clients
or third-party media hosts.

## Core API

Every request uses the client's existing Resonance bearer token and profile/client
headers.

- `POST /api/v1/listen-along` creates a session and returns its join code plus a
  one-time host control token.
- `GET /api/v1/listen-along/{code}` reads the latest session snapshot.
- `PUT /api/v1/listen-along/{code}` updates the snapshot. It requires
  `X-Resonance-Listen-Host` and the current revision.
- `DELETE /api/v1/listen-along/{code}` ends the session and requires the same host
  token.

Snapshots contain only:

```json
{
  "revision": 4,
  "source_url": "https://www.youtube.com/watch?v=example",
  "media_kind": "audio",
  "position_seconds": 37.5,
  "is_playing": true
}
```

Core adds `updated_at`, `expires_at`, `server_time`, and `participant_count`. A participant projects a
playing position as `position_seconds + (now - updated_at)`, adjusted by the
observed server clock offset. A client ignores older revisions and corrects drift
only when it exceeds the platform's tolerance.

`participant_count` is the number of installation cohorts that have contacted the
room during the last ten seconds, including the host. Core stores only a SHA-256
digest of the existing anonymous cohort key and removes stale presence rows.

The host token is random, kept only in client memory, and stored by Core as a
SHA-256 hash. Join codes carry no account credential. Creating a new session ends
the host profile's previous active session, and inactive sessions expire after
eight hours.

## Client behavior

- Host play, pause, seek, next, previous, and automatic track transitions publish
  a complete revisioned snapshot.
- Participant transport controls are disabled; volume and leaving the session stay
  local.
- Every client shows a copy action beside an active room code so the host or a
  participant can share the exact code without retyping it.
- Participants first reuse a local or server-cached track with the same canonical
  source URL. Otherwise they resolve the source through the existing platform link
  importer and play the resulting transient stream with provider-required headers.
- YouTube transient playback uses explicit verified GoogleVideo byte ranges so
  AVFoundation and Media3 retain the provider headers on every seek/read request.
- Resolved provider artwork stays local to each participant and is shown in the
  player when the library does not already contain artwork for that source.
- Healthy participant sessions poll about every 250 milliseconds. Failed requests
  back off, while new revisions resume the normal cadence.
- Play, pause, and seek revisions for the current source reuse its prepared stream;
  only a source change starts a new provider resolution.
- Provider stream URLs are never written to the library or sent back to Core.
- A source-less local file cannot be hosted. The UI asks the user to import it from
  a supported link or associate it with the server first.
- Sign-out, server/profile changes, or credential invalidation leave the session
  and cancel its polling/playback work.

Core uses revisioned short polling because the current Sites deployment has D1
and R2 bindings but no Durable Object/WebSocket coordination binding. This keeps
reconnect behavior deterministic without introducing a second production service.
