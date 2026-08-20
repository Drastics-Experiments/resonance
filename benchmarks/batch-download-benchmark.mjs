import { createRequire } from "node:module";
import { performance } from "node:perf_hooks";

const require = createRequire(import.meta.url);
const { runServerDownloadPool } = require("../windows/server-download.cjs");

const itemCount = Number(process.argv[2] || 30);
const rounds = Number(process.argv[3] || 5);
const networkDelay = (index) => 12 + (index % 5) * 3;
const metadataDelay = 7;
const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function trial(concurrency, scanMetadata) {
  const items = Array.from({ length: itemCount }, (_, index) => index);
  const started = performance.now();
  await runServerDownloadPool(items, async (index) => {
    await sleep(networkDelay(index));
    if (scanMetadata) await sleep(metadataDelay);
    return index;
  }, { concurrency });
  return performance.now() - started;
}

async function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

const configurations = [
  { name: "sequential + embedded scan", concurrency: 1, scanMetadata: true },
  { name: "2 workers + embedded scan", concurrency: 2, scanMetadata: true },
  { name: "3 workers + catalog fast path", concurrency: 3, scanMetadata: false },
  { name: "4 workers + catalog fast path", concurrency: 4, scanMetadata: false },
  { name: "6 workers + catalog fast path", concurrency: 6, scanMetadata: false },
];

const rows = [];
for (const configuration of configurations) {
  const samples = [];
  for (let round = 0; round < rounds; round += 1) {
    samples.push(await trial(configuration.concurrency, configuration.scanMetadata));
  }
  rows.push({ ...configuration, milliseconds: await median(samples) });
}
const baseline = rows[0].milliseconds;
console.log(`Synthetic batch: ${itemCount} files, median of ${rounds} rounds`);
console.log("method\tmedian_ms\tspeedup");
for (const row of rows) {
  console.log(`${row.name}\t${row.milliseconds.toFixed(1)}\t${(baseline / row.milliseconds).toFixed(2)}x`);
}
