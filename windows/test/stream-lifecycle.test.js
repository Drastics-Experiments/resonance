import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import downloadFile from "../download-file.cjs";
import responseBody from "../response-body.cjs";
import serverStream from "../server-stream.cjs";

const { writeResponseToFile } = downloadFile;
const { readResponseBytes } = responseBody;
const { createExactLengthRelay } = serverStream;

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

test("bounded response reads cancel once and release their reader lock on overflow", async () => {
  let cancelCalls = 0;
  const response = new Response(new ReadableStream({
    start(controller) { controller.enqueue(Buffer.from("abcd")); },
    cancel() { cancelCalls += 1; throw new Error("upstream cancellation failed"); },
  }));

  await assert.rejects(readResponseBytes(response, 3, "bounded response"), /too large/);
  assert.equal(cancelCalls, 1);
  assert.equal(response.body.locked, false);
});

test("bounded response reads release their reader lock after a successful read", async () => {
  const response = new Response(Buffer.from("complete"));
  assert.equal((await readResponseBytes(response, 64)).toString(), "complete");
  const reader = response.body.getReader();
  reader.releaseLock();
});

test("bounded readers preserve provider errors for declared and streamed overflow", async () => {
  for (const headers of [{ "content-length": "4" }, {}]) {
    let cancelled = false;
    const response = new Response(new ReadableStream({
      start(controller) { controller.enqueue(Buffer.from("four")); },
      cancel() { cancelled = true; },
    }), { headers });
    const error = Object.assign(new Error("Provider response too large"), { code: "PROVIDER_LIMIT", stage: "lookup" });
    await assert.rejects(readResponseBytes(response, 3, error), (caught) => caught === error);
    assert.equal(cancelled, true);
    assert.equal(response.body.locked, false);
  }
});

test("bounded readers accept the exact limit and propagate stream failures", async () => {
  assert.deepEqual(await readResponseBytes(new Response(null), 1), Buffer.alloc(0));
  assert.equal((await readResponseBytes(new Response("four"), 4)).toString(), "four");
  const error = new DOMException("Cancelled upstream", "AbortError");
  const response = new Response(new ReadableStream({
    pull(controller) { controller.error(error); },
  }));
  await assert.rejects(readResponseBytes(response, 4), (caught) => caught === error);
  assert.equal(response.body.locked, false);
});

test("downloads honor a typed-array view's byte offset", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "resonance-stream-view-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const backing = new Uint8Array([0xff, 0xee, 0x72, 0x65, 0x73, 0x6f, 0x6e, 0x61, 0x6e, 0xdd]);
  const bytes = backing.subarray(2, 9);
  const destination = path.join(directory, "view.part");
  const response = new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(bytes);
      controller.close();
    },
  }), { headers: { "content-length": String(bytes.byteLength) } });

  await writeResponseToFile(response, destination, {
    expectedSize: bytes.byteLength,
    expectedSHA256: sha256(bytes),
  });
  assert.deepEqual(await readFile(destination), Buffer.from(bytes));
});

test("a failed destination open cancels the response and preserves the existing file", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "resonance-stream-existing-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const destination = path.join(directory, "existing.part");
  await writeFile(destination, "keep me");
  let cancelCalls = 0;
  const response = new Response(new ReadableStream({
    cancel() { cancelCalls += 1; },
  }), { headers: { "content-length": "1" } });

  await assert.rejects(writeResponseToFile(response, destination, {
    expectedSize: 1,
    expectedSHA256: "a".repeat(64),
  }), { code: "EEXIST" });
  assert.equal(cancelCalls, 1);
  assert.equal(response.body.locked, false);
  assert.equal(await readFile(destination, "utf8"), "keep me");
});

test("an already-aborted download cancels the response before returning", async () => {
  const controller = new AbortController();
  const reason = new DOMException("Transfer superseded", "AbortError");
  controller.abort(reason);
  let cancelCalls = 0;
  const response = new Response(new ReadableStream({
    cancel() { cancelCalls += 1; },
  }));

  await assert.rejects(writeResponseToFile(response, "unused.part", {
    signal: controller.signal,
    expectedSize: 1,
    expectedSHA256: "a".repeat(64),
  }), { name: "AbortError" });
  assert.equal(cancelCalls, 1);
});

test("download cancellation interrupts a pending read and removes the partial file", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "resonance-stream-lifecycle-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const bytes = Buffer.from("pending download");
  const destination = path.join(directory, "pending.part");
  const controller = new AbortController();
  let startRead;
  const readStarted = new Promise((resolve) => { startRead = resolve; });
  let cancelCalls = 0;
  let cancelReason;
  const response = new Response(new ReadableStream({
    pull() { startRead(); },
    cancel(reason) {
      cancelCalls += 1;
      cancelReason = reason;
    },
  }, { highWaterMark: 0 }), { headers: { "content-length": String(bytes.length) } });
  const reason = new DOMException("Replaced by a newer transfer", "AbortError");

  const transfer = writeResponseToFile(response, destination, {
    signal: controller.signal,
    expectedSize: bytes.length,
    expectedSHA256: sha256(bytes),
  });
  await readStarted;
  controller.abort(reason);

  await assert.rejects(transfer, { name: "AbortError" });
  assert.equal(cancelCalls, 1);
  assert.equal(cancelReason, reason);
  assert.equal(response.body.locked, false);
  await assert.rejects(access(destination), { code: "ENOENT" });
});

test("relay cancellation wins a late upstream chunk and cleans up exactly once", async () => {
  let startRead;
  const readStarted = new Promise((resolve) => { startRead = resolve; });
  let upstream;
  let cancelCalls = 0;
  let completed = 0;
  let chunks = 0;
  const body = new ReadableStream({
    start(controller) { upstream = controller; },
    pull() { startRead(); },
    cancel() { cancelCalls += 1; },
  }, { highWaterMark: 0 });
  const relay = createExactLengthRelay(body, 4, () => { completed += 1; }, () => { chunks += 1; });
  const reader = relay.getReader();
  const pendingRead = reader.read();
  await readStarted;

  // Resolve the upstream read, then cancel before the relay's continuation runs.
  upstream.enqueue(Buffer.from("late"));
  const cancellation = reader.cancel("playback stopped");
  await cancellation;
  assert.deepEqual(await pendingRead, { done: true, value: undefined });
  assert.equal(cancelCalls, 1);
  assert.equal(body.locked, false);
  assert.equal(completed, 1);
  assert.equal(chunks, 0);
});
