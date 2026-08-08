const net = require("node:net");
const path = require("node:path");

const DISCORD_HANDSHAKE = 0;
const DISCORD_FRAME = 1;
const DISCORD_CLOSE = 2;
const DISCORD_PING = 3;
const DISCORD_PONG = 4;

function validDiscordApplicationID(value) {
  const candidate = String(value || "").trim();
  return /^\d{15,22}$/.test(candidate) ? candidate : "";
}

function discordIPCPaths(platform = process.platform, environment = process.env) {
  if (platform === "win32") {
    return Array.from({ length: 10 }, (_unused, index) => `\\\\?\\pipe\\discord-ipc-${index}`);
  }
  const prefixes = [
    environment.XDG_RUNTIME_DIR,
    environment.TMPDIR,
    environment.TMP,
    environment.TEMP,
    "/tmp",
  ].filter((value, index, values) => value && values.indexOf(value) === index);
  return prefixes.flatMap((prefix) => Array.from(
    { length: 10 },
    (_unused, index) => path.join(prefix, `discord-ipc-${index}`),
  ));
}

function encodeDiscordFrame(opcode, payload) {
  const body = Buffer.from(JSON.stringify(payload), "utf8");
  const frame = Buffer.allocUnsafe(body.length + 8);
  frame.writeInt32LE(opcode, 0);
  frame.writeInt32LE(body.length, 4);
  body.copy(frame, 8);
  return frame;
}

function sanitizeDiscordActivity(value, nowSeconds = Math.floor(Date.now() / 1000)) {
  if (!value || typeof value !== "object") return null;
  const title = String(value.title || "").trim().slice(0, 128);
  if (!title) return null;
  const artist = String(value.artist || "").trim().slice(0, 120);
  const album = String(value.album || "").trim().slice(0, 120);
  const playing = Boolean(value.playing);
  const position = Math.max(0, Number(value.position) || 0);
  const duration = Math.max(0, Number(value.duration) || 0);
  const stateParts = [artist ? `by ${artist}` : "", !playing ? "Paused" : ""].filter(Boolean);
  const activity = {
    type: 2,
    details: title,
    state: (stateParts.join(" · ") || album || "Listening in Resonance").slice(0, 128),
    instance: false,
  };
  if (playing && duration > 0 && position < duration) {
    const start = Math.max(1, Math.floor(nowSeconds - position));
    activity.timestamps = { start, end: Math.max(start + 1, Math.floor(start + duration)) };
  }
  return activity;
}

class DiscordRPCClient {
  constructor({ onStatus = () => {}, reconnectDelayMS = 15_000, connectTimeoutMS = 1_200 } = {}) {
    this.onStatus = onStatus;
    this.reconnectDelayMS = reconnectDelayMS;
    this.connectTimeoutMS = connectTimeoutMS;
    this.enabled = false;
    this.applicationID = "";
    this.activity = null;
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.ready = false;
    this.reconnectTimer = null;
    this.generation = 0;
    this.currentStatus = { state: "disabled", message: "Rich Presence is off." };
  }

  status() {
    return { ...this.currentStatus, applicationConfigured: Boolean(this.applicationID) };
  }

  setStatus(state, message) {
    if (this.currentStatus.state === state && this.currentStatus.message === message) return;
    this.currentStatus = { state, message };
    this.onStatus(this.status());
  }

  configure({ enabled, applicationID } = {}) {
    const nextEnabled = Boolean(enabled);
    const nextApplicationID = validDiscordApplicationID(applicationID);
    const connectionChanged = this.enabled !== nextEnabled || this.applicationID !== nextApplicationID;
    this.enabled = nextEnabled;
    this.applicationID = nextApplicationID;
    if (!nextEnabled) {
      this.disconnect({ clear: true });
      this.setStatus("disabled", "Rich Presence is off.");
      return this.status();
    }
    if (!nextApplicationID) {
      this.disconnect({ clear: true });
      this.setStatus("configuration-required", "Add the Resonance Discord Application ID to connect.");
      return this.status();
    }
    if (connectionChanged || !this.socket) this.connect();
    return this.status();
  }

  setActivity(value) {
    this.activity = sanitizeDiscordActivity(value);
    if (this.ready) this.sendActivity();
    return this.status();
  }

