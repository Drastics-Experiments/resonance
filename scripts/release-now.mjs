#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

import { expectedAssetNames as validatedExpectedAssetNames } from "./validate-release-assets.mjs";

const scriptPath = fileURLToPath(import.meta.url);
const repositoryRoot = path.resolve(path.dirname(scriptPath), "..");
const versionPattern = /^[0-9]+\.[0-9]+\.[0-9]+$/;
const requiredAndroidSecrets = [
  "RESONANCE_ANDROID_KEYSTORE_BASE64",
  "RESONANCE_ANDROID_KEYSTORE_PASSWORD",
  "RESONANCE_ANDROID_KEY_ALIAS",
  "RESONANCE_ANDROID_KEY_PASSWORD",
];
const requiredMacOSSecrets = [
  "RESONANCE_MACOS_APP_CERTIFICATE_BASE64",
  "RESONANCE_MACOS_APP_CERTIFICATE_PASSWORD",
  "RESONANCE_MACOS_APP_IDENTITY",
  "RESONANCE_MACOS_INSTALLER_CERTIFICATE_BASE64",
  "RESONANCE_MACOS_INSTALLER_CERTIFICATE_PASSWORD",
  "RESONANCE_MACOS_INSTALLER_IDENTITY",
  "RESONANCE_MACOS_NOTARY_KEY_BASE64",
  "RESONANCE_MACOS_NOTARY_KEY_ID",
  "RESONANCE_MACOS_NOTARY_ISSUER_ID",
];
const requiredWindowsSecrets = [
  "RESONANCE_WINDOWS_CERTIFICATE_BASE64",
  "RESONANCE_WINDOWS_CERTIFICATE_PASSWORD",
  "RESONANCE_WINDOWS_CERTIFICATE_SHA1",
];
const versionFiles = [
  "android/app/build.gradle.kts",
  "ios/Resonance.xcodeproj/project.pbxproj",
  "ios/Resonance/Info.plist",
  "release/version.json",
  "windows/package.json",
];
const releasePolicyFile = "release/policy.json";
const releaseFiles = [...versionFiles, releasePolicyFile];

function fail(message) {
  throw new Error(message);
}

function commandText(command, arguments_) {
  return [command, ...arguments_].join(" ");
}

function run(command, arguments_ = [], options = {}) {
  const {
    allowFailure = false,
    capture = true,
    cwd = repositoryRoot,
    env = {},
  } = options;
  const result = spawnSync(command, arguments_, {
    cwd,
    encoding: "utf8",
    env: { ...process.env, ...env },
    maxBuffer: 16 * 1024 * 1024,
    stdio: capture ? "pipe" : "inherit",
  });

  if (result.error) {
    fail(`${commandText(command, arguments_)} could not start: ${result.error.message}`);
  }
  if (result.status !== 0 && !allowFailure) {
    const detail = [result.stdout, result.stderr]
      .filter(Boolean)
      .join("\n")
      .trim();
    fail(
      `${commandText(command, arguments_)} exited with status ${result.status}${
        detail ? `\n${detail}` : ""
      }`,
    );
  }
  return {
    status: result.status ?? 1,
    stdout: result.stdout?.trim() ?? "",
    stderr: result.stderr?.trim() ?? "",
  };
}

function output(command, arguments_ = [], options = {}) {
  return run(command, arguments_, options).stdout;
}

function runJSON(command, arguments_, options = {}) {
  const text = output(command, arguments_, options);
  try {
    return JSON.parse(text);
  } catch {
    fail(`${commandText(command, arguments_)} did not return valid JSON:\n${text}`);
  }
}

function succeeds(command, arguments_, options = {}) {
  return run(command, arguments_, { ...options, allowFailure: true }).status === 0;
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

export function parseArguments(arguments_) {
  const options = {
    build: undefined,
    dryRun: false,
    help: false,
    retryFailed: false,
    version: undefined,
  };

  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    switch (argument) {
      case "--build": {
        const value = arguments_[index + 1];
        if (!value || !/^[0-9]+$/.test(value)) fail("--build requires a positive integer");
        options.build = Number(value);
        index += 1;
        break;
      }
      case "--dry-run":
        options.dryRun = true;
        break;
      case "--help":
      case "-h":
        options.help = true;
        break;
      case "--retry-failed":
        options.retryFailed = true;
        break;
      case "--version": {
        const value = arguments_[index + 1];
        if (!value || !versionPattern.test(value)) {
          fail("--version requires a semantic version such as 1.2.0");
        }
        options.version = value;
        index += 1;
        break;
      }
      default:
        fail(`unknown argument: ${argument}`);
    }
  }

  if (options.build !== undefined && options.build < 1) {
    fail("--build requires a positive integer");
  }
  return options;
}

