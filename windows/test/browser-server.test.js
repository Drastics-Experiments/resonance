import assert from "node:assert/strict";
import test from "node:test";
import {
  commandLineHost,
  createBrowserPreviewServer,
  isTailscaleIPv4,
  tailscaleIPv4Host,
} from "../ui/browser-server.mjs";

async function withPreview(testContext, callback) {
  const preview = createBrowserPreviewServer({ port: 0 });
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
    return await callback(address.url.slice(0, -"/ui/".length));
  } finally {
    await preview.close();
  }
}

function localReferences(source, contentType) {
  const references = [];
  const add = (value) => {
    if (!value || value.startsWith("#")) return;
    try {
      const url = new URL(value, "http://preview.test/ui/");
      if (url.origin !== "http://preview.test" || !url.pathname.startsWith("/ui/")) return;
      references.push(`${url.pathname}${url.search}`);
    } catch {
      // A malformed or external reference is not a preview asset to fetch.
    }
  };
  if (contentType.includes("html")) {
    for (const match of source.matchAll(/(?:src|href)=["']([^"']+)["']/g)) add(match[1]);
  }
  if (contentType.includes("javascript")) {
    for (const match of source.matchAll(/\bimport\s+(?:[^"'`]+?\s+from\s+)?["']([^"']+)["']/g)) add(match[1]);
  }
  return references;
}

test("browser client serves the renderer at /ui/ with a same-origin API CSP", async (t) => {
  await withPreview(t, async (origin) => {
    const response = await fetch(`${origin}/ui/`);
    const html = await response.text();
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type") || "", /^text\/html/);
    assert.match(response.headers.get("content-security-policy") || "", /script-src 'self'/);
    const csp = response.headers.get("content-security-policy") || "";
    assert.match(csp, /style-src 'self'/);
    assert.match(csp, /style-src-attr 'unsafe-inline'/);
    assert.match(csp, /connect-src 'self' blob: https:\/\/clerk\.unblocked\.mov/);
    assert.match(html, /src="browser-runtime\.js"/);
    assert.match(html, /src="app\.js"/);
  });
});

test("browser preview redirects its root to /ui/ and serves module assets", async (t) => {
  await withPreview(t, async (origin) => {
    const root = await fetch(`${origin}/`, { redirect: "manual" });
    assert.equal(root.status, 302);
    assert.equal(root.headers.get("location"), "/ui/");

    const shortUI = await fetch(`${origin}/ui`, { redirect: "manual" });
    assert.equal(shortUI.status, 302);
    assert.equal(shortUI.headers.get("location"), "/ui/");

    const module = await fetch(`${origin}/ui/browser-runtime.js`);
    assert.equal(module.status, 200);
    assert.match(module.headers.get("content-type") || "", /^application\/javascript/);
    assert.match(await module.text(), /createBrowserResonanceAPI/);
  });
});

test("browser service rejects unauthenticated API and stream creation", async (t) => {
  await withPreview(t, async (origin) => {
    for (const [path, init] of [
      ["/api/browser/catalog", {}],
      ["/api/browser/streams", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ songID: "song-1" }) }],
    ]) {
      const response = await fetch(`${origin}${path}`, init);
      assert.equal(response.status, 401);
      assert.match((await response.json()).error, /Sign in/);
    }
  });
});

test("browser preview serves the complete local renderer asset graph", async (t) => {
  await withPreview(t, async (origin) => {
    const queue = ["/ui/index.html"];
    const visited = new Set();
    while (queue.length) {
      const assetPath = queue.shift();
      if (visited.has(assetPath)) continue;
      visited.add(assetPath);

      const response = await fetch(`${origin}${assetPath}`);
      assert.equal(response.status, 200, assetPath);
      assert.match(response.headers.get("content-security-policy") || "", /script-src 'self'/, assetPath);
      assert.ok(Number(response.headers.get("content-length")) > 0, assetPath);

      const contentType = response.headers.get("content-type") || "";
      if (!/javascript|css|html/.test(contentType)) continue;
      for (const reference of localReferences(await response.text(), contentType)) {
        if (!visited.has(reference)) queue.push(reference);
      }
    }

    for (const expected of [
      "/ui/index.html",
      "/ui/theme-bootstrap.js",
      "/ui/styles.css",
      "/ui/transitions.css",
      "/ui/shuffle-icon.css",
      "/ui/browser-runtime.js",
      "/ui/app.js",
      "/ui/core.js",
      "/ui/media-session.js",
    ]) {
      assert.equal(visited.has(expected), true, expected);
    }
  });
});

test("browser preview stays loopback-scoped to the UI tree", async (t) => {
  await withPreview(t, async (origin) => {
    const outside = await fetch(`${origin}/package.json`);
    assert.equal(outside.status, 404);

    const traversal = await fetch(`${origin}/ui/%2e%2e%2fpackage.json`);
    assert.equal(traversal.status, 403);

    const post = await fetch(`${origin}/ui/`, { method: "POST" });
    assert.equal(post.status, 405);
    assert.equal(post.headers.get("allow"), "GET, HEAD");

    const head = await fetch(`${origin}/ui/index.html`, { method: "HEAD" });
    assert.equal(head.status, 200);
    assert.equal(await head.text(), "");
    assert.ok(Number(head.headers.get("content-length")) > 0);
  });
});

test("browser preview allows only loopback or Tailscale IPv4 bindings", () => {
  assert.equal(createBrowserPreviewServer({ host: "100.64.0.1" }).host, "100.64.0.1");
  assert.throws(
    () => createBrowserPreviewServer({ host: "0.0.0.0" }),
    /must bind to 127\.0\.0\.1 or a Tailscale IPv4 address/,
  );
  assert.throws(() => createBrowserPreviewServer({ host: "192.168.1.20" }), /must bind/);
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
