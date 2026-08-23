import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { createBrowserResonanceAPI } from "../ui/browser-runtime.js";

function memoryStorage() {
  const values = new Map();
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  };
}

test("browser runtime exposes a deterministic fixture library and reset hook", async () => {
  const api = createBrowserResonanceAPI({ storage: memoryStorage() });
  const loaded = await api.loadLibrary();
  assert.equal(api.browser, true);
  assert.equal(api.browserRuntimeVersion, "1");
  assert.equal(loaded.state.tracks.length, 6);
  assert.equal(loaded.state.playlists.length, 3);
  assert.equal(loaded.state.tracks[0].title, "Morning Signal");

  const changed = { ...loaded.state, tracks: [] };
  await api.saveLibrary(changed);
  assert.equal((await api.loadLibrary()).state.tracks.length, 0);
  assert.equal(api.resetBrowserState().tracks.length, 6);
});

test("browser runtime survives a blocked localStorage getter", async () => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  try {
    Object.defineProperty(globalThis, "localStorage", {
      configurable: true,
      get() { throw new Error("localStorage is blocked"); },
    });
    const api = createBrowserResonanceAPI();
    assert.equal((await api.loadLibrary()).state.tracks.length, 6);
  } finally {
    if (descriptor) Object.defineProperty(globalThis, "localStorage", descriptor);
    else delete globalThis.localStorage;
  }
});

test("browser fixtures preserve metadata durations and do not expose filesystem actions", async () => {
  const api = createBrowserResonanceAPI({ storage: memoryStorage() });
  const tracks = (await api.loadLibrary()).state.tracks;
  assert.deepEqual(tracks.map((track) => track.duration), [186, 242, 205, 278, 194, 221]);
  assert.ok(tracks.every((track) => !track.filePath));
  assert.equal(new Set(tracks.map((track) => track.fileUrl)).size, tracks.length);
});

test("browser state reset emits a notification and reloads after returning", async () => {
  const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const dispatched = [];
  let reloads = 0;
  class FakeCustomEvent {
    constructor(type, init) {
      this.type = type;
      this.detail = init?.detail;
    }
  }
  Object.defineProperty(globalThis, "window", {
    configurable: true,
    value: {
      CustomEvent: FakeCustomEvent,
      dispatchEvent: (event) => dispatched.push(event),
      location: { reload: () => { reloads += 1; } },
    },
  });
  try {
    const api = createBrowserResonanceAPI({ storage: memoryStorage() });
    const notifications = [];
    api.onBrowserStateReset((state) => notifications.push(state));
    const resetState = api.resetBrowserState();
    assert.equal(reloads, 0);
    assert.equal(notifications.length, 1);
    assert.equal(dispatched.length, 1);
    assert.equal(dispatched[0].type, api.browserStateResetEvent);
    assert.equal(dispatched[0].detail.tracks.length, 6);
    assert.equal(resetState.tracks.length, 6);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(reloads, 1);

    api.resetBrowserState({ reload: false });
    assert.equal(reloads, 1);
    assert.equal(dispatched.length, 2);
    assert.equal(api.reloadBrowserState(), true);
    assert.equal(reloads, 2);
  } finally {
    if (previousWindow) Object.defineProperty(globalThis, "window", previousWindow);
    else delete globalThis.window;
  }
});

test("browser runtime implements every preload method used by app.js", async () => {
  const [appSource, preloadSource] = await Promise.all([
    readFile(new URL("../ui/app.js", import.meta.url), "utf8"),
    readFile(new URL("../preload.cjs", import.meta.url), "utf8"),
  ]);
  const api = createBrowserResonanceAPI({ storage: memoryStorage() });
  const methods = [...new Set([
    ...[...appSource.matchAll(/api\.([A-Za-z0-9_]+)/g)].map((match) => match[1]),
    ...[...preloadSource.matchAll(/\n\s*([A-Za-z0-9_]+):/g)].map((match) => match[1]),
  ])];
  for (const method of methods) assert.equal(typeof api[method], "function", method);
});

test("browser runtime is inserted before the renderer module and does not replace Electron preload", async () => {
  const [html, runtimeSource] = await Promise.all([
    readFile(new URL("../ui/index.html", import.meta.url), "utf8"),
    readFile(new URL("../ui/browser-runtime.js", import.meta.url), "utf8"),
  ]);
  const browserScript = html.indexOf('src="browser-runtime.js"');
  const rendererScript = html.indexOf('src="app.js"');
  assert.ok(browserScript >= 0);
  assert.ok(browserScript < rendererScript);
  assert.match(runtimeSource, /typeof window !== "undefined" && !window\.resonance/);
});