export function nextPatchVersion(version) {
  if (!versionPattern.test(version)) fail(`invalid semantic version: ${version}`);
  const [major, minor, patch] = version.split(".").map(Number);
  return `${major}.${minor}.${patch + 1}`;
}

export function compareVersions(left, right) {
  if (!versionPattern.test(left) || !versionPattern.test(right)) {
    fail(`invalid semantic version comparison: ${left}, ${right}`);
  }
  const leftParts = left.split(".").map(Number);
  const rightParts = right.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (leftParts[index] !== rightParts[index]) {
      return leftParts[index] > rightParts[index] ? 1 : -1;
    }
  }
  return 0;
}

export function expectedAssetNames(version) {
  return validatedExpectedAssetNames(version);
}

export function selectLatestRun(runs, headSha) {
  return runs
    .filter((run_) => run_.headSha === headSha)
    .sort((left, right) => right.databaseId - left.databaseId)[0];
}

export function porcelainChangedPaths(status) {
  return String(status || "")
    .split("\n")
    .filter(Boolean)
    .map((line) => line.replace(/^[ MADRCU?!]{1,2} /, ""));
}

export function requiredReleaseSecretNames() {
  return [...requiredAndroidSecrets, ...requiredMacOSSecrets, ...requiredWindowsSecrets];
}

function usage() {
  console.log(`Usage: /path/to/Resonance/app/scripts/release-now.mjs [options]

The legacy PR-based release path is disabled. Production releases must be dispatched
from the protected main branch through direct-release-build.yml with production signing.
This command is retained only to report the migration; it never creates a branch,
commit, pull request, tag, release, or build.

Options:
  -h, --help        Show this help

Use Release Studio or dispatch the protected direct-release workflow explicitly.`);
}

function readManifest() {
  const manifest = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, "release", "version.json"), "utf8"),
  );
  if (!versionPattern.test(manifest.version)) fail("release/version.json has an invalid version");
  if (!Number.isInteger(manifest.build) || manifest.build < 1) {
    fail("release/version.json has an invalid build number");
  }
  return manifest;
}

function readReleasePolicy() {
  const policy = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, releasePolicyFile), "utf8"),
  );
  if (
    policy.schemaVersion !== 1 ||
    !versionPattern.test(policy.version) ||
    !Number.isInteger(policy.build) ||
    policy.build < 1 ||
    policy.desktopSigning !== "production"
  ) {
    fail(`${releasePolicyFile} is invalid`);
  }
  return policy;
}

function writeReleasePolicy(version, build) {
  const policy = {
    schemaVersion: 1,
    version,
    build,
    desktopSigning: "production",
  };
  fs.writeFileSync(
    path.join(repositoryRoot, releasePolicyFile),
    `${JSON.stringify(policy, null, 2)}\n`,
  );
}

function git(arguments_, options = {}) {
  return output("git", arguments_, options);
}

function gh(arguments_, options = {}) {
  return output("gh", arguments_, options);
}

function ghJSON(arguments_, options = {}) {
  return runJSON("gh", arguments_, options);
}

function ensureCleanWorkingTree() {
  const dirty = git(["status", "--porcelain=v1"]);
  if (dirty) {
    fail(
      "the working tree is dirty; commit the exact app updates you want released first. " +
        "This command will not stage unrelated changes.",
    );
  }
}

function isAncestor(ancestor, descendant) {
  return succeeds("git", ["merge-base", "--is-ancestor", ancestor, descendant]);
}

function ensureCurrentSourceContainsMain(currentBranch) {
  run("git", ["fetch", "origin", "main", "--prune"], { capture: false });
  let head = git(["rev-parse", "HEAD"]);
  const main = git(["rev-parse", "origin/main"]);

  if (currentBranch === "main" && head !== main && isAncestor(head, main)) {
    run("git", ["merge", "--ff-only", "origin/main"], { capture: false });
    head = git(["rev-parse", "HEAD"]);
  }
  const mergedReleaseBranch =
    currentBranch.startsWith("release/v") && isAncestor(head, main);
  if (!isAncestor(main, head) && !mergedReleaseBranch) {
    fail(`current HEAD ${head} does not contain origin/main ${main}; update the branch first`);
  }
  return { head, main };
}

function resolveRepository() {
  run("gh", ["auth", "status"], { capture: true });
  return gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);
}

