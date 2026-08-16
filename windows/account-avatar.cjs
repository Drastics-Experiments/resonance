const { readResponseBytes } = require("./response-body.cjs");

const ACCOUNT_AVATAR_HOSTS = Object.freeze([
  "images.clerk.dev",
  "img.clerk.com",
]);
const ACCOUNT_AVATAR_HOST_SET = new Set(ACCOUNT_AVATAR_HOSTS);
const MAX_ACCOUNT_AVATAR_BYTES = 2 * 1024 * 1024;
const MAX_ACCOUNT_AVATAR_REDIRECTS = 5;
const MAX_ACCOUNT_AVATAR_FETCH_MS = 15_000;
const MAX_ACCOUNT_AVATAR_URL_LENGTH = 8_192;
const MAX_ACCOUNT_AVATAR_SIDE = 4_096;
const MAX_ACCOUNT_AVATAR_PIXELS = 16_777_216;
const MAX_ACCOUNT_AVATAR_DATA_URL_LENGTH = 4 * 1024 * 1024;
const ACCOUNT_AVATAR_CONTENT_TYPES = new Set([
  "image/avif",
  "image/gif",
  "image/jpeg",
  "image/png",
  "image/webp",
]);
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

function isPrivateHost(rawHost) {
  let host = String(rawHost || "").trim().replace(/^\[|\]$/g, "").toLocaleLowerCase();
  while (host.endsWith(".")) host = host.slice(0, -1);
  if (!host) return true;
  if (host === "localhost"
      || host.endsWith(".localhost")
      || host.endsWith(".local")
      || host.endsWith(".internal")
      || host.endsWith(".lan")
      || host.endsWith(".home.arpa")) return true;

  const octets = host.split(".");
  const values = octets.map((value) => Number(value));
  const privateIPv4 = octets.length === 4
    && octets.every((value) => /^\d{1,3}$/.test(value))
    && values.every((value) => value >= 0 && value <= 255)
    && (values[0] === 0
      || values[0] === 10
      || values[0] === 127
      || values[0] >= 224
      || (values[0] === 100 && values[1] >= 64 && values[1] <= 127)
      || (values[0] === 169 && values[1] === 254)
      || (values[0] === 172 && values[1] >= 16 && values[1] <= 31)
      || (values[0] === 192 && values[1] === 0)
      || (values[0] === 192 && values[1] === 168)
      || (values[0] === 198 && (values[1] === 18 || values[1] === 19)));
  if (privateIPv4 || (/^\d+$/.test(host) && host.length > 0)) return true;
  if (host.includes(":")) {
    const embeddedIPv4 = host.split(":").at(-1);
    if (embeddedIPv4 && isPrivateHost(embeddedIPv4)) return true;
    if (host === "::" || host === "::1" || /^f[cd]/.test(host) || /^fe[89ab]/.test(host) || host.startsWith("ff")) return true;
  }
  return false;
}

