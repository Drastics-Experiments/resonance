let metadataModule;

async function parser() {
  metadataModule ||= import("music-metadata");
  return metadataModule;
}

function pictureDataURL(picture) {
  if (!picture?.data?.length) return null;
  const format = /^image\/[a-z0-9.+-]+$/i.test(String(picture.format || "")) ? picture.format : "image/jpeg";
  return `data:${format};base64,${Buffer.from(picture.data).toString("base64")}`;
}

async function readAudioMetadata(filePath) {
  try {
    const { parseFile } = await parser();
    const parsed = await parseFile(filePath, { duration: true, skipCovers: false });
    const common = parsed.common || {};
    return {
      title: common.title || null,
      artist: common.artist || (Array.isArray(common.artists) ? common.artists.join(", ") : null),
      album: common.album || null,
      duration: Number(parsed.format?.duration) || 0,
      artwork: pictureDataURL(common.picture?.[0]),
    };
  } catch {
    return { title: null, artist: null, album: null, duration: 0, artwork: null };
  }
}

module.exports = { pictureDataURL, readAudioMetadata };