function ensureReleaseSigningSecrets(repository) {
  const secrets = ghJSON(["secret", "list", "--repo", repository, "--json", "name"]);
  const names = new Set(secrets.map((secret) => secret.name));
  const required = requiredReleaseSecretNames();
  const missing = required.filter((name) => !names.has(name));
  if (missing.length > 0) {
    fail(`missing production release-signing secret(s): ${missing.join(", ")}`);
  }
}

function remoteBranchSha(branch) {
  const result = run("git", ["ls-remote", "--heads", "origin", `refs/heads/${branch}`], {
    allowFailure: true,
  });
  return result.stdout.split(/\s+/)[0] || undefined;
}

function ensureNewReleaseTarget(repository, version, branch) {
  const tag = `v${version}`;
  if (
    succeeds("gh", ["api", `repos/${repository}/git/ref/tags/${tag}`], {
      capture: true,
    })
  ) {
    fail(`tag ${tag} already exists`);
  }
  if (remoteBranchSha(branch)) fail(`remote branch ${branch} already exists`);
  if (succeeds("git", ["show-ref", "--verify", "--quiet", `refs/heads/${branch}`])) {
    fail(`local branch ${branch} already exists`);
  }
}

function validateVersionChanges() {
  run("node", ["scripts/release-version.mjs", "--check"], { capture: false });
  run("git", ["diff", "--check"], { capture: false });
  const changed = porcelainChangedPaths(git(["status", "--porcelain=v1"])).sort();
  const expected = [...releaseFiles].sort();
  if (JSON.stringify(changed) !== JSON.stringify(expected)) {
    fail(
      `version synchronization changed an unexpected file set:\n${changed.join("\n")}`,
    );
  }
}

function releaseBody(version, build, sourceSha) {
  return `## Release\n- version: ${version}\n- build: ${build}\n- source: ${sourceSha}\n\n` +
    "The production direct-release workflow builds all four client platforms plus " +
    "the iPhone companion installers from the exact " +
    "protected main SHA in parallel; macOS and Windows are production-signed and verified. " +
    "It validates the complete asset and release-policy " +
    "contract and records exact source provenance. Publication is performed only by " +
    "the trusted direct-release workflow after its protected-environment approval.";
}

function findReleasePullRequest(repository, branch) {
  const pullRequests = ghJSON([
    "pr",
    "list",
    "--repo",
    repository,
    "--head",
    branch,
    "--state",
    "all",
    "--limit",
    "20",
    "--json",
    "number,state,mergedAt,url,headRefOid,mergeCommit",
  ]);
  return pullRequests.sort((left, right) => right.number - left.number)[0];
}

function createReleasePullRequest(
  repository,
  branch,
  version,
  build,
  sourceSha,
) {
  const url = gh([
    "pr",
    "create",
    "--repo",
    repository,
    "--base",
    "main",
    "--head",
    branch,
    "--title",
    `Prepare Resonance ${version}`,
    "--body",
    releaseBody(version, build, sourceSha),
  ]);
  console.log(`Opened ${url}`);
  return findReleasePullRequest(repository, branch);
}

async function discoverWorkflowRun(repository, workflow, headSha) {
  const pollMilliseconds = Number(process.env.RESONANCE_RELEASE_POLL_MS || 5_000);
  const timeoutMilliseconds = Number(
    process.env.RESONANCE_RELEASE_DISCOVERY_TIMEOUT_MS || 180_000,
  );
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    const runs = ghJSON([
      "run",
      "list",
      "--repo",
      repository,
      "--workflow",
      workflow,
      "--commit",
      headSha,
      "--event",
      "pull_request",
      "--limit",
      "20",
      "--json",
      "databaseId,status,conclusion,headSha,createdAt,url",
    ]);
    const run_ = selectLatestRun(runs, headSha);
    if (run_) return run_;
    await sleep(pollMilliseconds);
  }
  fail(`timed out waiting for ${workflow} on ${headSha}`);
}

async function requireSuccessfulWorkflow(repository, workflow, headSha, retryFailed) {
  let run_ = await discoverWorkflowRun(repository, workflow, headSha);
  if (run_.status === "completed" && run_.conclusion !== "success" && retryFailed) {
    console.log(`Rerunning failed ${workflow}: ${run_.url}`);
    run("gh", ["run", "rerun", String(run_.databaseId), "--repo", repository, "--failed"], {
      capture: false,
    });
    run_ = { ...run_, status: "queued", conclusion: "" };
  }
  if (run_.status !== "completed") {
    console.log(`Waiting for ${workflow}: ${run_.url}`);
    run(
      "gh",
      [
        "run",
        "watch",
        String(run_.databaseId),
        "--repo",
        repository,
        "--exit-status",
        "--interval",
        "10",
      ],
      { capture: false },
    );
  }
  const finalRun = ghJSON([
    "run",
    "view",
    String(run_.databaseId),
    "--repo",
    repository,
    "--json",
    "status,conclusion,url,headSha",
  ]);
  if (finalRun.status !== "completed" || finalRun.conclusion !== "success") {
    fail(`${workflow} did not succeed: ${finalRun.url}`);
  }
  return { ...run_, ...finalRun };
}

