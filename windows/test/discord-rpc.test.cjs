const assert = require("node:assert/strict");
const test = require("node:test");

const {
  discordIPCPaths,
  encodeDiscordFrame,
  sanitizeDiscordActivity,
  validDiscordApplicationID,
} = require("../discord-rpc.cjs");

test("validates public Discord application IDs", () => {
  assert.equal(validDiscordApplicationID(" 123456789012345678 "), "123456789012345678");
  assert.equal(validDiscordApplicationID("not-an-id"), "");
  assert.equal(validDiscordApplicationID("123"), "");
});

test("encodes Discord IPC frames with little-endian headers", () => {
  const frame = encodeDiscordFrame(0, { v: 1, client_id: "123456789012345678" });
  assert.equal(frame.readInt32LE(0), 0);
  assert.equal(frame.readInt32LE(4), frame.length - 8);
  assert.deepEqual(JSON.parse(frame.subarray(8).toString("utf8")), {
    v: 1,
    client_id: "123456789012345678",
  });
});

test("builds documented Discord IPC paths on Windows and macOS", () => {
  assert.equal(discordIPCPaths("win32", {})[0], "\\\\?\\pipe\\discord-ipc-0");
  assert.deepEqual(discordIPCPaths("darwin", { TMPDIR: "/private/tmp/example" }).slice(0, 2), [
    "/private/tmp/example/discord-ipc-0",
    "/private/tmp/example/discord-ipc-1",
  ]);
});

test("creates listening activity with playback timestamps", () => {
  assert.deepEqual(sanitizeDiscordActivity({
    title: "Signal",
    artist: "Resonance",
    album: "Desktop",
    playing: true,
    position: 10,
    duration: 120,
  }, 1_000), {
    type: 2,
    details: "Signal",
    state: "by Resonance",
    instance: false,
    timestamps: { start: 990, end: 1110 },
  });
  assert.equal(sanitizeDiscordActivity({}), null);
});
