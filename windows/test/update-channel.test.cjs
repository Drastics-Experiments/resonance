"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const { createUpdateChannelGeneration } = require("../update-channel.cjs");

test("rejects an asynchronous update completion after its channel is invalidated", async () => {
  const channel = createUpdateChannelGeneration();
  const stableGeneration = channel.capture();
  const accepted = [];
  let finish;
  const completion = new Promise((resolve) => { finish = resolve; }).then(() => (
    channel.commit(stableGeneration, () => accepted.push("stable artifact"))
  ));

  channel.invalidate();
  finish();

  assert.equal(await completion, false);
  assert.deepEqual(accepted, []);

  const prereleaseGeneration = channel.capture();
  assert.equal(channel.commit(prereleaseGeneration, () => accepted.push("prerelease artifact")), true);
  assert.deepEqual(accepted, ["prerelease artifact"]);
});
