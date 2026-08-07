function policyError(errorFactory, message) {
  const error = typeof errorFactory === "function" ? errorFactory(message) : new Error(message);
  return error instanceof Error ? error : new Error(message);
}

function signedDeadline(config) {
  if (config?.verified !== true) return null;
  const deadline = Date.parse(config.expires_at);
  return Number.isFinite(deadline) ? deadline : NaN;
}

function createRenewablePolicyLease(options = {}) {
  const {
    initialConfig,
    renew,
    parentSignal,
    allowUnsignedInitial = false,
    renewalLeadMs = 60_000,
    retryDelayMs = 5_000,
    now = Date.now,
    setTimer = setTimeout,
    clearTimer = clearTimeout,
    errorFactory,
  } = options;
  if ((renew !== undefined && renew !== null && typeof renew !== "function")
      || typeof now !== "function"
      || typeof setTimer !== "function"
      || typeof clearTimer !== "function") {
    throw new TypeError("A clock, timer implementation, and optional renewal function are required.");
  }

  const controller = new AbortController();
  let expirationTimer = null;
  let renewalTimer = null;
  let deadline = signedDeadline(initialConfig);
  let closed = false;
  let renewing = false;
  const unsigned = initialConfig?.verified !== true;
  if (unsigned && !(allowUnsignedInitial && !initialConfig?.expires_at)) {
    throw policyError(errorFactory, "A valid signed policy lease is required.");
  }
  if (!unsigned && (!Number.isFinite(deadline) || deadline <= now())) {
    throw policyError(errorFactory, "The signed policy authorization has expired.");
  }

  const clearTimers = () => {
    if (expirationTimer !== null) clearTimer(expirationTimer);
    if (renewalTimer !== null) clearTimer(renewalTimer);
    expirationTimer = null;
    renewalTimer = null;
  };
  const abortForPolicy = (message) => {
    if (!controller.signal.aborted) {
      controller.abort(policyError(errorFactory, message || "Policy authorization expired or was revoked."));
    }
    clearTimers();
  };
  const abortForParent = () => {
    if (!controller.signal.aborted) {
      controller.abort(parentSignal?.reason instanceof Error
        ? parentSignal.reason
        : new DOMException("Transfer cancelled", "AbortError"));
    }
    clearTimers();
  };
  if (parentSignal?.aborted) abortForParent();
  else parentSignal?.addEventListener("abort", abortForParent, { once: true });

  const scheduleRetry = () => {
    if (closed || controller.signal.aborted || unsigned || typeof renew !== "function") return;
    const remaining = deadline - now();
    if (remaining <= 0) {
      abortForPolicy();
      return;
    }
    const delay = Math.max(0, Math.min(Math.max(1, retryDelayMs), remaining - 1));
    renewalTimer = setTimer(() => { void renewLease(); }, delay);
    renewalTimer?.unref?.();
  };

  const renewLease = async () => {
    if (closed || controller.signal.aborted || unsigned || typeof renew !== "function" || renewing) return;
    renewing = true;
    try {
      const renewed = await renew();
      if (closed || controller.signal.aborted) return;
      const nextDeadline = signedDeadline(renewed);
      if (renewed?.source === "remote"
          && Number.isFinite(nextDeadline)
          && nextDeadline > deadline
          && nextDeadline > now()) {
        deadline = nextDeadline;
        armSignedLease();
      } else if (renewed?.source === "remote"
          && Number.isFinite(nextDeadline)
          && nextDeadline < deadline) {
        // A freshly verified server response is authoritative even when it
        // shortens the lease. Re-arm even if the shorter deadline elapsed
        // while renewal was in flight so it revokes immediately instead of
        // retaining the older, longer authorization. A same-expiry cached
        // response merely retries.
        deadline = nextDeadline;
        armSignedLease();
      } else {
        scheduleRetry();
      }
    } catch (error) {
      if (closed || controller.signal.aborted) return;
      if (error?.verifiedRevocation === true) {
        abortForPolicy(error.message || "Policy authorization was revoked.");
      } else {
        scheduleRetry();
      }
    } finally {
      renewing = false;
    }
  };

  const armSignedLease = () => {
    clearTimers();
    const remaining = deadline - now();
    if (remaining <= 0) {
      abortForPolicy();
      return;
    }
    expirationTimer = setTimer(() => abortForPolicy(), remaining);
    expirationTimer?.unref?.();
    const lead = Math.max(0, Math.min(Number(renewalLeadMs) || 0, remaining));
    if (typeof renew === "function") {
      renewalTimer = setTimer(() => { void renewLease(); }, Math.max(0, remaining - lead));
      renewalTimer?.unref?.();
    }
  };

  if (!unsigned && !controller.signal.aborted) armSignedLease();

  const assertAuthorized = () => {
    if (!unsigned && !controller.signal.aborted && now() >= deadline) abortForPolicy();
    controller.signal.throwIfAborted();
    return true;
  };
  return {
    signal: controller.signal,
    get deadline() { return unsigned ? null : deadline; },
    assertActive: assertAuthorized,
    assertAuthorized,
    close() {
      if (closed) return;
      closed = true;
      clearTimers();
      parentSignal?.removeEventListener("abort", abortForParent);
    },
  };
}

module.exports = { createRenewablePolicyLease };