function currentPullRequest(repository, number) {
  return ghJSON([
    "pr",
    "view",
    String(number),
    "--repo",
    repository,
    "--json",
    "number,state,mergedAt,url,headRefOid,mergeable,mergeStateStatus,mergeCommit",
  ]);
}

function mergeReleasePullRequest(repository, pullRequest, candidateSha) {
  const current = currentPullRequest(repository, pullRequest.number);
  if (current.state !== "OPEN") return current;
  if (current.headRefOid !== candidateSha) {
    fail(`PR #${current.number} moved from ${candidateSha} to ${current.headRefOid}`);
  }
  if (current.mergeable === "CONFLICTING") {
    fail(`PR #${current.number} has merge conflicts`);
  }
  run(
    "gh",
    [
      "pr",
      "merge",
      String(current.number),
      "--repo",
      repository,
      "--merge",
      "--match-head-commit",
      candidateSha,
      "--delete-branch",
    ],
    { capture: false },
  );
  const merged = currentPullRequest(repository, current.number);
  if (merged.state !== "MERGED" || !merged.mergeCommit?.oid) {
    fail(`PR #${current.number} did not merge`);
  }
  console.log(`Merged ${merged.url} at ${merged.mergeCommit.oid}`);
  return merged;
}

async function verifyPublicRelease(
  repository,
  version,
  candidateSha,
  mergeSha,
  candidateRunId,
) {
  const tag = `v${version}`;
  const release = ghJSON([
    "release",
    "view",
    tag,
    "--repo",
    repository,
    "--json",
    "tagName,isDraft,isPrerelease,targetCommitish,url,assets",
  ]);
  if (release.isDraft || release.isPrerelease || release.tagName !== tag) {
    fail(`${tag} is not a normal published release`);
  }
  const actualAssets = release.assets.map((asset) => asset.name).sort();
  const expectedAssets = expectedAssetNames(version);
  if (JSON.stringify(actualAssets) !== JSON.stringify(expectedAssets)) {
    fail(`${tag} has an unexpected public asset set:\n${actualAssets.join("\n")}`);
  }
  const tagSha = gh([
    "api",
    `repos/${repository}/git/ref/tags/${tag}`,
    "--jq",
    ".object.sha",
  ]);
  if (![candidateSha, mergeSha].includes(tagSha)) {
    fail(`${tag} targets ${tagSha}, expected ${candidateSha} or ${mergeSha}`);
  }

  const verificationRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), `resonance-release-${version}-`),
  );
  try {
    const assetDirectory = path.join(verificationRoot, "assets");
    const provenanceDirectory = path.join(verificationRoot, "provenance");
    fs.mkdirSync(assetDirectory);
    fs.mkdirSync(provenanceDirectory);
    run(
      "gh",
      ["release", "download", tag, "--repo", repository, "--dir", assetDirectory],
      { capture: false },
    );
    run(
      "gh",
      [
        "run",
        "download",
        String(candidateRunId),
        "--repo",
        repository,
        "--name",
        `release-provenance-${tag}-${candidateSha}`,
        "--dir",
        provenanceDirectory,
      ],
      { capture: false },
    );
    const validationArguments = [
      "scripts/validate-release-assets.mjs",
      assetDirectory,
      version,
      "--signing-evidence",
      path.join(provenanceDirectory, "signing"),
    ];
    run(process.execPath, validationArguments, { capture: false });
  } finally {
    fs.rmSync(verificationRoot, { force: true, recursive: true });
  }
  console.log(`Published and verified ${release.url}`);
  return release;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.help) {
    usage();
    return;
  }

  fail(
    "the legacy PR release path is disabled; dispatch direct-release-build.yml from " +
      "protected main with production_release=true and the exact main SHA",
  );

  ensureCleanWorkingTree();
  let currentBranch = git(["branch", "--show-current"]);
  if (!currentBranch) fail("detached HEAD is not supported");
  const initialBranch = currentBranch;
  const repository = resolveRepository();
  const source = ensureCurrentSourceContainsMain(currentBranch);
  let manifest = readManifest();
  let releasePolicy = readReleasePolicy();
  if (releasePolicy.version !== manifest.version || releasePolicy.build !== manifest.build) {
    fail(`${releasePolicyFile} does not match release/version.json`);
  }
  let releaseBranchMatch = /^release\/v([0-9]+\.[0-9]+\.[0-9]+)$/.exec(currentBranch);
  const resuming = Boolean(releaseBranchMatch);
  const version = resuming
    ? releaseBranchMatch[1]
    : options.version || nextPatchVersion(manifest.version);
  const build = resuming ? manifest.build : options.build || manifest.build + 1;
  const branch = `release/v${version}`;
  const tag = `v${version}`;
  ensureReleaseSigningSecrets(repository);

  if (resuming) {
    if (manifest.version !== version) {
      fail(`${currentBranch} contains release version ${manifest.version}`);
    }
    if (options.version && options.version !== version) {
      fail(`--version ${options.version} does not match ${currentBranch}`);
    }
    if (options.build && options.build !== build) {
      fail(`--build ${options.build} does not match ${currentBranch}`);
    }
  } else {
    if (compareVersions(version, manifest.version) <= 0) {
      fail(`release version ${version} must be newer than ${manifest.version}`);
    }
    if (build <= manifest.build) {
      fail(`release build ${build} must be greater than ${manifest.build}`);
    }
  }

  console.log(
    `${options.dryRun ? "Dry-run" : "Release"} plan: ${tag} build ${build} from ${source.head}`,
  );
  console.log("Desktop mode: production signing and signing evidence required.");
  console.log("One PR; Android, iOS, macOS, and Windows build in parallel; no post-merge rebuild.");
  if (options.dryRun) return;

  if (!resuming) {
    ensureNewReleaseTarget(repository, version, branch);
    run("git", ["switch", "-c", branch], { capture: false });
    currentBranch = branch;
    run("node", ["scripts/release-version.mjs", "--set", version, String(build)], {
      capture: false,
    });
    writeReleasePolicy(version, build);
    validateVersionChanges();
    run("git", ["add", "--", ...releaseFiles], { capture: false });
    run("git", ["commit", "-m", `Prepare Resonance ${version}`], { capture: false });
    manifest = readManifest();
    releasePolicy = readReleasePolicy();
  }

  const candidateSha = git(["rev-parse", "HEAD"]);
  let pullRequest = findReleasePullRequest(repository, branch);
  if (!pullRequest || pullRequest.state === "OPEN") {
    const existingRemoteSha = remoteBranchSha(branch);
    if (existingRemoteSha && existingRemoteSha !== candidateSha) {
      fail(`remote ${branch} is ${existingRemoteSha}, but local HEAD is ${candidateSha}`);
    }
    if (!existingRemoteSha) {
      run("git", ["push", "-u", "origin", branch], { capture: false });
    }
  }
  if (!pullRequest) {
    pullRequest = createReleasePullRequest(
      repository,
      branch,
      manifest.version,
      manifest.build,
      candidateSha,
    );
  }
  if (!pullRequest) fail(`could not resolve the release PR for ${branch}`);

  let mergedPullRequest = currentPullRequest(repository, pullRequest.number);
  const candidateRun = await requireSuccessfulWorkflow(
    repository,
    "release-candidate.yml",
    candidateSha,
    options.retryFailed,
  );
  if (mergedPullRequest.state === "OPEN") {
    mergedPullRequest = mergeReleasePullRequest(repository, mergedPullRequest, candidateSha);
  } else if (mergedPullRequest.state !== "MERGED") {
    fail(`release PR ${mergedPullRequest.url} is closed without being merged`);
  }

  const mergeSha = mergedPullRequest.mergeCommit?.oid;
  if (!mergeSha) fail(`release PR ${mergedPullRequest.url} has no merge commit`);
  await requireSuccessfulWorkflow(
    repository,
    "publish-release.yml",
    candidateSha,
    options.retryFailed,
  );
  await verifyPublicRelease(
    repository,
    version,
    candidateSha,
    mergeSha,
    candidateRun.databaseId,
  );

  if (initialBranch !== branch && succeeds("git", ["show-ref", "--verify", "--quiet", `refs/heads/${initialBranch}`])) {
    run("git", ["switch", initialBranch], { capture: false });
    if (initialBranch === "main") {
      run("git", ["fetch", "origin", "main", "--prune"], { capture: false });
      run("git", ["merge", "--ff-only", "origin/main"], { capture: false });
    }
  }
}

if (path.resolve(process.argv[1] || "") === scriptPath) {
  main().catch((error) => {
    console.error(`release-now: ${error.message}`);
    process.exitCode = 1;
  });
}
