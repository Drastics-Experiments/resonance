function isExplicitLoopbackHostname(hostname) {
  const value = String(hostname || "").toLocaleLowerCase().replace(/\.$/, "");
  return value === "localhost" || value === "127.0.0.1" || value === "[::1]" || value === "::1";
}

function normalizeServerBaseURL(value, { allowInsecureLoopback = false } = {}) {
  const url = new URL(String(value || "").trim());
  const secure = url.protocol === "https:";
  const permittedDevelopmentURL = allowInsecureLoopback
    && url.protocol === "http:"
    && isExplicitLoopbackHostname(url.hostname);
  if (!secure && !permittedDevelopmentURL) {
    throw new Error("Use an https:// server URL. Plain http:// is allowed only for a local development server.");
  }
  if (url.username || url.password) throw new Error("Do not put credentials in the server URL.");
  url.hash = "";
  url.search = "";
  url.pathname = url.pathname.replace(/\/+$/, "") + "/";
  return url;
}

function catalogSHA256(song) {
  const value = String(song?.content_sha256 || song?.contentSha256 || song?.sha256 || "").trim().toLocaleLowerCase();
  return /^[a-f0-9]{64}$/.test(value) ? value : null;
}

module.exports = {
  catalogSHA256,
  isExplicitLoopbackHostname,
  normalizeServerBaseURL,
};
