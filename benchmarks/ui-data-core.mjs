export function generateTracks(count) {
  const genres = ["Electronic", "Ambient", "Pop", "Rock", "Jazz", "Classical", "Hip Hop", "Soundtrack"];
  return Array.from({ length: count }, (_, index) => {
    const downloaded = index % 3 === 0;
    return {
      id: `track-${index}`,
      title: `Song ${String(index).padStart(6, "0")} ${genres[index % genres.length]}`,
      artist: `Artist ${index % 257}`,
      album: `Album ${index % 43}`,
      relativePath: `folder/${index % 97}/track-${index}.m4a`,
      dateAddedEpochMs: 1_700_000_000_000 + ((index * 7919) % Math.max(count, 1)),
      durationMs: 90_000 + (index % 420) * 1_000,
      downloaded,
      size: 64_000 + (hashCode(`track-${index}`) & 0x3fffff),
    };
  });
}

export function baselineLibrarySearch(tracks, rawQuery) {
  const query = rawQuery.trim().toLocaleLowerCase("en-US");
  if (!query) return tracks;
  return tracks.filter((track) =>
    track.title.toLocaleLowerCase("en-US").includes(query)
    || track.artist.toLocaleLowerCase("en-US").includes(query)
    || track.album.toLocaleLowerCase("en-US").includes(query)
    || track.relativePath.toLocaleLowerCase("en-US").includes(query));
}

export function baselineStorage(tracks, scope, sort, rawQuery) {
  const scoped = scope === "all"
    ? tracks
    : tracks.filter((track) => scope === "downloads" ? track.downloaded : !track.downloaded);
  const query = rawQuery.trim().toLocaleLowerCase("en-US");
  const visible = scoped.filter((track) =>
    !query
    || track.title.toLocaleLowerCase("en-US").includes(query)
    || track.artist.toLocaleLowerCase("en-US").includes(query)
    || track.album.toLocaleLowerCase("en-US").includes(query)
    || track.relativePath.toLocaleLowerCase("en-US").includes(query));
  return visible.sort((a, b) => {
    switch (sort) {
      case "title": return a.title.localeCompare(b.title, "en-US", { sensitivity: "accent" });
      case "artist": return a.artist.localeCompare(b.artist, "en-US", { sensitivity: "accent" });
      case "recent": return b.dateAddedEpochMs - a.dateAddedEpochMs;
      case "size": return b.size - a.size;
      default: throw new Error(`Unknown sort: ${sort}`);
    }
  });
}

export function baselineRecentlyAdded(tracks, limit = 6) {
  return [...tracks].sort((a, b) => b.dateAddedEpochMs - a.dateAddedEpochMs).slice(0, limit);
}

export function boundedRecentlyAdded(tracks, limit = 6) {
  if (limit <= 0 || tracks.length === 0) return [];
  if (tracks.length <= limit) {
    return [...tracks].sort((a, b) => b.dateAddedEpochMs - a.dateAddedEpochMs);
  }
  const recent = [];
  for (const track of tracks) {
    const insertionIndex = recent.findIndex((candidate) =>
      track.dateAddedEpochMs > candidate.dateAddedEpochMs);
    if (insertionIndex >= 0) recent.splice(insertionIndex, 0, track);
    else if (recent.length < limit) recent.push(track);
    if (recent.length > limit) recent.pop();
  }
  return recent;
}

export class TrackCatalogIndex {
  constructor(tracks) {
    this.entries = tracks.map((track) => ({
      track,
      searchText: `${track.title}\0${track.artist}\0${track.album}\0${track.relativePath}`.toLocaleLowerCase("en-US"),
      titleKey: track.title.toLocaleLowerCase("en-US"),
      artistKey: track.artist.toLocaleLowerCase("en-US"),
    }));
    this.downloaded = this.entries.filter((entry) => entry.track.downloaded);
    this.imported = this.entries.filter((entry) => !entry.track.downloaded);
  }

  librarySearch(rawQuery) {
    const query = rawQuery.trim().toLocaleLowerCase("en-US");
    if (!query) return this.entries.map((entry) => entry.track);
    const matches = [];
    for (const entry of this.entries) {
      if (entry.searchText.includes(query)) matches.push(entry.track);
    }
    return matches;
  }

  storage(scope, sort, rawQuery) {
    const source = scope === "all"
      ? this.entries
      : scope === "downloads" ? this.downloaded : this.imported;
    const query = rawQuery.trim().toLocaleLowerCase("en-US");
    const matches = query
      ? source.filter((entry) => entry.searchText.includes(query))
      : [...source];
    matches.sort((a, b) => {
      switch (sort) {
        case "title": return a.titleKey.localeCompare(b.titleKey);
        case "artist": return a.artistKey.localeCompare(b.artistKey);
        case "recent": return b.track.dateAddedEpochMs - a.track.dateAddedEpochMs;
        case "size": return b.track.size - a.track.size;
        default: throw new Error(`Unknown sort: ${sort}`);
      }
    });
    return matches.map((entry) => entry.track);
  }
}

export function buildRowPresentations(tracks, count) {
  let hash = 1;
  const end = Math.min(count, tracks.length);
  for (let index = 0; index < end; index += 1) {
    const track = tracks[index];
    const seconds = Math.floor(track.durationMs / 1000);
    const duration = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
    hash = Math.imul(31, hash) + hashCode(track.title);
    hash = Math.imul(31, hash) + hashCode(track.artist);
    hash = Math.imul(31, hash) + hashCode(duration);
  }
  return hash | 0;
}

function hashCode(value) {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) {
    hash = Math.imul(31, hash) + value.charCodeAt(index);
  }
  return hash | 0;
}
