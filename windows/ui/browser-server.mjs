import { createServer } from "node:http";
import { promises as fs } from "node:fs";
import { networkInterfaces } from "node:os";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const UI_ROOT = path.resolve(fileURLToPath(new URL(".", import.meta.url)));
const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 4173;
// The renderer has a small number of data-driven style attributes (waveform
// bars, ruler labels, and the storage ring). Keep stylesheet loading strict,
// but scope the inline exception to attributes rather than allowing inline
// <style> blocks. Browser fixtures also use a blob: URL for their silent audio
// track; allowing blob: alone keeps waveform decoding offline and prevents
// arbitrary network connections from the preview page.
const BROWSER_CSP = "default-src 'self' file:; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; media-src 'self' file: blob: resonance-stream:; img-src 'self' data: file: https:; connect-src blob:; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'";

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
    throw new Error(`Browser preview must bind to ${DEFAULT_HOST} or a Tailscale IPv4 address.`);
  }
  const root = path.resolve(uiRoot);
  const server = createServer(async (request, response) => {
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
      const contents = await fs.readFile(real);
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
  console.log(`Resonance browser UI: ${address.url}`);
  const shutdown = () => { void preview.close().finally(() => process.exit(0)); };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (invokedPath === import.meta.url) {
  run().catch((error) => {
    console.error(`Could not start browser UI: ${error.message}`);
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
