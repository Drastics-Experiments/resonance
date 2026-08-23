import assert from "node:assert/strict";
import test from "node:test";
import { createBrowserPreviewServer } from "../ui/browser-server.mjs";

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

test("browser preview serves the renderer at /ui/ with the CSP intact", async (t) => {
  await withPreview(t, async (origin) => {
    const response = await fetch(`${origin}/ui/`);
    const html = await response.text();
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type") || "", /^text\/html/);
    assert.match(response.headers.get("content-security-policy") || "", /script-src 'self'/);
    const csp = response.headers.get("content-security-policy") || "";
    assert.match(csp, /style-src 'self'/);
    assert.match(csp, /style-src-attr 'unsafe-inline'/);
    assert.match(csp, /connect-src blob:/);
    assert.doesNotMatch(csp, /connect-src[^;]*https?:/);
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

test("browser preview rejects non-loopback bindings", () => {
  assert.throws(
    () => createBrowserPreviewServer({ host: "0.0.0.0" }),
    /must bind to 127\.0\.0\.1/,
  );
});