  connect() {
    this.disconnect();
    if (!this.enabled || !this.applicationID) return;
    const generation = ++this.generation;
    const candidates = discordIPCPaths();
    this.setStatus("connecting", "Connecting to the Discord desktop app…");

    const tryCandidate = (index) => {
      if (generation !== this.generation || !this.enabled) return;
      if (index >= candidates.length) {
        this.setStatus("discord-not-running", "Discord desktop is not running. Resonance will retry automatically.");
        this.reconnectTimer = setTimeout(() => this.connect(), this.reconnectDelayMS);
        this.reconnectTimer.unref?.();
        return;
      }
      const socket = net.createConnection(candidates[index]);
      let settled = false;
      const timeout = setTimeout(() => socket.destroy(), this.connectTimeoutMS);
      timeout.unref?.();
      const fail = () => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        socket.destroy();
        tryCandidate(index + 1);
      };
      socket.once("error", fail);
      socket.once("connect", () => {
        if (settled || generation !== this.generation) return socket.destroy();
        settled = true;
        clearTimeout(timeout);
        socket.removeListener("error", fail);
        this.attachSocket(socket, generation);
      });
    };
    tryCandidate(0);
  }

  attachSocket(socket, generation) {
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    this.ready = false;
    socket.on("data", (chunk) => this.receive(chunk));
    socket.on("error", () => {});
    socket.on("close", () => {
      if (this.socket === socket) {
        this.socket = null;
        this.ready = false;
      }
      if (generation === this.generation && this.enabled) {
        this.setStatus("disconnected", "Discord disconnected. Resonance will retry automatically.");
        this.reconnectTimer = setTimeout(() => this.connect(), this.reconnectDelayMS);
        this.reconnectTimer.unref?.();
      }
    });
    socket.write(encodeDiscordFrame(DISCORD_HANDSHAKE, { v: 1, client_id: this.applicationID }));
  }

  receive(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 8) {
      const opcode = this.buffer.readInt32LE(0);
      const length = this.buffer.readInt32LE(4);
      if (length < 0 || length > 1024 * 1024) return this.socket?.destroy();
      if (this.buffer.length < length + 8) return;
      const body = this.buffer.subarray(8, length + 8);
      this.buffer = this.buffer.subarray(length + 8);
      let payload = null;
      try { payload = JSON.parse(body.toString("utf8")); } catch { /* ignore malformed Discord frames */ }
      if (opcode === DISCORD_PING) {
        this.socket?.write(encodeDiscordFrame(DISCORD_PONG, payload));
      } else if (opcode === DISCORD_CLOSE) {
        this.setStatus("error", String(payload?.message || "Discord closed the Rich Presence connection."));
        this.socket?.destroy();
      } else if (opcode === DISCORD_FRAME && payload?.evt === "READY") {
        this.ready = true;
        this.setStatus("connected", "Connected to Discord desktop.");
        this.sendActivity();
      } else if (opcode === DISCORD_FRAME && payload?.evt === "ERROR") {
        this.setStatus("error", String(payload?.data?.message || "Discord rejected the Rich Presence update."));
      }
    }
  }

  sendActivity() {
    if (!this.ready || !this.socket || this.socket.destroyed) return;
    this.socket.write(encodeDiscordFrame(DISCORD_FRAME, {
      cmd: "SET_ACTIVITY",
      args: { pid: process.pid, activity: this.activity },
      nonce: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    }));
  }

  disconnect({ clear = false } = {}) {
    this.generation += 1;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    const socket = this.socket;
    this.socket = null;
    if (clear && this.ready && socket && !socket.destroyed) {
      socket.write(encodeDiscordFrame(DISCORD_FRAME, {
        cmd: "SET_ACTIVITY",
        args: { pid: process.pid, activity: null },
        nonce: `${Date.now()}-clear`,
      }));
      socket.end();
    } else {
      socket?.destroy();
    }
    this.ready = false;
    this.buffer = Buffer.alloc(0);
  }

  destroy() {
    this.enabled = false;
    this.disconnect({ clear: true });
  }
}

module.exports = {
  DiscordRPCClient,
  discordIPCPaths,
  encodeDiscordFrame,
  sanitizeDiscordActivity,
  validDiscordApplicationID,
};
