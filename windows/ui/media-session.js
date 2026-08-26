const MEDIA_SESSION_ACTIONS = Object.freeze([
  "play",
  "pause",
  "seekbackward",
  "seekforward",
  "seekto",
  "nexttrack",
  "previoustrack",
]);

const ARTWORK_DATA_URL_PATTERN = /^data:image\/[a-z0-9.+-]+;base64,[a-z0-9+/]+=*$/i;
const ARTWORK_PROTOCOLS = new Set(["blob:", "https:"]);

function normalizedArtworkSource(value) {
  if (typeof value !== "string") return null;
  const source = value.trim();
  if (!source) return null;
  if (ARTWORK_DATA_URL_PATTERN.test(source)) return source;
  try {
    const url = new URL(source);
    return ARTWORK_PROTOCOLS.has(url.protocol) ? url.href : null;
  } catch {
    return null;
  }
}

function artworkMimeType(source) {
  const match = /^data:([^;,]+)/i.exec(source);
  return match?.[1] || undefined;
}

export function mediaSessionArtwork(track) {
  const sources = [track?.artwork, track?.artworkURL, track?.artwork_url]
    .map(normalizedArtworkSource)
    .filter(Boolean);
  return [...new Set(sources)].map((src) => ({
    src,
    sizes: "512x512",
    ...(artworkMimeType(src) ? { type: artworkMimeType(src) } : {}),
  }));
}

export function mediaSessionMetadataInit(track) {
  if (!track) return null;
  return {
    title: String(track.title || track.name || "Untitled"),
    artist: String(track.artist || "Unknown Artist"),
    album: String(track.album || ""),
    artwork: mediaSessionArtwork(track),
  };
}

function mediaSessionPositionState(mediaSession, { duration, position, playbackRate } = {}) {
  if (typeof mediaSession?.setPositionState !== "function") return false;
  const normalizedDuration = Number(duration);
  const normalizedPosition = Number(position);
  const normalizedRate = Number(playbackRate);
  if (!Number.isFinite(normalizedDuration) || normalizedDuration <= 0
      || !Number.isFinite(normalizedPosition)) return false;
  try {
    mediaSession.setPositionState({
      duration: normalizedDuration,
      position: Math.max(0, Math.min(normalizedDuration, normalizedPosition)),
      playbackRate: Number.isFinite(normalizedRate) && normalizedRate > 0 ? normalizedRate : 1,
    });
    return true;
  } catch {
    // Chromium rejects position state when a media element reports a transient
    // or stale duration. The next playback event will retry it.
    return false;
  }
}

export function createMediaSessionController({
  navigatorObject = typeof globalThis === "undefined" ? null : globalThis.navigator,
  MediaMetadataConstructor = typeof globalThis === "undefined" ? null : globalThis.MediaMetadata,
  actionHandlers = {},
} = {}) {
  const mediaSession = navigatorObject?.mediaSession;
  if (!mediaSession || typeof mediaSession.setActionHandler !== "function") return null;

  for (const action of MEDIA_SESSION_ACTIONS) {
    const handler = actionHandlers[action];
    if (typeof handler !== "function") continue;
    try {
      mediaSession.setActionHandler(action, handler);
    } catch {
      // Action support varies between Chromium versions and host platforms.
    }
  }

  let metadataSignature = "";
  const controller = {
    syncPlayback({ hasTrack = true, isPlaying = false, duration = 0, position = 0, playbackRate = 1 } = {}) {
      try {
        mediaSession.playbackState = !hasTrack ? "none" : isPlaying ? "playing" : "paused";
      } catch {
        // The property is optional in older embedded Chromium versions.
      }
      mediaSessionPositionState(mediaSession, { duration, position, playbackRate });
    },

    sync({ track = null, isPlaying = false, duration = 0, position = 0, playbackRate = 1 } = {}) {
      const metadata = mediaSessionMetadataInit(track);
      const nextSignature = metadata ? JSON.stringify(metadata) : "";
      if (nextSignature !== metadataSignature) {
        metadataSignature = nextSignature;
        try {
          mediaSession.metadata = metadata && typeof MediaMetadataConstructor === "function"
            ? new MediaMetadataConstructor(metadata)
            : null;
        } catch {
          try {
            mediaSession.metadata = null;
          } catch {
            // Some host shells expose a read-only metadata property.
          }
        }
      }
      this.syncPlayback({ hasTrack: Boolean(track), isPlaying, duration, position, playbackRate });
    },
  };

  return controller;
}

export { MEDIA_SESSION_ACTIONS };
