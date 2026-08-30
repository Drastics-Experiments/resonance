import { createServer } from "node:http";
import { networkInterfaces } from "node:os";
import { pathToFileURL } from "node:url";
import path from "node:path";
import {
  SOURCE_ARCHIVE_PREFIX,
  SOURCE_MANIFEST_PATH,
  createSourceExporter,
} from "./ui/source-export.mjs";

const REPO_ROOT = path.resolve(import.meta.dirname, "..");
const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 4173;

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
  if (!candidates.length) throw new Error("No active Tailscale IPv4 address was found.");
  return candidates[0];
}

function responseHeaders(contentType, length, cacheControl = "no-store") {
  return {
    "Cache-Control": cacheControl,
    "Content-Length": String(length),
    "Content-Type": contentType,
    "Cross-Origin-Resource-Policy": "same-origin",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
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

export function createRemotePreviewServer({
  host = DEFAULT_HOST,
  port = DEFAULT_PORT,
  repoRoot = REPO_ROOT,
  sourceExporter = createSourceExporter({ repoRoot }),
} = {}) {
  if (host !== DEFAULT_HOST && !isTailscaleIPv4(host)) {
    throw new Error(`Remote preview must bind to ${DEFAULT_HOST} or a Tailscale IPv4 address.`);
  }

  const server = createServer(async (request, response) => {
    if (!request.url || !["GET", "HEAD"].includes(request.method)) {
      send(response, 405, "Method Not Allowed", { Allow: "GET, HEAD" });
      return;
    }

    const requestPath = new URL(request.url, "http://127.0.0.1").pathname;
    const isSourceArchivePath = requestPath.startsWith(`${SOURCE_ARCHIVE_PREFIX}/`)
      && /^\/[0-9a-f]{64}\.zip$/.test(requestPath.slice(SOURCE_ARCHIVE_PREFIX.length));
    if (requestPath !== SOURCE_MANIFEST_PATH && !isSourceArchivePath) {
      send(response, 404, "Not Found");
      return;
    }

    try {
      const snapshot = await sourceExporter.getSnapshot();
      if (requestPath === SOURCE_MANIFEST_PATH) {
        const headers = responseHeaders("application/json; charset=utf-8", snapshot.manifestBody.length);
        response.writeHead(200, headers);
        if (request.method !== "HEAD") response.end(snapshot.manifestBody);
        else response.end();
        return;
      }

      if (requestPath !== snapshot.manifest.source.url) {
        send(response, 404, "Not Found");
        return;
      }
      const digest = Buffer.from(snapshot.manifest.source.sha256, "hex").toString("base64");
      const remainingSeconds = Math.max(
        0,
        Math.floor((Date.parse(snapshot.manifest.expiresAt) - Date.now()) / 1000),
      );
      const headers = {
        ...responseHeaders(
          "application/zip",
          snapshot.archive.length,
          `private, max-age=${remainingSeconds}, immutable`,
        ),
        "Content-Disposition": `attachment; filename="resonance-preview-${snapshot.manifest.source.sha256.slice(0, 16)}.zip"`,
        Digest: `sha-256=${digest}`,
        ETag: `"${snapshot.manifest.source.sha256}"`,
        Expires: new Date(snapshot.manifest.expiresAt).toUTCString(),
      };
      response.writeHead(200, headers);
      if (request.method !== "HEAD") response.end(snapshot.archive);
      else response.end();
    } catch (error) {
      console.error(`Could not create source preview: ${error.message}`);
      send(response, 503, "Source Export Unavailable", { "Retry-After": "1" });
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
        const origin = `http://${host}:${actualPort}`;
        resolve({ host, port: actualPort, origin, manifestURL: `${origin}${SOURCE_MANIFEST_PATH}` });
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
  const raw = index >= 0 ? argv[index + 1] : process.env.RESONANCE_REMOTE_PREVIEW_PORT || DEFAULT_PORT;
  const port = Number(raw);
  if (!Number.isInteger(port) || port < 0 || port > 65_535) {
    throw new Error("Port must be an integer from 0 through 65535.");
  }
  return port;
}

function commandLineHost(argv) {
  const hostIndex = argv.findIndex((argument) => argument === "--host");
  const requestedHost = hostIndex >= 0 ? argv[hostIndex + 1] : process.env.RESONANCE_REMOTE_PREVIEW_HOST;
  const useTailscale = argv.includes("--tailscale");
  if (useTailscale && requestedHost) throw new Error("Use either --tailscale or --host, not both.");
  if (useTailscale) return tailscaleIPv4Host();
  if (hostIndex >= 0 && !requestedHost) throw new Error("--host requires an address.");
  return requestedHost || DEFAULT_HOST;
}

async function run() {
  const argv = process.argv.slice(2);
  const preview = createRemotePreviewServer({
    host: commandLineHost(argv),
    port: commandLinePort(argv),
  });
  const address = await preview.listen();
  console.log(`Resonance remote-preview manifest: ${address.manifestURL}`);
  const shutdown = () => { void preview.close().finally(() => process.exit(0)); };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

const invokedPath = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : "";
if (invokedPath === import.meta.url) {
  run().catch((error) => {
    console.error(`Could not start remote preview: ${error.message}`);
    process.exitCode = 1;
  });
}

export {
  DEFAULT_HOST,
  DEFAULT_PORT,
  REPO_ROOT,
  commandLineHost,
  isTailscaleIPv4,
  tailscaleIPv4Host,
};
