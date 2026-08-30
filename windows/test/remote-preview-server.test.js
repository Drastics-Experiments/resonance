import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import {
  commandLineHost,
  createRemotePreviewServer,
  isTailscaleIPv4,
  tailscaleIPv4Host,
} from "../remote-preview-server.mjs";

async function withPreview(testContext, callback, options = {}) {
  const preview = createRemotePreviewServer({ port: 0, ...options });
  let address;
  try {
    address = await preview.listen();
  } catch (error) {
    if (error?.code === "EACCES" || error?.code === "EPERM") {
      testContext.skip("loopback sockets are unavailable in this test environment");
      return;
    }
    throw error;
  }
  try {
    return await callback(address.origin);
  } finally {
    await preview.close();
  }
}

test("remote preview serves only one coherent source manifest and archive", async (t) => {
  const archive = Buffer.from("source archive fixture");
  const sha256 = createHash("sha256").update(archive).digest("hex");
  const manifest = {
    schemaVersion: 1,
    project: "resonance",
    target: "macos-electron-preview",
    revision: {
      branch: "preview-test",
      commit: "0123456789abcdef0123456789abcdef01234567",
      dirty: true,
      label: "preview-test @ 0123456 + changes",
    },
    source: {
      url: `/__resonance/preview/v1/source/${sha256}.zip`,
      format: "zip",
      sha256,
      size: archive.length,
    },
    createdAt: "2026-08-30T12:00:00.000Z",
    expiresAt: "2026-08-31T12:00:00.000Z",
  };
  const sourceExporter = {
    async getSnapshot() {
      return {
        manifest,
        manifestBody: Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`),
        archive,
      };
    },
  };

  await withPreview(t, async (origin) => {
    const manifestResponse = await fetch(`${origin}/__resonance/preview/v1/manifest.json`, {
      redirect: "manual",
    });
    assert.equal(manifestResponse.status, 200);
    assert.match(manifestResponse.headers.get("content-type") || "", /^application\/json/);
    assert.deepEqual(await manifestResponse.json(), manifest);

    const archiveResponse = await fetch(`${origin}${manifest.source.url}`, { redirect: "manual" });
    assert.equal(archiveResponse.status, 200);
    assert.equal(archiveResponse.headers.get("content-type"), "application/zip");
    assert.equal(archiveResponse.headers.get("content-length"), String(archive.length));
    assert.equal(archiveResponse.headers.get("etag"), `"${sha256}"`);
    assert.match(archiveResponse.headers.get("cache-control") || "", /immutable/);
    assert.deepEqual(Buffer.from(await archiveResponse.arrayBuffer()), archive);

    const head = await fetch(`${origin}${manifest.source.url}`, { method: "HEAD" });
    assert.equal(head.status, 200);
    assert.equal(await head.text(), "");
    assert.equal(head.headers.get("content-length"), String(archive.length));

    for (const removedBrowserPath of ["/", "/ui", "/ui/", "/ui/index.html", "/ui/app.js"]) {
      const response = await fetch(`${origin}${removedBrowserPath}`, { redirect: "manual" });
      assert.equal(response.status, 404, removedBrowserPath);
    }
    const post = await fetch(`${origin}/__resonance/preview/v1/manifest.json`, { method: "POST" });
    assert.equal(post.status, 405);
    assert.equal(post.headers.get("allow"), "GET, HEAD");
    const unknown = await fetch(`${origin}/__resonance/preview/v1/source/${"f".repeat(64)}.zip`);
    assert.equal(unknown.status, 404);
  }, { sourceExporter });
});

test("remote preview allows only loopback or Tailscale IPv4 bindings", () => {
  assert.equal(createRemotePreviewServer({ host: "100.64.0.1" }).host, "100.64.0.1");
  assert.throws(
    () => createRemotePreviewServer({ host: "0.0.0.0" }),
    /must bind to 127\.0\.0\.1 or a Tailscale IPv4 address/,
  );
  assert.throws(() => createRemotePreviewServer({ host: "192.168.1.20" }), /must bind/);
});

test("Tailscale host discovery selects an active CGNAT address", () => {
  assert.equal(isTailscaleIPv4("100.64.0.1"), true);
  assert.equal(isTailscaleIPv4("100.127.255.254"), true);
  assert.equal(isTailscaleIPv4("100.128.0.1"), false);
  assert.equal(isTailscaleIPv4("192.168.1.20"), false);
  assert.equal(tailscaleIPv4Host({
    ethernet: [{ address: "192.168.1.20", family: "IPv4", internal: false }],
    tailscale0: [{ address: "100.71.104.87", family: "IPv4", internal: false }],
  }), "100.71.104.87");
  assert.throws(() => tailscaleIPv4Host({
    ethernet: [{ address: "192.168.1.20", family: "IPv4", internal: false }],
  }), /No active Tailscale IPv4 address/);
});

test("Tailscale command-line mode rejects conflicting host selection", () => {
  assert.throws(
    () => commandLineHost(["--tailscale", "--host", "100.71.104.87"]),
    /either --tailscale or --host/,
  );
});
