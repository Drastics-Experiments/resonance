function boundedText(value, maximumLength) {
  const text = typeof value === "string" ? value.trim() : "";
  return text ? text.slice(0, maximumLength) : null;
}

function safeURL(value, maximumLength = 8_192) {
  const text = boundedText(value, maximumLength);
  if (!text) return null;
  try {
    const url = new URL(text);
    if (!["https:", "http:"].includes(url.protocol) || url.username || url.password) return null;
    return url.href;
  } catch {
    return null;
  }
}

function boundedEvidence(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const entries = Object.entries(value).slice(0, 24).flatMap(([key, candidate]) => {
    const safeKey = boundedText(key, 64);
    if (!safeKey) return [];
    if (typeof candidate === "string") return [[safeKey, candidate.slice(0, 500)]];
    if (typeof candidate === "number" && Number.isFinite(candidate)) return [[safeKey, candidate]];
    if (typeof candidate === "boolean") return [[safeKey, candidate]];
    return [];
  });
  return entries.length ? Object.fromEntries(entries) : null;
}

function normalizeSingleSourceIdentity(value, fallback = {}) {
  const candidate = value && typeof value === "object" && !Array.isArray(value) ? value : {};
  const provider = boundedText(candidate.provider || fallback.provider, 64);
  const providerID = boundedText(candidate.providerID || candidate.providerId || fallback.providerID, 256);
  const sourcePageURL = safeURL(candidate.sourcePageURL || candidate.sourceURL || fallback.sourcePageURL || fallback.sourceURL);
  const mediaSourceURL = safeURL(candidate.mediaSourceURL || fallback.mediaSourceURL);
  const confidenceText = boundedText(candidate.confidence || fallback.confidence, 64);
  const rawScore = Number(candidate.score ?? fallback.score);
  const score = Number.isFinite(rawScore) ? Math.max(0, Math.min(1, rawScore)) : null;
  const evidence = boundedEvidence(candidate.evidence || fallback.evidence);
  if (!provider && !providerID && !sourcePageURL && !mediaSourceURL && !confidenceText && score === null && !evidence) return null;
  return {
    provider,
    providerID,
    sourcePageURL,
    mediaSourceURL,
    confidence: confidenceText,
    score,
    evidence,
  };
}

function normalizeSourceIdentities(value, additional = []) {
  const candidates = [
    ...(Array.isArray(value) ? value : []),
    ...(Array.isArray(additional) ? additional : [additional]),
  ];
  const seen = new Set();
  const identities = [];
  for (const candidate of candidates) {
    const identity = normalizeSingleSourceIdentity(candidate);
    if (!identity) continue;
    const key = JSON.stringify([
      identity.provider,
      identity.providerID,
      identity.sourcePageURL,
      identity.mediaSourceURL,
      identity.confidence,
      identity.score,
      identity.evidence,
    ]);
    if (seen.has(key)) continue;
    seen.add(key);
    identities.push(identity);
    if (identities.length >= 8) break;
  }
  return identities;
}

function normalizeSourceIdentity(value, fallback = {}) {
  const candidate = value && typeof value === "object" && !Array.isArray(value) ? value : {};
  const identity = normalizeSingleSourceIdentity(candidate, fallback);
  if (!identity) return null;
  const aliases = normalizeSourceIdentities(candidate.aliases, fallback.aliases);
  return aliases.length ? { ...identity, aliases } : identity;
}

module.exports = {
  normalizeSourceIdentity,
  normalizeSourceIdentities,
};
