import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import clientConfigState from "../client-config-state.cjs";
import crashSafeFile from "../crash-safe-file.cjs";

const {
  cachedConfigMeetsRevisionFloor,
  clientConfigRevisionFloor,
  commitClientConfigRecord,
  currentFloorSafeCachedConfig,
} = clientConfigState;
const { crashSafeReplaceMirrored, readPrimaryOrBackup } = crashSafeFile;

test("a failed floor write never activates its cache record or lowers the in-memory high-water", async () => {
  const key = `client-config-v1-${"a".repeat(64)}`;
  const oldRecord = { highest_revision: 8, body: "old" };
  const state = { entries: { [key]: oldRecord }, revision_floors: { [key]: 8 } };
  const newRecord = { highest_revision: 9, body: "new" };
  await assert.rejects(commitClientConfigRecord({
    state,
    cacheKey: key,
    record: newRecord,
    revision: 9,
    persist: async () => { throw new Error("disk unavailable"); },
  }), /disk unavailable/);
  assert.equal(state.entries[key], oldRecord);
  assert.equal(clientConfigRevisionFloor(state, key), 9);
  assert.equal(cachedConfigMeetsRevisionFloor({ verified: true, revision: 8 }, state, key), false);
  assert.equal(cachedConfigMeetsRevisionFloor({ verified: true, revision: 9 }, state, key), true);
});

test("accepted floors survive primary corruption through a mirrored latest backup", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "resonance-config-floor-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const destination = path.join(directory, "client-config-state.json");
  const backupPath = `${destination}.backup`;
  const snapshot = JSON.stringify({ revision_floors: { scope: 19 } });
  await crashSafeReplaceMirrored(destination, snapshot, { backupPath, encoding: "utf8" });
  assert.equal(await readFile(backupPath, "utf8"), snapshot);
  await writeFile(destination, "corrupt");
  const recovered = await readPrimaryOrBackup(destination, (bytes) => JSON.parse(bytes.toString("utf8")), { backupPath });
  assert.equal(recovered.recoveredFromBackup, true);
  assert.equal(recovered.value.revision_floors.scope, 19);
});

test("a late fallback re-reads the current cache instead of returning a captured stale revision", () => {
  const key = `client-config-v1-${"b".repeat(64)}`;
  const state = {
    entries: { [key]: { config: { verified: true, revision: 8 } } },
    revision_floors: { [key]: 8 },
  };
  const captured = state.entries[key].config;
  state.entries[key] = { config: { verified: true, revision: 9 } };
  state.revision_floors[key] = 9;
  const current = currentFloorSafeCachedConfig(state, key, (record) => record?.config || null);
  assert.equal(captured.revision, 8);
  assert.equal(current.revision, 9);
  assert.equal(cachedConfigMeetsRevisionFloor(captured, state, key), false);
});
