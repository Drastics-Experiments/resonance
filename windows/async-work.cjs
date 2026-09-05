/** Map in input order without opening a file/connection for every item at once. */
async function mapConcurrent(values, concurrency, map) {
  if (!Number.isSafeInteger(concurrency) || concurrency < 1) {
    throw new RangeError("Concurrency must be a positive integer.");
  }
  const items = Array.from(values);
  const results = new Array(items.length);
  let next = 0;
  let failed = false;
  let failure;

  async function worker() {
    while (!failed && next < items.length) {
      const index = next++;
      try {
        results[index] = await map(items[index], index);
      } catch (error) {
        if (!failed) failure = error;
        failed = true;
      }
    }
  }

  // Finish the active workers before rejecting so callers can safely clean up
  // resources. Once one fails, no additional work is started.
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, worker));
  if (failed) throw failure;
  return results;
}

/**
 * Serialize replacement snapshots, retaining only the latest pending value.
 * A superseded caller resolves only after its replacement has been written.
 * Values must be owned snapshots that callers do not mutate after enqueueing.
 */
function createLatestValueWriter(write, { prepare = (value) => value } = {}) {
  let running = false;
  let pending = null;

  async function drain() {
    while (pending) {
      const batch = pending;
      pending = null;
      try {
        await write(batch.value);
        batch.resolve();
      } catch (error) {
        batch.reject(error);
      }
    }
    running = false;
  }

  return function enqueue(value) {
    // Reject malformed input before it can replace an accepted pending value.
    try {
      value = prepare(value);
    } catch (error) {
      return Promise.reject(error);
    }
    pending ||= { ...Promise.withResolvers(), value };
    pending.value = value;
    if (!running) {
      running = true;
      queueMicrotask(drain);
    }
    return pending.promise;
  };
}

module.exports = { createLatestValueWriter, mapConcurrent };
