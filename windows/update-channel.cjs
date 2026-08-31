"use strict";

function createUpdateChannelGeneration() {
  let generation = 0;

  return Object.freeze({
    capture() {
      return generation;
    },
    invalidate() {
      generation += 1;
      return generation;
    },
    isCurrent(candidate) {
      return candidate === generation;
    },
    commit(candidate, callback) {
      if (candidate !== generation) return false;
      callback();
      return true;
    },
  });
}

module.exports = { createUpdateChannelGeneration };
