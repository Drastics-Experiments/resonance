const fs = require("node:fs");
const path = require("node:path");

const UPDATE_AUTHENTICITY_MODES = new Set(["production", "unsigned"]);
const RELATIVE_REQUIRE_PATTERN = /require\(["']\.\/([^"']+)["']\)/g;

function fail(message) {
  throw new Error(message);
}

function normalizeRelativeDependency(parent, requested) {
  const dependency = path.posix.normalize(path.posix.join(path.posix.dirname(parent), requested));
  if (!dependency || dependency === ".." || dependency.startsWith("../") || path.posix.isAbsolute(dependency)) {
    fail(`${parent} has an unsafe packaged dependency path: ${requested}`);
  }
  return dependency;
}

function validatePackagedWindowsApp(archiveRoot, expectedAuthenticityMode) {
  const root = path.resolve(String(archiveRoot || ""));
  if (!root || !fs.existsSync(root)) fail("The packaged app archive was not found.");
  if (!UPDATE_AUTHENTICITY_MODES.has(expectedAuthenticityMode)) {
    fail("The expected Windows update authenticity mode is invalid.");
  }

  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  } catch (error) {
    fail(`The packaged app manifest could not be read: ${error.message}`);
  }
  if (manifest.resonanceUpdateAuthenticity !== expectedAuthenticityMode) {
    fail(
      `The packaged app update authenticity mode is ${manifest.resonanceUpdateAuthenticity || "missing"}, `
      + `expected ${expectedAuthenticityMode}.`,
    );
  }

  const pending = [String(manifest.main || "main.cjs"), "preload.cjs"];
  const visited = new Set();
  while (pending.length > 0) {
    const filename = pending.shift();
    if (visited.has(filename)) continue;
    visited.add(filename);
    const fullPath = path.join(root, ...filename.split("/"));
    if (!fs.existsSync(fullPath)) fail(`The packaged app is missing required module ${filename}.`);

    const source = fs.readFileSync(fullPath, "utf8");
    for (const match of source.matchAll(RELATIVE_REQUIRE_PATTERN)) {
      const dependency = normalizeRelativeDependency(filename, match[1]);
      const dependencyPath = path.join(root, ...dependency.split("/"));
      if (!fs.existsSync(dependencyPath)) {
        fail(`The packaged app is missing ${dependency}, required by ${filename}.`);
      }
      if (/\.cjs$/i.test(dependency)) pending.push(dependency);
    }
  }

  return Object.freeze({
    authenticityMode: expectedAuthenticityMode,
    modules: Object.freeze([...visited].sort()),
  });
}

if (require.main === module) {
  try {
    const result = validatePackagedWindowsApp(process.argv[2], process.argv[3]);
    process.stdout.write(
      `Verified ${result.modules.length} packaged Windows startup modules (${result.authenticityMode}).\n`,
    );
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = { normalizeRelativeDependency, validatePackagedWindowsApp };
