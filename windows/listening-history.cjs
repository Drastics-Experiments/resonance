const MAX_LISTENING_HISTORY_BATCH = 500;
const MAX_LISTENED_SECONDS = 31 * 24 * 60 * 60;
const MAX_TRACK_DURATION_SECONDS = 7 * 24 * 60 * 60;

function boundedText(value, maximumLength) {
  const text = typeof value === "string" ? value.trim() : "";
  return text && text.length <= maximumLength ? text : null;
}

function optionalText(value, maximumLength) {
  if (value === undefined || value === null || value === "") return null;
  return boundedText(value, maximumLength);
}

function normalizedNumber(value, maximum, field) {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0 || number > maximum) {
    throw new Error(`Listening history ${field} must be a non-negative finite number.`);
  }
  return number;
}

function normalizeListeningHistoryEntry(value) {
  const id = boundedText(value?.id, 128);
  const trackID = boundedText(value?.trackID ?? value?.track_id, 128);
  const songValue = value?.remoteID ?? value?.songID ?? value?.song_id;
  const songID = optionalText(songValue, 128);
  const startedAt = new Date(value?.startedAt ?? value?.started_at ?? "");
  if (!id || !trackID) throw new Error("Listening history entries require an id and track_id.");
  if (songValue !== undefined && songValue !== null && songValue !== "" && !songID) {
    throw new Error("Listening history song_id must contain at most 128 characters.");
  }
  if (!Number.isFinite(startedAt.getTime())) {
    throw new Error("Listening history entries require a valid started_at timestamp.");
  }
  const listenedSeconds = normalizedNumber(
    value?.listenedSeconds ?? value?.listened_seconds,
    MAX_LISTENED_SECONDS,
    "listened_seconds",
  );
  const durationValue = value?.duration ?? value?.durationSeconds ?? value?.duration_seconds;
  const durationSeconds = durationValue === undefined || durationValue === null || durationValue === ""
    ? null
    : normalizedNumber(durationValue, MAX_TRACK_DURATION_SECONDS, "duration_seconds");
  return {
    id,
    track_id: trackID,
    song_id: songID,
    started_at: startedAt.toISOString(),
    listened_seconds: listenedSeconds,
    title: optionalText(value?.title, 500),
    artist: optionalText(value?.artist, 500),
    album: optionalText(value?.album, 500),
    duration_seconds: durationSeconds,
  };
}

function normalizeListeningHistoryUploadEntries(entries) {
  if (!Array.isArray(entries) || entries.length === 0 || entries.length > MAX_LISTENING_HISTORY_BATCH) {
    throw new Error(`Listening history must contain between 1 and ${MAX_LISTENING_HISTORY_BATCH} entries.`);
  }
  return entries.map(normalizeListeningHistoryEntry);
}

module.exports = {
  MAX_LISTENING_HISTORY_BATCH,
  normalizeListeningHistoryEntry,
  normalizeListeningHistoryUploadEntries,
};
