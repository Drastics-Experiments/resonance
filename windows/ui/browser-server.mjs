import { createServer } from "node:http";
import { createHash, randomBytes } from "node:crypto";
import { promises as fs } from "node:fs";
import { networkInterfaces } from "node:os";
import { Readable } from "node:stream";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const UI_ROOT = path.resolve(fileURLToPath(new URL(".", import.meta.url)));
const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 4173;
const PRODUCTION_ORIGIN = "https://resonance-core.blithe-haven-9710.chatgpt.site";
const CLERK_ORIGIN = "https://clerk.unblocked.mov";
const CLERK_BROWSER_SCRIPT = `${CLERK_ORIGIN}/npm/@clerk/clerk-js@5/dist/clerk.browser.js`;
const MAX_BROWSER_REQUEST_BYTES = 2 * 1024 * 1024;
const BROWSER_STREAM_TTL_MS = 15 * 60 * 1000;
// The renderer has a small number of data-driven style attributes (waveform
// bars, ruler labels, and the storage ring). Keep stylesheet loading strict,
// but scope the inline exception to attributes rather than allowing inline
// <style> blocks. Browser-local imports use blob: media. API and streaming
// traffic remain same-origin; Clerk is the only direct external connection.
const BROWSER_CSP = `default-src 'self'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; media-src 'self' blob:; img-src 'self' data: https:; connect-src 'self' blob: ${CLERK_ORIGIN}; object-src 'none'; frame-src ${CLERK_ORIGIN} https://challenges.cloudflare.com; base-uri 'none'; form-action 'self' ${CLERK_ORIGIN}`;

const CONTENT_TYPES = Object.freeze({
  ".css": "text/css; charset=utf-8",
  ".gif": "image/gif",
  ".html": "text/html; charset=utf-8",
  ".ico": "image/x-icon",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".wav": "audio/wav",
  ".webm": "video/webm",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
});

function isTailscaleIPv4(address) {
  const octets = String(address).split(".").map(Number);
  return octets.length === 4
    && octets.every((octet) => Number.isInteger(octet) && octet >= 0 && octet <= 255)
    && octets[0] === 100
    && octets[1] >= 64
    && octets[1] <= 127;
}

function tailscaleIPv4Host(interfaces = networkInterfaces()) {
  const candidates = Object.values(interfaces)
    .flatMap((addresses) => addresses || [])
    .filter((entry) => (entry.family === "IPv4" || entry.family === 4) && !entry.internal)
    .map((entry) => entry.address)
    .filter(isTailscaleIPv4)
    .sort();
  if (!candidates.length) {
    throw new Error("No active Tailscale IPv4 address was found.");
  }
  return candidates[0];
}

function responseHeaders(contentType, length = null) {
  return {
    "Cache-Control": "no-store",
    "Content-Security-Policy": BROWSER_CSP,
    "Content-Type": contentType,
    "Cross-Origin-Resource-Policy": "same-origin",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    ...(length === null ? {} : { "Content-Length": String(length) }),
  };
}

function send(response, statusCode, body = "", headers = {}) {
  const payload = Buffer.isBuffer(body) ? body : Buffer.from(String(body));
  response.writeHead(statusCode, {
    "Content-Length": String(payload.length),
    "Content-Type": "text/plain; charset=utf-8",
    ...headers,
  });
  if (response.req?.method !== "HEAD") response.end(payload);
  else response.end();
}

function redirect(response, location) {
  response.writeHead(302, {
    Location: location,
    "Cache-Control": "no-store",
    "Content-Length": "0",
  });
  response.end();
}

function sendJSON(response, statusCode, value, headers = {}) {
  send(response, statusCode, JSON.stringify(value), {
    "Cache-Control": "no-store",
    "Content-Type": "application/json; charset=utf-8",
    ...headers,
  });
}

