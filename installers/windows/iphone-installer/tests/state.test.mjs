import assert from "node:assert/strict";
import test from "node:test";
import {
  checklistState,
  formatCompactDate,
  formatExpiry,
  parseInstallationLedger,
  refreshSummary,
  normalizeError,
  railState,
  refreshUrgency,
  serializeInstallationLedger,
  shortDeviceId,
  sortInstallationsByRefresh,
  upsertInstallation,
} from "../ui/state.mjs";

test("rail marks completed and current steps", () => {
  assert.deepEqual(railState("account"), [
    { id: "connect", current: false, complete: true },
    { id: "account", current: true, complete: false },
    { id: "install", current: false, complete: false },
  ]);
});

test("checklist progresses without claiming future work", () => {
  const states = checklistState("sign");
  assert.deepEqual(states.map((item) => item.state), ["complete", "complete", "working", "pending"]);
});

test("failed checklist step takes precedence", () => {
  const states = checklistState("sign", "sign");
  assert.equal(states[2].state, "failed");
});

test("normalizes structured and string errors", () => {
  assert.deepEqual(normalizeError({ type: "auth", message: "Denied" }), { type: "auth", message: "Denied" });
  assert.deepEqual(normalizeError("Disconnected"), { type: "unknown", message: "Disconnected" });
});

test("refresh urgency uses a 48 hour window", () => {
  const now = new Date("2026-08-16T12:00:00Z");
  assert.equal(refreshUrgency("2026-08-16T11:59:00Z", now), "expired");
  assert.equal(refreshUrgency("2026-08-18T11:59:00Z", now), "due");
  assert.equal(refreshUrgency("2026-08-18T12:01:00Z", now), "healthy");
});

test("formats an expiry date", () => {
  assert.match(formatExpiry("2026-08-23T12:00:00Z", "en-US"), /August 23/);
  assert.equal(formatExpiry("not-a-date"), "Unknown");
});

const installation = {
  udid: "00008140-0012345678901234",
  name: "Lily's iPhone",
  version: "2.0.3",
  installedAt: "2026-08-16T12:00:00Z",
  expiresAt: "2026-08-23T12:00:00Z",
};

test("installation ledger persists one current record per phone", () => {
  const updated = upsertInstallation([installation], {
    ...installation,
    version: "2.0.4",
    installedAt: "2026-08-17T12:00:00Z",
    expiresAt: "2026-08-24T12:00:00Z",
  });
  const restored = parseInstallationLedger(serializeInstallationLedger(updated));
  assert.equal(restored.length, 1);
  assert.equal(restored[0].version, "2.0.4");
  assert.equal(restored[0].expiresAt, "2026-08-24T12:00:00.000Z");
});

test("installation ledger ignores malformed records", () => {
  const payload = JSON.stringify({
    schemaVersion: 1,
    installations: [installation, { name: "Missing identity" }],
  });
  assert.equal(parseInstallationLedger(payload).length, 1);
  assert.deepEqual(parseInstallationLedger("not-json"), []);
});

test("refresh ordering surfaces expired and due phones first", () => {
  const now = new Date("2026-08-20T12:00:00Z");
  const healthy = { ...installation, udid: "healthy", expiresAt: "2026-08-25T12:00:00Z" };
  const due = { ...installation, udid: "due", expiresAt: "2026-08-21T12:00:00Z" };
  const expired = { ...installation, udid: "expired", expiresAt: "2026-08-19T12:00:00Z" };
  assert.deepEqual(sortInstallationsByRefresh([healthy, due, expired], now).map((item) => item.udid), ["expired", "due", "healthy"]);
  assert.deepEqual(refreshSummary([healthy, due, expired], now), { expired: 1, due: 1 });
});

test("compact installation labels are readable", () => {
  assert.match(formatCompactDate("2026-08-23T12:00:00Z", "en-US"), /Aug 23/);
  assert.equal(shortDeviceId(installation.udid), "…901234");
});
