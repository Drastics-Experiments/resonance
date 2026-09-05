import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import asyncWork from "../async-work.cjs";

const { createLatestValueWriter, mapConcurrent } = asyncWork;
const deferred = () => Promise.withResolvers();

test("bounded mapping keeps input order even when file work completes out of order", async () => {
  const gates = Array.from({ length: 7 }, deferred);
  const started = [];
  let active = 0;
  let peak = 0;
  const work = mapConcurrent(gates, 2, async (gate, index) => {
    started.push(index);
    peak = Math.max(peak, ++active);
    await gate.promise;
    active--;
    return index * 10;
  });
  assert.deepEqual(started, [0, 1]);
  gates[1].resolve();
  await new Promise(setImmediate);
  assert.deepEqual(started, [0, 1, 2]);
  for (const gate of gates) gate.resolve();
  assert.deepEqual(await work, [0, 10, 20, 30, 40, 50, 60]);
  assert.equal(peak, 2);
  assert.equal(active, 0);
});

test("failed mapping stops new work and waits for active resources before rejecting", async () => {
  const gates = [deferred(), deferred()];
  const started = [];
  let settled = false;
  const failure = new Error("unreadable media");
  const work = mapConcurrent([0, 1, 2, 3], 2, async (index) => {
    started.push(index);
    await gates[index].promise;
  });
  const rejected = assert.rejects(work, failure).then(() => { settled = true; });
  gates[0].reject(failure);
  await new Promise(setImmediate);
  assert.equal(settled, false);
  assert.deepEqual(started, [0, 1]);
  gates[1].resolve();
  await rejected;
  assert.deepEqual(started, [0, 1]);
});

test("mapping supports empty iterables and rejects invalid limits", async () => {
  assert.deepEqual(await mapConcurrent(new Set(), 4, () => assert.fail()), []);
  assert.deepEqual(await mapConcurrent(new Set([2, 1]), 8, (n) => n + 1), [3, 2]);
  for (const concurrency of [0, -1, 1.5, Infinity, NaN]) {
    await assert.rejects(mapConcurrent([], concurrency, () => {}), RangeError);
  }
});

test("pending saves collapse to the latest snapshot and acknowledge only after it is written", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "resonance-save-queue-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const destination = path.join(directory, "library.json");
  const firstWrite = deferred();
  const lastWrite = deferred();
  const written = [];
  const save = createLatestValueWriter(async (snapshot) => {
    written.push(snapshot.version);
    await (snapshot.version === 1 ? firstWrite.promise : lastWrite.promise);
    await writeFile(destination, JSON.stringify(snapshot));
  });
  const first = save({ version: 1 });
  await new Promise(setImmediate);
  let acknowledged = 0;
  const pending = Array.from({ length: 100 }, (_, index) =>
    save({ version: index + 2 }).then(() => { acknowledged++; }));
  assert.deepEqual(written, [1]);
  firstWrite.resolve();
  await first;
  assert.equal(acknowledged, 0);
  assert.deepEqual(written, [1, 101]);
  assert.equal(JSON.parse(await readFile(destination, "utf8")).version, 1);
  lastWrite.resolve();
  await Promise.all(pending);
  assert.equal(acknowledged, 100);
  assert.equal(JSON.parse(await readFile(destination, "utf8")).version, 101);
});

test("save errors reject affected callers while newer snapshots still persist", async () => {
  const failedWrite = deferred();
  const written = [];
  const save = createLatestValueWriter(async (value) => {
    if (value === "failed") await failedWrite.promise;
    written.push(value);
  });
  const first = save("superseded");
  const second = save("failed");
  const rejections = [assert.rejects(first, /disk full/), assert.rejects(second, /disk full/)];
  await new Promise(setImmediate);
  const recovery = save("recovered");
  failedWrite.reject(new Error("disk full"));
  await Promise.all([...rejections, recovery]);
  assert.deepEqual(written, ["recovered"]);
  await save("after idle");
  assert.deepEqual(written, ["recovered", "after idle"]);
});

test("synchronous writer failures do not strand the queue", async () => {
  const save = createLatestValueWriter((value) => {
    if (value === 1) throw new Error("failed synchronously");
  });
  await assert.rejects(save(1), /failed synchronously/);
  await save(2);
});

test("invalid input cannot supersede an accepted pending snapshot", async () => {
  const firstWrite = deferred();
  const written = [];
  const save = createLatestValueWriter(async (value) => {
    if (value === 1) await firstWrite.promise;
    written.push(value);
  }, {
    prepare(value) {
      if (!Number.isInteger(value)) throw new TypeError("Invalid snapshot");
      return value;
    },
  });
  const first = save(1);
  await new Promise(setImmediate);
  const validPending = save(2);
  await assert.rejects(save(null), /Invalid snapshot/);
  firstWrite.resolve();
  await Promise.all([first, validPending]);
  assert.deepEqual(written, [1, 2]);
});

test("unserializable input cannot discard a waiting JSON save", async () => {
  const written = [];
  const save = createLatestValueWriter(async (json) => { written.push(JSON.parse(json)); }, {
    prepare: JSON.stringify,
  });
  const valid = save({ version: 2 });
  const circular = {};
  circular.self = circular;
  await assert.rejects(save(circular), TypeError);
  await valid;
  assert.deepEqual(written, [{ version: 2 }]);
});
