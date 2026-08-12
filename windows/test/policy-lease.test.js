import assert from "node:assert/strict";
import test from "node:test";
import policyLease from "../policy-lease.cjs";

const { createRenewablePolicyLease } = policyLease;

function signed(expiresAt) {
  return { verified: true, expires_at: new Date(expiresAt).toISOString() };
}

function fakeTime(start = 1_000) {
  let current = start;
  let sequence = 0;
  const timers = new Map();
  const setTimer = (callback, delay) => {
    const id = ++sequence;
    timers.set(id, { at: current + Math.max(0, Number(delay) || 0), callback });
    return id;
  };
  const clearTimer = (id) => timers.delete(id);
  const advance = async (milliseconds) => {
    const target = current + milliseconds;
    while (true) {
      const next = [...timers.entries()]
        .filter(([, timer]) => timer.at <= target)
        .sort((left, right) => left[1].at - right[1].at || left[0] - right[0])[0];
      if (!next) break;
      timers.delete(next[0]);
      current = next[1].at;
      next[1].callback();
      await Promise.resolve();
      await Promise.resolve();
    }
    current = Math.max(current, target);
    await Promise.resolve();
  };
  return {
    now: () => current,
    setCurrent(value) { current = value; },
    setTimer,
    clearTimer,
    advance,
    timers,
  };
}

test("legacy safe file-cache policy remains usable without an artificial expiry", () => {
  const clock = fakeTime();
  const lease = createRenewablePolicyLease({
    initialConfig: { verified: false },
    allowUnsignedInitial: true,
    renew: async () => { throw new Error("must not renew"); },
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  });
  assert.equal(lease.deadline, null);
  assert.equal(lease.assertActive(), true);
  assert.equal(clock.timers.size, 0);
  lease.close();
});

test("a fixed signed lease never renews and remains bounded by its captured expiry", () => {
  const clock = fakeTime();
  const lease = createRenewablePolicyLease({
    initialConfig: signed(11_000),
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  });
  assert.equal(lease.deadline, 11_000);
  assert.equal(clock.timers.size, 1);
  lease.close();
});

test("same-expiry and transient renewals retry before the old deadline", async () => {
  const clock = fakeTime();
  let attempts = 0;
  const lease = createRenewablePolicyLease({
    initialConfig: signed(11_000),
    renew: async () => {
      attempts += 1;
      if (attempts === 1) return signed(11_000);
      if (attempts === 2) throw new Error("temporary network failure");
      return { ...signed(31_000), source: "remote" };
    },
    renewalLeadMs: 5_000,
    retryDelayMs: 1_000,
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  });
  await clock.advance(5_000);
  assert.equal(attempts, 1);
  await clock.advance(1_000);
  assert.equal(attempts, 2);
  await clock.advance(1_000);
  assert.equal(attempts, 3);
  assert.equal(lease.deadline, 31_000);
  assert.equal(lease.signal.aborted, false);
  lease.close();
});

test("an active signed lease can refresh immediately without delaying its authorization", async () => {
  const clock = fakeTime();
  let releaseRefresh;
  const refreshPending = new Promise((resolve) => { releaseRefresh = resolve; });
  let attempts = 0;
  const lease = createRenewablePolicyLease({
    initialConfig: signed(11_000),
    renew: async () => {
      attempts += 1;
      await refreshPending;
      return { ...signed(21_000), source: "remote" };
    },
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  });
  const refresh = lease.refresh();
  assert.equal(lease.refresh(), refresh);
  assert.equal(attempts, 1);
  assert.equal(lease.assertAuthorized(), true);
  assert.equal(lease.deadline, 11_000);
  releaseRefresh();
  await refresh;
  assert.equal(lease.deadline, 21_000);
  lease.close();
});

test("the concrete refresh settles before final authorization observes a revocation", async () => {
  const clock = fakeTime();
  let releaseRefresh;
  const refreshPending = new Promise((resolve) => { releaseRefresh = resolve; });
  const revoked = Object.assign(new Error("Offline downloads were revoked."), { verifiedRevocation: true });
  const lease = createRenewablePolicyLease({
    initialConfig: signed(11_000),
    renew: async () => {
      await refreshPending;
      throw revoked;
    },
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  });
  const refresh = lease.refresh();
  assert.equal(lease.assertAuthorized(), true);
  releaseRefresh();
  await refresh;
  assert.throws(() => lease.assertAuthorized(), /revoked/);
  lease.close();
});

test("a later-expiry cache fallback retains but never extends the current lease", async () => {
  const clock = fakeTime();
  let attempts = 0;
  const lease = createRenewablePolicyLease({
    initialConfig: signed(11_000),
    renew: async () => {
      attempts += 1;
      return { ...signed(31_000), source: "cache" };
    },
    renewalLeadMs: 5_000,
    retryDelayMs: 1_000,
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  });
  await clock.advance(5_000);
  assert.equal(attempts, 1);
  assert.equal(lease.deadline, 11_000);
  assert.equal(lease.signal.aborted, false);
  lease.close();
});

test("a verified revocation aborts immediately while an elapsed deadline fails even if timers lag", async () => {
  const clock = fakeTime();
  const revoked = Object.assign(new Error("Offline downloads were revoked."), { verifiedRevocation: true });
  const lease = createRenewablePolicyLease({
    initialConfig: signed(11_000),
    renew: async () => { throw revoked; },
    renewalLeadMs: 5_000,
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  });
  await clock.advance(6_000);
  assert.equal(lease.signal.aborted, true);
  assert.match(lease.signal.reason.message, /revoked/);

  let current = 1_000;
  const lagged = createRenewablePolicyLease({
    initialConfig: signed(2_000),
    renew: async () => signed(3_000),
    now: () => current,
    setTimer: () => 1,
    clearTimer: () => {},
  });
  current = 2_000;
  assert.throws(() => lagged.assertActive(), /expired|revoked/);
});

test("a freshly verified remote renewal can shorten but never silently retain a longer lease", async () => {
  const clock = fakeTime();
  const lease = createRenewablePolicyLease({
    initialConfig: signed(21_000),
    renew: async () => ({ ...signed(16_000), source: "remote" }),
    renewalLeadMs: 15_000,
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  });
  await clock.advance(5_000);
  assert.equal(lease.deadline, 16_000);
  assert.equal(lease.signal.aborted, false);
  lease.close();
});

test("a remote renewal whose shorter deadline elapsed in flight aborts immediately", async () => {
  const clock = fakeTime();
  const lease = createRenewablePolicyLease({
    initialConfig: signed(11_000),
    renew: async () => {
      clock.setCurrent(7_000);
      return { ...signed(6_500), source: "remote" };
    },
    renewalLeadMs: 5_000,
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  });
  await clock.advance(5_000);
  assert.equal(lease.deadline, 6_500);
  assert.equal(lease.signal.aborted, true);
  assert.match(lease.signal.reason.message, /expired|revoked/);
  lease.close();
});

test("parent cancellation and close clean up a lease", () => {
  const clock = fakeTime();
  const parent = new AbortController();
  const lease = createRenewablePolicyLease({
    initialConfig: signed(11_000),
    renew: async () => signed(21_000),
    parentSignal: parent.signal,
    now: clock.now,
    setTimer: clock.setTimer,
    clearTimer: clock.clearTimer,
  });
  parent.abort(new DOMException("Cancelled", "AbortError"));
  assert.equal(lease.signal.aborted, true);
  assert.equal(lease.signal.reason.name, "AbortError");
  lease.close();
  assert.equal(clock.timers.size, 0);
});
