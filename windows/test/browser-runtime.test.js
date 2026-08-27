import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createBrowserResonanceAPI } from "../ui/browser-runtime.js";
import { activeServerClientConfig, resolveServerTransferModes } from "../ui/core.js";

function memoryStorage() {
  const values = new Map();
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  };
}

function signedInClerk(token = "account-token") {
  const listeners = new Set();
  return {
    loaded: true,
    session: { getToken: async ({ template }) => template === "resonance" ? token : null },
    load: async () => {},
    addListener: (callback) => { listeners.add(callback); return () => listeners.delete(callback); },
    signOut: async () => {},
  };
}

function json(value, init = {}) {
  return new Response(JSON.stringify(value), {
    status: init.status || 200,
    headers: { "Content-Type": "application/json", ...(init.headers || {}) },
  });
}

test("browser runtime starts as a real empty client without demo data or debug hooks", async () => {
  const api = createBrowserResonanceAPI({ storage: memoryStorage(), clerk: { session: null } });
  const loaded = await api.loadLibrary();
  assert.equal(api.runtime, "browser");
  assert.equal(api.browser, undefined);
  assert.equal(api.resetBrowserState, undefined);
  assert.deepEqual(loaded.state.tracks, []);
  assert.deepEqual(loaded.state.playlists.map((playlist) => playlist.name), ["Liked Songs"]);
});

test("browser runtime survives blocked persistent storage", async () => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  try {
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      get() { throw new Error("localStorage is blocked"); },
    });
    const api = createBrowserResonanceAPI({ clerk: { session: null } });
    assert.deepEqual((await api.loadLibrary()).state.tracks, []);
  } finally {
    if (descriptor) Object.defineProperty(globalThis, "localStorage", descriptor);
    else delete globalThis.localStorage;
  }
});

test("browser account session comes from Clerk and the real account endpoint", async () => {
  const requests = [];
  const api = createBrowserResonanceAPI({
    storage: memoryStorage(),
    clerk: signedInClerk(),
    fetchImpl: async (url, init) => {
      requests.push({ url, init });
      return json({
        id: "user_123",
        profile_id: "user_123",
        email: "listener@example.com",
        display_name: "Listener",
        role: "member",
      });
    },
  });
  const session = await api.loadAccountSession();
  assert.equal(session.displayName, "Listener");
  assert.equal(session.profileID, "user_123");
  assert.equal(session.accessToken, "account-token");
  assert.equal(requests[0].url, "/api/browser/auth/me");
  assert.equal(new Headers(requests[0].init.headers).get("authorization"), "Bearer account-token");
});

test("browser catalog and stream requests use authenticated same-origin transport", async () => {
  const requests = [];
  const api = createBrowserResonanceAPI({
    storage: memoryStorage(),
    clerk: signedInClerk(),
    window: { location: { href: "http://100.71.104.87:47173/ui/", origin: "http://100.71.104.87:47173" } },
    fetchImpl: async (url, init) => {
      requests.push({ url, init });
      if (url === "/api/browser/catalog") return json({ count: 1, songs: [{ id: "song-1", title: "Real song" }] });
      if (url === "/api/browser/streams") return json({
        url: "/api/browser/streams/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        historyTrackID: `remote-stream:${"b".repeat(64)}`,
      });
      if (String(url).includes("/api/browser/streams/")) return json({ released: true });
      throw new Error(`Unexpected request ${url}`);
    },
  });
  assert.equal((await api.fetchCatalog({ profileID: "user_123" })).songs[0].title, "Real song");
  const stream = await api.createServerStream({ profileID: "user_123", songID: "song-1" });
  assert.match(stream.url, /^\/api\/browser\/streams\/[a-f0-9]{64}$/);
  assert.equal(await api.releaseServerStream(stream.url), true);
  assert.equal(new Headers(requests[0].init.headers).get("x-resonance-profile"), "user_123");
  assert.equal(new Headers(requests[1].init.headers).get("authorization"), "Bearer account-token");
});

test("browser configuration forces stream-only playback", async () => {
  const state = (await createBrowserResonanceAPI({ storage: memoryStorage(), clerk: { session: null } }).loadLibrary()).state;
  const api = createBrowserResonanceAPI({ storage: memoryStorage(), clerk: { session: null } });
  const { config } = await api.fetchClientConfig();
  assert.notEqual(activeServerClientConfig(config), null);
  assert.equal(resolveServerTransferModes({
    state,
    serverURL: state.serverURL,
    profileID: "default",
    config,
  }).downloadMode, "stream_only");
});

test("browser runtime implements every preload method used by the renderer", async () => {
  const [appSource, preloadSource] = await Promise.all([
    readFile(new URL("../ui/app.js", import.meta.url), "utf8"),
    readFile(new URL("../preload.cjs", import.meta.url), "utf8"),
  ]);
  const api = createBrowserResonanceAPI({ storage: memoryStorage(), clerk: { session: null } });
  const methods = [...new Set([
    ...[...appSource.matchAll(/api\.([A-Za-z0-9_]+)\s*\(/g)].map((match) => match[1]),
    ...[...preloadSource.matchAll(/\n\s*([A-Za-z0-9_]+):/g)].map((match) => match[1]),
  ])];
  for (const method of methods) assert.equal(typeof api[method], "function", method);
});

test("renderer keeps transitions but exposes no browser-preview debug surface", async () => {
  const [html, css, appSource] = await Promise.all([
    readFile(new URL("../ui/index.html", import.meta.url), "utf8"),
    readFile(new URL("../ui/transitions.css", import.meta.url), "utf8"),
    readFile(new URL("../ui/app.js", import.meta.url), "utf8"),
  ]);
  assert.match(html, /href="transitions\.css"/);
  assert.match(css, /prefers-reduced-motion: reduce/);
  assert.doesNotMatch(html, /Browser test mode|resetBrowserPreview/);
  assert.doesNotMatch(appSource, /resetBrowserState|browserPreviewBar/);
});

test("browser runtime loads before app.js without replacing Electron preload", async () => {
  const [html, runtimeSource] = await Promise.all([
    readFile(new URL("../ui/index.html", import.meta.url), "utf8"),
    readFile(new URL("../ui/browser-runtime.js", import.meta.url), "utf8"),
  ]);
  assert.ok(html.indexOf('src="browser-runtime.js"') < html.indexOf('src="app.js"'));
  assert.match(runtimeSource, /typeof window !== "undefined" && !window\.resonance/);
  assert.doesNotMatch(runtimeSource, /__resonanceBrowser|Browser Tester|sampleTracks/);
});
