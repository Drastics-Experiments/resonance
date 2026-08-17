export const INSTALL_STEPS = ["verify", "profile", "sign", "transfer"];
export const INSTALLATION_LEDGER_KEY = "resonance-installations-v1";

export function normalizeError(error) {
  if (!error) return { type: "unknown", message: "Something went wrong." };
  if (typeof error === "string") return { type: "unknown", message: error };
  if (typeof error.message === "string") {
    return { type: error.type || "unknown", message: error.message };
  }
  return { type: "unknown", message: JSON.stringify(error) };
}

export function railState(stage) {
  const order = ["connect", "account", "install", "success"];
  const current = Math.max(0, order.indexOf(stage));
  return ["connect", "account", "install"].map((id, index) => ({
    id,
    current: index === Math.min(current, 2),
    complete: index < current || stage === "success",
  }));
}

export function checklistState(activeStep, failedStep = null) {
  const activeIndex = INSTALL_STEPS.indexOf(activeStep);
  return INSTALL_STEPS.map((id, index) => ({
    id,
    state:
      id === failedStep
        ? "failed"
        : activeStep === "done" || index < activeIndex
          ? "complete"
          : index === activeIndex
            ? "working"
            : "pending",
  }));
}

export function formatExpiry(isoDate, locale = "en-US") {
  const date = new Date(isoDate);
  if (Number.isNaN(date.getTime())) return "Unknown";
  return new Intl.DateTimeFormat(locale, {
    weekday: "long",
    month: "long",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
}

export function refreshUrgency(isoDate, now = new Date()) {
  const expires = new Date(isoDate);
  const remaining = expires.getTime() - now.getTime();
  if (!Number.isFinite(remaining) || remaining <= 0) return "expired";
  if (remaining <= 48 * 60 * 60 * 1000) return "due";
  return "healthy";
}

function validDate(value) {
  return typeof value === "string" && Number.isFinite(new Date(value).getTime());
}

function normalizeInstallation(record) {
  if (
    !record ||
    typeof record.udid !== "string" ||
    !record.udid.trim() ||
    typeof record.name !== "string" ||
    !record.name.trim() ||
    typeof record.version !== "string" ||
    !record.version.trim() ||
    !validDate(record.installedAt) ||
    !validDate(record.expiresAt)
  ) {
    return null;
  }
  return {
    udid: record.udid.trim(),
    name: record.name.trim(),
    version: record.version.trim(),
    installedAt: new Date(record.installedAt).toISOString(),
    expiresAt: new Date(record.expiresAt).toISOString(),
  };
}

export function parseInstallationLedger(serialized) {
  if (!serialized) return [];
  try {
    const value = JSON.parse(serialized);
    if (value?.schemaVersion !== 1 || !Array.isArray(value.installations)) return [];
    const byDevice = new Map();
    for (const candidate of value.installations) {
      const record = normalizeInstallation(candidate);
      if (!record) continue;
      const existing = byDevice.get(record.udid);
      if (!existing || new Date(record.installedAt) > new Date(existing.installedAt)) {
        byDevice.set(record.udid, record);
      }
    }
    return [...byDevice.values()]
      .sort((left, right) => new Date(right.installedAt) - new Date(left.installedAt))
      .slice(0, 100);
  } catch {
    return [];
  }
}

export function serializeInstallationLedger(installations) {
  return JSON.stringify({ schemaVersion: 1, installations });
}

export function upsertInstallation(installations, candidate) {
  const record = normalizeInstallation(candidate);
  if (!record) throw new TypeError("Invalid installation record");
  return [record, ...installations.filter((item) => item.udid !== record.udid)].slice(0, 100);
}

export function sortInstallationsByRefresh(installations, now = new Date()) {
  const priority = { expired: 0, due: 1, healthy: 2 };
  return [...installations].sort((left, right) => {
    const urgencyDifference = priority[refreshUrgency(left.expiresAt, now)] - priority[refreshUrgency(right.expiresAt, now)];
    if (urgencyDifference !== 0) return urgencyDifference;
    return new Date(left.expiresAt) - new Date(right.expiresAt);
  });
}

export function refreshSummary(installations, now = new Date()) {
  const expired = installations.filter((record) => refreshUrgency(record.expiresAt, now) === "expired").length;
  const due = installations.filter((record) => refreshUrgency(record.expiresAt, now) === "due").length;
  return { expired, due };
}

export function formatCompactDate(isoDate, locale = "en-US") {
  const date = new Date(isoDate);
  if (Number.isNaN(date.getTime())) return "Unknown";
  return new Intl.DateTimeFormat(locale, {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
}

export function shortDeviceId(udid) {
  const value = String(udid || "");
  return value.length > 6 ? `…${value.slice(-6).toUpperCase()}` : value.toUpperCase();
}
