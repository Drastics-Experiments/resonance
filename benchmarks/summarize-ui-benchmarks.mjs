import fs from "node:fs";

const [inputPath] = process.argv.slice(2);
if (!inputPath) throw new Error("Usage: node summarize-ui-benchmarks.mjs <results.json>");

const document = JSON.parse(fs.readFileSync(inputPath, "utf8"));
const groups = new Map();
for (const result of document.results) {
  const key = `${result.name}:${result.dataset_size}`;
  if (!groups.has(key)) groups.set(key, {});
  groups.get(key)[result.variant] = result.median_ns;
}

const milliseconds = (nanoseconds) => (nanoseconds / 1_000_000).toFixed(3);
const rows = [];
for (const [key, variants] of groups) {
  const separator = key.lastIndexOf(":");
  const name = key.slice(0, separator);
  const size = Number(key.slice(separator + 1));
  if (variants.baseline === undefined || variants.candidate === undefined) continue;
  rows.push({
    name,
    size,
    baseline: variants.baseline,
    candidate: variants.candidate,
    speedup: variants.baseline / variants.candidate,
  });
}
rows.sort((a, b) => a.name.localeCompare(b.name) || a.size - b.size);

console.log("# UI benchmark results");
console.log("");
console.log(`Runtime: ${document.runtime} on ${document.platform}`);
console.log("");
console.log("| Benchmark | Tracks | Baseline median | Candidate median | Speedup |");
console.log("|---|---:|---:|---:|---:|");
for (const row of rows) {
  console.log(
    `| ${row.name} | ${row.size.toLocaleString("en-US")} | ${milliseconds(row.baseline)} ms | ${milliseconds(row.candidate)} ms | ${row.speedup.toFixed(2)}× |`,
  );
}

const builds = document.results
  .filter((result) => result.name === "index_build")
  .sort((a, b) => a.dataset_size - b.dataset_size);
if (builds.length) {
  console.log("");
  console.log("Index construction cost:");
  for (const result of builds) {
    console.log(`- ${result.dataset_size.toLocaleString("en-US")} tracks: ${milliseconds(result.median_ns)} ms`);
  }
}
