const fs = require("node:fs/promises");

const EMPTY_METADATA = { title: null, artist: null, album: null, duration: 0, artwork: null };
let metadataModule;

async function parser() {
  metadataModule ||= import("music-metadata").catch((error) => {
    metadataModule = undefined;
    throw error;
  });
  return metadataModule;
}

function pictureDataURL(picture) {
  if (!picture?.data?.length) return null;
  const format = /^image\/[a-z0-9.+-]+$/i.test(String(picture.format || "")) ? picture.format : "image/jpeg";
  return `data:${format};base64,${Buffer.from(picture.data).toString("base64")}`;
}

function createMetadataReader({
  parseFile = async (...args) => (await parser()).parseFile(...args),
  stat = (filePath) => fs.stat(filePath, { bigint: true }),
  maxEntries = 128,
  maxArtworkBytes = 8 * 1024 * 1024,
} = {}) {
  if (![maxEntries, maxArtworkBytes].every((limit) => Number.isSafeInteger(limit) && limit >= 0)) {
    throw new RangeError("Metadata cache limits must be nonnegative integers.");
  }
  const cache = new Map();
  const inFlight = new Map();
  let cachedArtworkBytes = 0;

  async function signature(filePath) {
    try {
      const info = await stat(filePath);
      return [info.dev, info.ino, info.size, info.mtimeNs ?? info.mtimeMs, info.ctimeNs ?? info.ctimeMs].join(":");
    } catch {
      return null;
    }
  }

  async function load(filePath, key, version) {
    // music-metadata mutates its options, so each parse owns a fresh object.
    const parsed = await parseFile(filePath, { duration: true, skipCovers: false });
    const common = parsed.common || {};
    const value = {
      title: common.title || null,
      artist: common.artist || (Array.isArray(common.artists) ? common.artists.join(", ") : null),
      album: common.album || null,
      duration: Number(parsed.format?.duration) || 0,
      artwork: pictureDataURL(common.picture?.[0]),
    };
    const bytes = value.artwork ? Buffer.byteLength(value.artwork) : 0;
    // A file replaced during parsing must not populate the cache.
    if (key && maxEntries > 0 && bytes <= maxArtworkBytes && await signature(filePath) === version) {
      while (cache.size >= maxEntries || cachedArtworkBytes + bytes > maxArtworkBytes) {
        const oldest = cache.keys().next().value;
        cachedArtworkBytes -= cache.get(oldest).bytes;
        cache.delete(oldest);
      }
      cache.set(key, { value, bytes });
      cachedArtworkBytes += bytes;
    }
    return value;
  }

  async function readAudioMetadata(filePath) {
    const version = await signature(filePath);
    const key = version === null ? null : `${filePath}\0${version}`;
    const cached = cache.get(key);
    if (cached) {
      cache.delete(key);
      cache.set(key, cached);
      return { ...cached.value };
    }

    try {
      let pending = key && inFlight.get(key);
      if (!pending) {
        pending = load(filePath, key, version);
        if (key) {
          pending = pending.finally(() => inFlight.delete(key));
          inFlight.set(key, pending);
        }
      }
      return { ...await pending };
    } catch {
      return { ...EMPTY_METADATA };
    }
  }

  return { readAudioMetadata };
}

module.exports = { pictureDataURL, createMetadataReader, ...createMetadataReader() };
