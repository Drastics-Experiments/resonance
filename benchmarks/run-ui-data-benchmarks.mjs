import fs from "node:fs";
import path from "node:path";
import { performance } from "node:perf_hooks";
import {
  TrackCatalogIndex,
  baselineLibrarySearch,
  baselineRecentlyAdded,
  baselineStorage,
  boundedRecentlyAdded,
  buildRowPresentations,
  generateTracks,
} from "./ui-data-core.mjs";

const outputPath = process.argv[2] ?? "benchmark-results/ui-data.json";
const sizes = [1_000, 10_000, 50_000];
const queries = [
  "song 000999",
  "artist 17",
  "album 9",
  "folder/33",
  "electronic",
  "definitely-not-present",
];
const storageCases = [
  ["all", "title", "artist 17"],
  ["downloads", "artist", "album 9"],
  ["files", "recent", "electronic"],
  ["all", "size", "song"],
  ["downloads", "title", "not-present"],
];

let blackhole = 0;
const results = [];

for (const size of sizes) {
  const tracks = generateTracks(size);
  const buildIterations = size >= 50_000 ? 7 : 15;
  results.push(benchmarkSingle("index_build", size, buildIterations, 4, () => {
    const index = new TrackCatalogIndex(tracks);
    consume(index.entries.length);
  }));

  const index = new TrackCatalogIndex(tracks);
  verifyEquivalent(tracks, index);

  const queryIterations = size >= 50_000 ? 5 : size >= 10_000 ? 12 : 40;
  results.push(...benchmarkPair("library_query_batch", size, queryIterations, 5,
    () => {
      for (const query of queries) consume(baselineLibrarySearch(tracks, query).length);
    },
    () => {
      for (const query of queries) consume(index.librarySearch(query).length);
    }));

  const storageIterations = size >= 50_000 ? 3 : size >= 10_000 ? 8 : 30;
  results.push(...benchmarkPair("storage_filter_sort_batch", size, storageIterations, 4,
    () => {
      for (const [scope, sort, query] of storageCases) {
        consume(baselineStorage(tracks, scope, sort, query).length);
      }
    },
    () => {
      for (const [scope, sort, query] of storageCases) {
        consume(index.storage(scope, sort, query).length);
      }
    }));

  const recentIterations = size >= 50_000 ? 12 : size >= 10_000 ? 35 : 120;
  results.push(...benchmarkPair("recently_added_top6", size, recentIterations, 5,
    () => consume(sumDates(baselineRecentlyAdded(tracks))),
    () => consume(sumDates(boundedRecentlyAdded(tracks)))));

  const rowIterations = size >= 50_000 ? 12 : size >= 10_000 ? 35 : 120;
  results.push(...benchmarkPair("row_presentation_work", size, rowIterations, 5,
    () => consume(buildRowPresentations(tracks, tracks.length)),
    () => consume(buildRowPresentations(tracks, Math.min(24, tracks.length)))));
}

const document = {
  schema_version: 1,
  runtime: process.version,
  platform: `${process.platform}-${process.arch}`,
  results,
  blackhole,
};
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, `${JSON.stringify(document, null, 2)}\n`);
console.log(JSON.stringify(document));

function verifyEquivalent(tracks, index) {
  for (const query of queries) {
    assertSameIds(baselineLibrarySearch(tracks, query), index.librarySearch(query), `library:${query}`);
  }
  for (const [scope, sort, query] of storageCases) {
    assertSameIds(
      baselineStorage(tracks, scope, sort, query),
      index.storage(scope, sort, query),
      `storage:${scope}:${sort}:${query}`,
    );
  }
  assertSameIds(baselineRecentlyAdded(tracks), boundedRecentlyAdded(tracks), "recent");
}

function assertSameIds(left, right, label) {
  if (left.length !== right.length) throw new Error(`${label}: length mismatch`);
  for (let index = 0; index < left.length; index += 1) {
    if (left[index].id !== right[index].id) {
      throw new Error(`${label}: mismatch at ${index}`);
    }
  }
}

function benchmarkPair(name, datasetSize, iterations, warmups, baseline, candidate) {
  for (let index = 0; index < warmups; index += 1) {
    baseline();
    candidate();
  }
  const baselineSamples = [];
  const candidateSamples = [];
  for (let sample = 0; sample < iterations; sample += 1) {
    if (sample % 2 === 0) {
      baselineSamples.push(time(baseline));
      candidateSamples.push(time(candidate));
    } else {
      candidateSamples.push(time(candidate));
      baselineSamples.push(time(baseline));
    }
  }
  return [
    { name, dataset_size: datasetSize, variant: "baseline", median_ns: median(baselineSamples) },
    { name, dataset_size: datasetSize, variant: "candidate", median_ns: median(candidateSamples) },
  ];
}

function benchmarkSingle(name, datasetSize, iterations, warmups, block) {
  for (let index = 0; index < warmups; index += 1) block();
  const samples = Array.from({ length: iterations }, () => time(block));
  return { name, dataset_size: datasetSize, variant: "candidate", median_ns: median(samples) };
}

function time(block) {
  const start = performance.now();
  block();
  return Math.round((performance.now() - start) * 1_000_000);
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

function sumDates(tracks) {
  let total = 0;
  for (const track of tracks) total += track.dateAddedEpochMs;
  return total;
}

function consume(value) {
  blackhole = (blackhole ^ Number(value)) | 0;
}