function allowedAccountAvatarURL(value) {
  let url;
  const rawValue = String(value || "").trim();
  try { url = new URL(rawValue); }
  catch { return null; }
  const host = url.hostname.toLocaleLowerCase();
  const authority = rawValue.match(/^[a-z][a-z\d+.-]*:\/\/([^\/?#]*)/i)?.[1] || "";
  if (url.protocol !== "https:"
      || url.username
      || url.password
      || authority.includes("@")
      || url.href.includes("#")
      || Buffer.byteLength(url.href, "utf8") > MAX_ACCOUNT_AVATAR_URL_LENGTH
      || (url.port && url.port !== "443")
      || !ACCOUNT_AVATAR_HOST_SET.has(host)
      || isPrivateHost(host)) return null;
  return url;
}

function isSafeAccountAvatarDataURL(value) {
  const candidate = typeof value === "string" ? value.trim() : "";
  if (!candidate || candidate.length > MAX_ACCOUNT_AVATAR_DATA_URL_LENGTH) return null;
  return /^data:image\/(?:avif|gif|jpeg|png|webp);base64,[A-Za-z0-9+/]+={0,2}$/.test(candidate)
    ? candidate
    : null;
}

function isWithinAccountAvatarPixelBounds(width, height) {
  return Number.isSafeInteger(width)
    && Number.isSafeInteger(height)
    && width > 0
    && height > 0
    && width <= MAX_ACCOUNT_AVATAR_SIDE
    && height <= MAX_ACCOUNT_AVATAR_SIDE
    && width * height <= MAX_ACCOUNT_AVATAR_PIXELS;
}

async function cancelResponseBody(response) {
  try { await response?.body?.cancel?.(); }
  catch { /* cancellation is best effort before rejecting the image */ }
}

/**
 * Fetch and decode an account avatar without allowing an arbitrary remote URL
 * to reach the renderer. Every redirect is manually validated against the
 * same public Clerk image allowlist and the response is bounded before decode.
 */
async function fetchAccountAvatar(value, {
  fetchImpl = fetch,
  decodeImage,
  signal = null,
} = {}) {
  if (typeof decodeImage !== "function") throw new TypeError("An account avatar decoder is required.");
  let current = allowedAccountAvatarURL(value);
  if (!current) return null;
  const requestSignal = signal || (
    typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function"
      ? AbortSignal.timeout(MAX_ACCOUNT_AVATAR_FETCH_MS)
      : undefined
  );

  for (let redirects = 0; ; redirects += 1) {
    let response;
    try {
      response = await fetchImpl(current, {
        headers: { Accept: "image/avif,image/webp,image/png,image/jpeg,image/gif" },
        cache: "no-store",
        credentials: "omit",
        redirect: "manual",
        ...(requestSignal ? { signal: requestSignal } : {}),
      });
    } catch {
      return null;
    }

    if (REDIRECT_STATUSES.has(response.status)) {
      const location = response.headers?.get?.("location");
      await cancelResponseBody(response);
      if (redirects >= MAX_ACCOUNT_AVATAR_REDIRECTS || !location) return null;
      try { current = allowedAccountAvatarURL(new URL(location, current)); }
      catch { current = null; }
      if (!current) return null;
      continue;
    }

    const finalURL = allowedAccountAvatarURL(response.url || current);
    const contentType = String(response.headers?.get?.("content-type") || "")
      .split(";", 1)[0]
      .trim()
      .toLocaleLowerCase();
    if (!finalURL || response.status < 200 || response.status >= 300 || !ACCOUNT_AVATAR_CONTENT_TYPES.has(contentType)) {
      await cancelResponseBody(response);
      return null;
    }

    let bytes;
    try { bytes = await readResponseBytes(response, MAX_ACCOUNT_AVATAR_BYTES, "Account avatar"); }
    catch { return null; }
    if (!bytes.length) return null;

    let decoded;
    try { decoded = await decodeImage(bytes, { contentType, url: finalURL }); }
    catch { return null; }
    if (!decoded || !isWithinAccountAvatarPixelBounds(decoded.width, decoded.height)) return null;
    return isSafeAccountAvatarDataURL(decoded.dataURL);
  }
}

module.exports = {
  ACCOUNT_AVATAR_CONTENT_TYPES,
  ACCOUNT_AVATAR_HOSTS,
  MAX_ACCOUNT_AVATAR_BYTES,
  MAX_ACCOUNT_AVATAR_DATA_URL_LENGTH,
  MAX_ACCOUNT_AVATAR_FETCH_MS,
  MAX_ACCOUNT_AVATAR_URL_LENGTH,
  MAX_ACCOUNT_AVATAR_PIXELS,
  MAX_ACCOUNT_AVATAR_REDIRECTS,
  MAX_ACCOUNT_AVATAR_SIDE,
  allowedAccountAvatarURL,
  fetchAccountAvatar,
  isPrivateHost,
  isSafeAccountAvatarDataURL,
  isWithinAccountAvatarPixelBounds,
};
