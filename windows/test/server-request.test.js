import assert from "node:assert/strict";
import test from "node:test";
import { fetchSameOrigin, MAX_SERVER_REDIRECTS } from "../server-request.cjs";

function redirectResponse(location, status = 302) {
  return new Response("redirect", { status, headers: { location } });
}

test("follows only bounded same-origin redirects and keeps credentials on that origin", async () => {
  const calls = [];
  const fetchImpl = async (input, options) => {
    calls.push({ input: new URL(input).href, options });
    if (calls.length === 1) return redirectResponse("/api/v1/next");
    return new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };

  const response = await fetchSameOrigin(
    "https://music.example/",
    "https://music.example/api/v1/start",
    {
      method: "POST",
      headers: { Authorization: "Bearer admin-secret", "X-Resonance-Profile": "default" },
      body: JSON.stringify({ value: true }),
    },
    { fetchImpl },
  );

  assert.equal(response.status, 200);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].options.redirect, "manual");
  assert.equal(calls[1].options.redirect, "manual");
  const redirectedHeaders = new Headers(calls[1].options.headers);
  assert.equal(redirectedHeaders.get("authorization"), "Bearer admin-secret");
  assert.equal(redirectedHeaders.get("x-resonance-profile"), "default");
  assert.equal(calls[1].options.method, "GET");
  assert.equal(calls[1].options.body, undefined);
});

test("never sends credentials to a cross-origin or private redirect target", async () => {
  const calls = [];
  const fetchImpl = async (input, options) => {
    calls.push({ input: new URL(input).href, options });
    return redirectResponse("https://127.0.0.1/private");
  };

  await assert.rejects(
    fetchSameOrigin(
      "https://music.example/",
      "https://music.example/api/v1/profile",
      { headers: { Authorization: "Bearer secret" } },
      { fetchImpl },
    ),
    /cross-origin redirect/,
  );
  assert.equal(calls.length, 1);
  assert.equal(new Headers(calls[0].options.headers).get("authorization"), "Bearer secret");
  assert.equal(calls.some(({ input }) => input.includes("127.0.0.1")), false);
});

test("stops after the authenticated redirect hop limit", async () => {
  let calls = 0;
  const fetchImpl = async () => {
    calls += 1;
    return redirectResponse(`/api/v1/loop-${calls}`);
  };

  await assert.rejects(
    fetchSameOrigin(
      "https://music.example/",
      "https://music.example/api/v1/start",
      { headers: { Authorization: "Bearer secret" } },
      { fetchImpl },
    ),
    /too many times/,
  );
  assert.equal(calls, MAX_SERVER_REDIRECTS + 1);
});

test("redirects retain method and body semantics without mutating caller headers", async () => {
  for (const status of [301, 302, 303, 307, 308]) {
    for (const method of ["POST", "PUT", "GET", "HEAD"]) {
      const headers = new Headers({ "Content-Type": "text/plain", "Content-Length": "7" });
      const body = ["GET", "HEAD"].includes(method) ? undefined : "payload";
      const calls = [];
      let cancelled = 0;
      await fetchSameOrigin("https://music.example", "/start", { method, headers, body }, {
        fetchImpl: async (_url, options) => {
          calls.push(options);
          return calls.length === 1
            ? new Response(new ReadableStream({ cancel() { cancelled += 1; } }), { status, headers: { location: "/next" } })
            : new Response(null);
        },
      });
      const rewritten = status <= 303 && !["GET", "HEAD"].includes(method);
      assert.equal(calls[1].method, rewritten ? "GET" : method);
      assert.equal(calls[1].body, rewritten ? undefined : body);
      assert.equal(calls[1].headers.get("content-type"), rewritten ? null : "text/plain");
      assert.equal(calls[1].headers.get("content-length"), rewritten ? null : "7");
      assert.equal(headers.get("content-type"), "text/plain");
      assert.equal(cancelled, 1);
    }
  }
});

test("rejected redirects cancel their bodies even when cancellation fails", async () => {
  for (const [location, message] of [
    [null, /without a Location/],
    ["http://[", /unsafe redirect/],
    ["https://user:password@music.example/next", /unsafe redirect/],
    ["https://other.example/next", /cross-origin redirect/],
  ]) {
    let calls = 0;
    let cancelled = 0;
    await assert.rejects(fetchSameOrigin("https://music.example", "/start", {}, {
      fetchImpl: async () => {
        calls += 1;
        return new Response(new ReadableStream({
          cancel() { cancelled += 1; throw new Error("Cancellation failed"); },
        }), { status: 302, headers: location ? { location } : {} });
      },
    }), message);
    assert.equal(calls, 1);
    assert.equal(cancelled, 1);
  }
});

test("main and social-auth do not retain independent authenticated fetch paths", async () => {
  const { readFile } = await import("node:fs/promises");
  const [mainSource, authSource, debridSource] = await Promise.all([
    readFile(new URL("../main.cjs", import.meta.url), "utf8"),
    readFile(new URL("../social-auth.cjs", import.meta.url), "utf8"),
    readFile(new URL("../local-debrid.cjs", import.meta.url), "utf8"),
  ]);
  assert.doesNotMatch(mainSource, /\bfetch\(/);
  assert.doesNotMatch(authSource, /\bfetchImpl\(/);
  assert.doesNotMatch(debridSource, /\bfetchImpl\(/);
  assert.match(mainSource, /fetchSameOrigin\(base/);
  assert.match(authSource, /fetchSameOrigin\(/);
  assert.match(debridSource, /fetchSameOrigin\(/);
});