function bearerToken(request) {
  const match = /^Bearer ([^\s]+)$/.exec(String(request.headers.authorization || ""));
  const token = match?.[1] || "";
  return token && token.length <= 16 * 1024 && !/[\u0000-\u001f\u007f]/.test(token) ? token : null;
}

function profileID(request) {
  const value = String(request.headers["x-resonance-profile"] || "default");
  return value && value.length <= 128 && !/[\u0000-\u001f\u007f]/.test(value) ? value : "default";
}

async function requestBody(request, maximumBytes = MAX_BROWSER_REQUEST_BYTES) {
  const chunks = [];
  let total = 0;
  for await (const chunk of request) {
    total += chunk.length;
    if (total > maximumBytes) throw Object.assign(new Error("Request body is too large."), { statusCode: 413 });
    chunks.push(chunk);
  }
  return Buffer.concat(chunks, total);
}

function upstreamHeaders(request, token, { json = false } = {}) {
  return {
    Accept: String(request.headers.accept || (json ? "application/json" : "*/*")),
    Authorization: `Bearer ${token}`,
    "X-Resonance-Profile": profileID(request),
    ...(json ? { "Content-Type": "application/json" } : {}),
  };
}

function relayHeaders(upstream, extra = {}) {
  const headers = {
    "Cache-Control": "no-store, private",
    "Content-Type": upstream.headers.get("content-type") || "application/octet-stream",
    "X-Content-Type-Options": "nosniff",
    ...extra,
  };
  for (const name of ["accept-ranges", "content-length", "content-range", "etag", "last-modified"]) {
    const value = upstream.headers.get(name);
    if (value) headers[name] = value;
  }
  return headers;
}

async function relayUpstream(response, request, upstream, extraHeaders = {}) {
  response.writeHead(upstream.status, relayHeaders(upstream, extraHeaders));
  if (request.method === "HEAD" || !upstream.body) {
    upstream.body?.cancel?.().catch?.(() => undefined);
    response.end();
    return;
  }
  Readable.fromWeb(upstream.body).on("error", () => response.destroy()).pipe(response);
}

function browserHTML(contents) {
  return contents.replace(
    /(<meta\s+http-equiv="Content-Security-Policy"\s+content=")[^"]*(">)/i,
    `$1${BROWSER_CSP}$2`,
  );
}

function historyTrackID(profile, songID) {
  const digest = createHash("sha256")
    .update("resonance-remote-stream-history-v1\n", "utf8")
    .update(PRODUCTION_ORIGIN, "utf8")
    .update("\n", "utf8")
    .update(profile, "utf8")
    .update("\n", "utf8")
    .update(songID, "utf8")
    .digest("hex");
  return `remote-stream:${digest}`;
}

function safeSongID(value) {
  const songID = String(value || "").trim();
  return songID && songID.length <= 128 && !/[\u0000-\u001f\u007f]/.test(songID) ? songID : null;
}

function sameOriginMediaURL(value) {
  try {
    const url = new URL(String(value || ""), PRODUCTION_ORIGIN);
    return url.origin === PRODUCTION_ORIGIN && !url.username && !url.password && !url.hash ? url : null;
  } catch {
    return null;
  }
}

let clerkBrowserScriptCache = null;
const clerkAssetCache = new Map();

async function boundedJSONResponse(response, maximumBytes = 16 * 1024 * 1024) {
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maximumBytes) throw new Error("The server response is too large.");
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > maximumBytes) throw new Error("The server response is too large.");
  return JSON.parse(bytes.toString("utf8"));
}

async function proxyBrowserAPI(request, response, pathname, search = "") {
  const token = bearerToken(request);
  if (!token) {
    sendJSON(response, 401, { error: "Sign in to your Resonance account." });
    return;
  }
  const method = String(request.method || "GET").toUpperCase();
  const body = ["POST", "PUT", "PATCH"].includes(method) ? await requestBody(request) : null;
  const upstream = await fetch(`${PRODUCTION_ORIGIN}${pathname}${search}`, {
    method,
    headers: upstreamHeaders(request, token, { json: Boolean(body?.length) }),
    body: body?.length ? body : undefined,
    redirect: "manual",
    signal: AbortSignal.timeout(30_000),
  });
  await relayUpstream(response, request, upstream);
}

