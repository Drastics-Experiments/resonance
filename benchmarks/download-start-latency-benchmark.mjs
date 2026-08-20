import { performance } from "node:perf_hooks";

const rounds = Math.max(3, Number(process.argv[2]) || 7);
const setupDelayMs = Math.max(10, Number(process.argv[3]) || 250);

const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

async function byteGatedStart() {
  const started = performance.now();
  await wait(setupDelayMs);
  return performance.now() - started;
}

async function preparationVisibleStart() {
  const started = performance.now();
  const visibleAt = performance.now() - started;
  await wait(setupDelayMs);
  return visibleAt;
}

async function median(operation) {
  const values = [];
  for (let index = 0; index < rounds; index += 1) values.push(await operation());
  values.sort((left, right) => left - right);
  return values[Math.floor(values.length / 2)];
}

const oldLatency = await median(byteGatedStart);
const newLatency = await median(preparationVisibleStart);
console.log(`Synthetic provider setup: ${setupDelayMs} ms, median of ${rounds} rounds`);
console.log("method	first_visible_ms");
console.log(`byte-gated UI	${oldLatency.toFixed(1)}`);
console.log(`preparation-visible UI	${newLatency.toFixed(3)}`);
console.log(`latency_removed_ms=${Math.max(0, oldLatency - newLatency).toFixed(1)}`);
