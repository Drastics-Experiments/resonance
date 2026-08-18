import { createRequire } from "node:module";
import { performance } from "node:perf_hooks";

const require = createRequire(import.meta.url);
const {
  createServerDownloadPresentationCoordinator,
  runServerDownloadPool,
  serverDownloadProgressEvent,
} = require("../windows/server-download.cjs");

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
const rounds = Number(process.argv[2] || 5);
const items = [
  { title: "YouTube A", provider: "youtube", preparation: 95, transfer: 24 },
  { title: "Direct A", provider: "server", preparation: 8, transfer: 24 },
  { title: "SoundCloud A", provider: "soundcloud", preparation: 48, transfer: 24 },
  { title: "Debrid A", provider: "debrid", preparation: 125, transfer: 24 },
  { title: "Direct B", provider: "server", preparation: 8, transfer: 24 },
  { title: "YouTube B", provider: "youtube", preparation: 82, transfer: 24 },
  { title: "SoundCloud B", provider: "soundcloud", preparation: 42, transfer: 24 },
  { title: "Direct C", provider: "server", preparation: 8, transfer: 24 },
];

function naiveCoordinator(itemCount, publish) {
  const active = new Set(Array.from({ length: itemCount }, (_, index) => index));
  let current = itemCount ? 0 : null;
  return {
    update(index, event) {
      if (active.has(index) && index === current) publish(event);
    },
    complete(index) {
      active.delete(index);
      if (index === current) current = active.size ? Math.min(...active) : null;
    },
  };
}

async function execute({ concurrency, optimizedPresentation }) {
  const started = performance.now();
  let firstVisibleByte = null;
  const publish = (event) => {
    if (firstVisibleByte === null && Number(event.itemCompleted) > 0) {
      firstVisibleByte = performance.now() - started;
    }
  };
  const coordinator = optimizedPresentation
    ? createServerDownloadPresentationCoordinator(items.length, publish)
    : naiveCoordinator(items.length, publish);

  await runServerDownloadPool(items, async (item, index) => {
    coordinator.update(index, serverDownloadProgressEvent({
      song: { title: item.title },
      itemIndex: index + 1,
      itemCount: items.length,
      completedBytes: 0,
      totalBytes: 1_024,
      title: `Preparing ${item.provider}`,
    }));
    await sleep(item.preparation);
    coordinator.update(index, serverDownloadProgressEvent({
      song: { title: item.title },
      itemIndex: index + 1,
      itemCount: items.length,
      completedBytes: 256,
      totalBytes: 1_024,
      title: `Downloading ${item.provider}`,
    }));
    await sleep(item.transfer);
    coordinator.complete(index);
  }, { concurrency });

  return {
    firstVisibleByte: firstVisibleByte ?? performance.now() - started,
    total: performance.now() - started,
  };
}

function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.floor(sorted.length / 2)];
}

const configurations = [
  { name: "sequential provider-first", concurrency: 1, optimizedPresentation: false },
  { name: "4 workers, first-item-owned popup", concurrency: 4, optimizedPresentation: false },
  { name: "4 workers, byte-priority popup", concurrency: 4, optimizedPresentation: true },
];

const rows = [];
for (const configuration of configurations) {
  const samples = [];
  for (let round = 0; round < rounds; round += 1) {
    samples.push(await execute(configuration));
  }
  rows.push({
    ...configuration,
    firstVisibleByte: median(samples.map((sample) => sample.firstVisibleByte)),
    total: median(samples.map((sample) => sample.total)),
  });
}

const baseline = rows[0];
console.log(`Synthetic mixed-provider batch: ${items.length} songs, median of ${rounds} rounds`);
console.log("method\tfirst_visible_byte_ms\ttotal_ms\tstartup_speedup\ttotal_speedup");
for (const row of rows) {
  console.log([
    row.name,
    row.firstVisibleByte.toFixed(1),
    row.total.toFixed(1),
    `${(baseline.firstVisibleByte / row.firstVisibleByte).toFixed(2)}x`,
    `${(baseline.total / row.total).toFixed(2)}x`,
  ].join("\t"));
}