async function createBrowserStream(request, response, streamSessions) {
  const token = bearerToken(request);
  if (!token) {
    sendJSON(response, 401, { error: "Sign in to your Resonance account." });
    return;
  }
  const body = await requestBody(request, 16 * 1024);
  let input;
  try { input = JSON.parse(body.toString("utf8")); }
  catch {
    sendJSON(response, 400, { error: "A valid stream request is required." });
    return;
  }
  const songID = safeSongID(input?.songID);
  if (!songID) {
    sendJSON(response, 400, { error: "A valid catalog song is required." });
    return;
  }
  const profile = profileID(request);
  const catalogResponse = await fetch(`${PRODUCTION_ORIGIN}/api/v1/songs`, {
    headers: upstreamHeaders(request, token, { json: true }),
    redirect: "manual",
    signal: AbortSignal.timeout(20_000),
  });
  if (!catalogResponse.ok) {
    await relayUpstream(response, request, catalogResponse);
    return;
  }
  const catalog = await boundedJSONResponse(catalogResponse);
  const matches = Array.isArray(catalog?.songs) ? catalog.songs.filter((song) => song?.id === songID) : [];
  if (matches.length !== 1) {
    sendJSON(response, matches.length ? 502 : 404, { error: matches.length ? "The server returned an ambiguous song." : "The catalog song is unavailable." });
    return;
  }
  const song = matches[0];
  const songFilename = String(song.filename || song.name || "").split(/[?#]/, 1)[0];
  if (song.media_kind === "video"
      || String(song.content_type || "").startsWith("video/")
      || /\.(?:avi|mkv|mov|mp4|m4v|webm)$/i.test(songFilename)) {
    sendJSON(response, 415, { error: "Browser stream-only playback currently supports audio songs." });
    return;
  }
  const mediaURL = sameOriginMediaURL(song?.media_location?.stream_url || song.stream_url || `/api/v1/songs/${encodeURIComponent(songID)}/stream`);
  if (!mediaURL) {
    sendJSON(response, 502, { error: "The server returned an invalid stream location." });
    return;
  }
  const sessionID = randomBytes(32).toString("hex");
  const session = { token, profile, songID, song, mediaURL, createdAt: Date.now() };
  streamSessions.set(sessionID, session);
  while (streamSessions.size > 64) streamSessions.delete(streamSessions.keys().next().value);
  sendJSON(response, 200, {
    url: `/api/browser/streams/${sessionID}`,
    historyTrackID: historyTrackID(profile, songID),
  });
}

async function refreshBrowserStreamLocation(session) {
  const refreshURL = sameOriginMediaURL(
    session.song?.media_location?.refresh_url
      || `/api/v1/songs/${encodeURIComponent(session.songID)}/media-location/refresh`,
  );
  if (!refreshURL) return false;
  const upstream = await fetch(refreshURL, {
    method: "POST",
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${session.token}`,
      "X-Resonance-Profile": session.profile,
    },
    redirect: "manual",
    signal: AbortSignal.timeout(20_000),
  });
  if (!upstream.ok) {
    upstream.body?.cancel?.().catch?.(() => undefined);
    return false;
  }
  const payload = await boundedJSONResponse(upstream, 512 * 1024);
  const mediaURL = sameOriginMediaURL(payload?.media_location?.stream_url);
  if (!mediaURL) return false;
  session.song = { ...session.song, media_location: payload.media_location };
  session.mediaURL = mediaURL;
  return true;
}

async function relayBrowserStream(request, response, session) {
  const fetchStream = () => fetch(session.mediaURL, {
    method: request.method,
    headers: {
      Accept: "audio/*, application/ogg, application/octet-stream",
      "Accept-Encoding": "identity",
      Authorization: `Bearer ${session.token}`,
      "X-Resonance-Profile": session.profile,
      ...(request.headers.range ? { Range: String(request.headers.range) } : {}),
    },
    redirect: "manual",
    signal: AbortSignal.timeout(5 * 60_000),
  });
  let upstream = await fetchStream();
  if (upstream.status === 409) {
    upstream.body?.cancel?.().catch?.(() => undefined);
    if (await refreshBrowserStreamLocation(session)) upstream = await fetchStream();
  }
  await relayUpstream(response, request, upstream, {
    "Content-Security-Policy": BROWSER_CSP,
    "Cross-Origin-Resource-Policy": "same-origin",
  });
}

async function handleBrowserAPI(request, response, streamSessions) {
  const url = new URL(request.url || "/", "http://127.0.0.1");
  if (!url.pathname.startsWith("/api/browser/")) return false;
  try {
    if (url.pathname === "/api/browser/auth/config" && request.method === "GET") {
      const upstream = await fetch(`${PRODUCTION_ORIGIN}/api/v1/auth/config`, {
        headers: { Accept: "application/json" },
        cache: "no-store",
        signal: AbortSignal.timeout(15_000),
      });
      const config = await boundedJSONResponse(upstream, 256 * 1024);
      if (!upstream.ok || !config?.publishable_key || config?.token_template !== "resonance") {
        sendJSON(response, 502, { error: "Account sign-in configuration is unavailable." });
        return true;
      }
      sendJSON(response, 200, { publishable_key: config.publishable_key, token_template: config.token_template });
      return true;
    }
    if (url.pathname === "/api/browser/auth/clerk.js" && request.method === "GET") {
      if (!clerkBrowserScriptCache) {
        const upstream = await fetch(CLERK_BROWSER_SCRIPT, { signal: AbortSignal.timeout(30_000) });
        if (!upstream.ok) throw new Error("The account sign-in client is unavailable.");
        clerkBrowserScriptCache = Buffer.from(await upstream.arrayBuffer());
      }
      send(response, 200, clerkBrowserScriptCache, {
        "Cache-Control": "private, max-age=3600",
        "Content-Type": "application/javascript; charset=utf-8",
        "Content-Security-Policy": BROWSER_CSP,
      });
      return true;
    }
    const clerkAssetMatch = /^\/api\/browser\/auth\/([A-Za-z0-9_.-]+\.(?:js|css))$/.exec(url.pathname);
    if (clerkAssetMatch && request.method === "GET") {
      const assetName = clerkAssetMatch[1];
      let asset = clerkAssetCache.get(assetName);
      if (!asset) {
        const upstream = await fetch(`${CLERK_ORIGIN}/npm/@clerk/clerk-js@5/dist/${assetName}`, {
          signal: AbortSignal.timeout(30_000),
        });
        if (!upstream.ok) throw new Error("The account sign-in client asset is unavailable.");
        asset = {
          body: Buffer.from(await upstream.arrayBuffer()),
          contentType: upstream.headers.get("content-type") || (assetName.endsWith(".css") ? "text/css" : "application/javascript"),
        };
        clerkAssetCache.set(assetName, asset);
      }
      send(response, 200, asset.body, {
        "Cache-Control": "private, max-age=3600",
        "Content-Type": asset.contentType,
        "Content-Security-Policy": BROWSER_CSP,
      });
      return true;
    }
    if (url.pathname === "/api/browser/auth/me" && request.method === "GET") {
      await proxyBrowserAPI(request, response, "/api/v1/auth/me");
      return true;
    }
    const proxies = new Map([
      ["/api/browser/catalog", "/api/v1/songs"],
      ["/api/browser/profiles", "/api/v1/profiles"],
      ["/api/browser/playlists", "/api/v1/playlists"],
      ["/api/browser/listening-history", "/api/v1/listening-history"],
    ]);
    if (proxies.has(url.pathname)) {
      await proxyBrowserAPI(request, response, proxies.get(url.pathname), url.search);
      return true;
    }
    const artworkMatch = /^\/api\/browser\/artwork\/([^/]+)$/.exec(url.pathname);
    if (artworkMatch && request.method === "GET") {
      const songID = safeSongID(decodeURIComponent(artworkMatch[1]));
      if (!songID) sendJSON(response, 400, { error: "A valid song is required." });
      else await proxyBrowserAPI(request, response, `/api/v1/songs/${encodeURIComponent(songID)}/artwork`);
      return true;
    }
    const adminSongMatch = /^\/api\/browser\/admin\/songs\/([^/]+)$/.exec(url.pathname);
    if (adminSongMatch && request.method === "DELETE") {
      const songID = safeSongID(decodeURIComponent(adminSongMatch[1]));
      if (!songID) sendJSON(response, 400, { error: "A valid song is required." });
      else await proxyBrowserAPI(request, response, `/api/v1/admin/songs/${encodeURIComponent(songID)}`);
      return true;
    }
    if (url.pathname === "/api/browser/streams" && request.method === "POST") {
      await createBrowserStream(request, response, streamSessions);
      return true;
    }
    const streamMatch = /^\/api\/browser\/streams\/([a-f0-9]{64})$/.exec(url.pathname);
    if (streamMatch) {
      const session = streamSessions.get(streamMatch[1]);
      if (!session || Date.now() - session.createdAt >= BROWSER_STREAM_TTL_MS) {
        streamSessions.delete(streamMatch[1]);
        sendJSON(response, 404, { error: "The stream session expired." });
      } else if (request.method === "DELETE") {
        streamSessions.delete(streamMatch[1]);
        sendJSON(response, 200, { released: true });
      } else if (["GET", "HEAD"].includes(request.method)) {
        await relayBrowserStream(request, response, session);
      } else {
        sendJSON(response, 405, { error: "Method Not Allowed" }, { Allow: "GET, HEAD, DELETE" });
      }
      return true;
    }
    sendJSON(response, 404, { error: "Not Found" });
    return true;
  } catch (error) {
    if (!response.headersSent) sendJSON(response, error?.statusCode || 502, { error: error?.message || "Browser service request failed." });
    else response.destroy();
    return true;
  }
}

function decodedUIPath(requestURL) {
  const url = new URL(requestURL || "/", "http://127.0.0.1");
  if (url.pathname === "/" || url.pathname === "/ui") return { redirect: "/ui/" };
  if (!url.pathname.startsWith("/ui/")) return null;
  let relative;
  try {
    relative = decodeURIComponent(url.pathname.slice("/ui/".length));
  } catch {
    return { error: 400 };
  }
  if (!relative) relative = "index.html";
  if (relative.includes("\0")) return { error: 400 };
  return { relative };
}

export function createBrowserPreviewServer({
  host = DEFAULT_HOST,
  port = DEFAULT_PORT,
  uiRoot = UI_ROOT,
} = {}) {
  if (host !== DEFAULT_HOST && !isTailscaleIPv4(host)) {
    throw new Error(`The browser client must bind to ${DEFAULT_HOST} or a Tailscale IPv4 address.`);
  }
  const root = path.resolve(uiRoot);
  const streamSessions = new Map();
  const server = createServer(async (request, response) => {
    if (request.url && await handleBrowserAPI(request, response, streamSessions)) return;
    if (!request.url || !["GET", "HEAD"].includes(request.method)) {
      send(response, 405, "Method Not Allowed", { Allow: "GET, HEAD" });
      return;
    }

    const resolved = decodedUIPath(request.url);
    if (resolved?.redirect) {
      redirect(response, resolved.redirect);
      return;
    }
    if (!resolved) {
      send(response, 404, "Not Found");
      return;
    }
    if (resolved.error) {
      send(response, resolved.error, resolved.error === 400 ? "Bad Request" : "Not Found");
      return;
    }

    const candidate = path.resolve(root, resolved.relative);
    if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) {
      send(response, 403, "Forbidden");
      return;
    }
    let real;
    try {
      real = await fs.realpath(candidate);
    } catch {
      send(response, 404, "Not Found");
      return;
    }
    if (real !== root && !real.startsWith(`${root}${path.sep}`)) {
      send(response, 403, "Forbidden");
      return;
    }
    let stat;
    try {
      stat = await fs.stat(real);
    } catch {
      send(response, 404, "Not Found");
      return;
    }
    if (!stat.isFile()) {
      send(response, 404, "Not Found");
      return;
    }
    const contentType = CONTENT_TYPES[path.extname(real).toLowerCase()] || "application/octet-stream";
    const headers = responseHeaders(contentType, stat.size);
    if (request.method === "HEAD") {
      response.writeHead(200, headers);
      response.end();
      return;
    }
    try {
      const rawContents = await fs.readFile(real);
      const contents = contentType.startsWith("text/html")
        ? Buffer.from(browserHTML(rawContents.toString("utf8")))
        : rawContents;
      response.writeHead(200, responseHeaders(contentType, contents.length));
      response.end(contents);
    } catch {
      send(response, 500, "Internal Server Error");
    }
  });

  return {
    server,
    host,
    port,
    listen: () => new Promise((resolve, reject) => {
      const onError = (error) => {
        server.off("listening", onListening);
        reject(error);
      };
      const onListening = () => {
        server.off("error", onError);
        const address = server.address();
        const actualPort = typeof address === "object" && address ? address.port : port;
        resolve({ host, port: actualPort, url: `http://${host}:${actualPort}/ui/` });
      };
      server.once("error", onError);
      server.once("listening", onListening);
      server.listen({ host, port });
    }),
    close: () => new Promise((resolve, reject) => {
      streamSessions.clear();
      if (!server.listening) {
        resolve();
        return;
      }
      server.close((error) => error ? reject(error) : resolve());
    }),
  };
}

function commandLinePort(argv) {
  const index = argv.findIndex((argument) => argument === "--port");
  const raw = index >= 0 ? argv[index + 1] : process.env.RESONANCE_UI_BROWSER_PORT || DEFAULT_PORT;
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 0 || port > 65_535) {
    throw new Error("Port must be an integer from 0 through 65535.");
  }
  return port;
}

function commandLineHost(argv) {
  const hostIndex = argv.findIndex((argument) => argument === "--host");
  const requestedHost = hostIndex >= 0 ? argv[hostIndex + 1] : process.env.RESONANCE_UI_BROWSER_HOST;
  const useTailscale = argv.includes("--tailscale");
  if (useTailscale && requestedHost) {
    throw new Error("Use either --tailscale or --host, not both.");
  }
  if (useTailscale) return tailscaleIPv4Host();
  if (hostIndex >= 0 && !requestedHost) throw new Error("--host requires an address.");
  return requestedHost || DEFAULT_HOST;
}

async function run() {
  const argv = process.argv.slice(2);
  const port = commandLinePort(argv);
  const host = commandLineHost(argv);
  const preview = createBrowserPreviewServer({ host, port });
  const address = await preview.listen();
  console.log(`Resonance web app: ${address.url}`);
  const shutdown = () => { void preview.close().finally(() => process.exit(0)); };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (invokedPath === import.meta.url) {
  run().catch((error) => {
    console.error(`Could not start the Resonance web app: ${error.message}`);
    process.exitCode = 1;
  });
}

export {
  BROWSER_CSP,
  CONTENT_TYPES,
  DEFAULT_HOST,
  DEFAULT_PORT,
  UI_ROOT,
  commandLineHost,
  isTailscaleIPv4,
  tailscaleIPv4Host,
};
