const assert = require('node:assert/strict');
const { execFile } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { promisify } = require('node:util');
const test = require('node:test');
// The Windows job exercises Authenticode separately and has no /bin/bash.
const installerTest = process.platform === 'win32' ? test.skip : test;

const exec = promisify(execFile);
const helperPath = path.join(__dirname, '../../mac/scripts/install-update.sh');
const team = 'ABCDEFGHIJ';
const requirement = 'identifier "com.gavindietrich.LikedSongsFocus" and anchor apple generic';
const quote = value => "'" + value.replaceAll("'", "'\\''") + "'";

installerTest('macOS packaging embeds optional development pins without enabling production signing', async () => {
  const source = await fs.readFile(path.join(__dirname, '../../mac/scripts/build-electron.sh'), 'utf8');
  // Execute the build script's actual policy validation and argument assembly,
  // without running platform packaging tools or reading signing credentials.
  const validation = source.slice(source.indexOf('MAC_UPDATE_AUTHENTICITY='), source.indexOf('\ncd "$WINDOWS_DIR"'));
  const config = source.slice(source.indexOf('UPDATE_CONFIG_ARGS=('), source.indexOf('\n"$WINDOWS_DIR/node_modules/.bin/electron-builder"'));
  assert.ok(validation && config);
  const args = async (mode, teamID = '', designatedRequirement = '') => {
    const result = await exec('/bin/bash', ['-c', `set -euo pipefail\n${validation}\n${config}\nprintf '%s\\0' "\${UPDATE_CONFIG_ARGS[@]}"`], {
      timeout:10000,
      env:{...process.env, MAC_UPDATE_AUTHENTICITY:mode, MAC_UPDATE_TEAM_ID:teamID, MAC_UPDATE_DESIGNATED_REQUIREMENT:designatedRequirement},
    });
    return result.stdout.split('\0').filter(Boolean);
  };
  const development = await args('development', team, requirement);
  assert.ok(development.includes('--config.mac.identity=-'));
  assert.ok(development.includes('--config.mac.extendInfo.ResonanceUpdateTeamIdentifier=' + team));
  assert.ok(development.includes('--config.mac.extendInfo.ResonanceUpdateDesignatedRequirement=' + requirement));
  assert.ok(development.includes('--config.extraMetadata.resonanceUpdateAuthenticity=development'));
  const unpinned = await args('development');
  assert.ok(unpinned.includes('--config.mac.identity=-'));
  assert.ok(!unpinned.some(value => value.includes('ResonanceUpdateTeamIdentifier')));
  const production = await args('production', team, requirement);
  assert.ok(!production.includes('--config.mac.identity=-'));
  for (const [mode, teamID, designatedRequirement] of [
    ['production', '', ''], ['development', team, ''], ['development', '', requirement],
    ['development', 'invalid', requirement], ['development', team, requirement + '\nanchor apple'],
  ]) await assert.rejects(args(mode, teamID, designatedRequirement), error => error.code === 64);
});

// Execute the actual shell installer with only macOS platform utilities mocked.
// This checks policy decisions and filesystem replacement on any Node CI host;
// real Apple signature validation still requires the native macOS build checks.
const utilities = `
const fs = require('node:fs');
const path = require('node:path');
const [tool, ...args] = process.argv.slice(2);
if (tool === 'ditto') {
  fs.cpSync(process.env.FIXTURE_PAYLOAD, path.join(args.at(-1), 'Resonance.app'), {recursive:true});
} else {
  const infoPath = tool === 'plutil' ? args.at(-1) : path.join(args.at(-1), 'Contents/Info.plist');
  const info = JSON.parse(fs.readFileSync(infoPath, 'utf8'));
  if (tool === 'plutil') {
    const value = info[args[1]];
    if (value == null) process.exit(1);
    process.stdout.write(String(value));
  } else if (tool === 'codesign') {
    if (args.includes('--display')) {
      console.log('TeamIdentifier=' + (info.fixtureTeam ?? info.ResonanceUpdateTeamIdentifier ?? 'not set'));
    } else {
      fs.appendFileSync(process.env.FIXTURE_LOG, JSON.stringify(args) + '\\n');
      if (info.fixtureValid === false) process.exit(1);
    }
  }
}
`;

function metadata(mode, version, overrides = {}) {
  return {
    CFBundleIdentifier: 'com.gavindietrich.LikedSongsFocus',
    CFBundleShortVersionString: version,
    ResonanceUpdateAuthenticity: mode,
    ...(['production', 'development'].includes(mode) ? {
      ResonanceUpdateTeamIdentifier: team,
      ResonanceUpdateDesignatedRequirement: requirement,
    } : {}),
    ...overrides,
  };
}

async function install(t, current, candidate, optIn = '1') {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'resonance-installer-test-'));
  t.after(() => fs.rm(root, {recursive:true, force:true}));
  const installed = path.join(root, 'Installed Resonance.app');
  const payload = path.join(root, 'payload.app');
  for (const [directory, info] of [[installed, current], [payload, candidate]]) {
    await fs.mkdir(path.join(directory, 'Contents'), {recursive:true});
    await fs.writeFile(path.join(directory, 'Contents/Info.plist'), JSON.stringify(info));
  }
  const mock = path.join(root, 'utilities.cjs');
  await fs.writeFile(mock, utilities);
  let source = await fs.readFile(helperPath, 'utf8');
  for (const tool of ['plutil', 'codesign', 'ditto']) {
    source = source.replaceAll('/usr/bin/' + tool, `${quote(process.execPath)} ${quote(mock)} ${tool}`);
  }
  const helper = path.join(root, 'install-update.sh');
  const archive = path.join(root, 'update.zip');
  const log = path.join(root, 'verification.jsonl');
  await fs.writeFile(helper, source);
  await fs.writeFile(archive, 'fixture archive');
  await fs.writeFile(log, '');
  let code = 0;
  try {
    await exec('/bin/bash', [helper, archive, installed, '2147483647', '2.0.1'], {
      timeout:10000,
      env:{...process.env, TMPDIR:root, FIXTURE_PAYLOAD:payload, FIXTURE_LOG:log,
        RESONANCE_ALLOW_UNVERIFIED_UPDATES:optIn, RESONANCE_SKIP_RELAUNCH:'1'},
    });
  } catch (error) { code = error.code; }
  const adopted = JSON.parse(await fs.readFile(path.join(installed, 'Contents/Info.plist'), 'utf8'));
  const verified = (await fs.readFile(log, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);
  return {code, adopted, verified};
}

for (const [from, to] of [['development', 'development'], ['development', 'production'], ['production', 'production']]) {
  installerTest(`macOS installer accepts ${from} to ${to}`, async t => {
    const candidate = metadata(to, '2.0.1');
    const result = await install(t, metadata(from, '2.0.0'), candidate);
    assert.equal(result.code, 0);
    assert.deepEqual(result.adopted, candidate);
    assert.ok(result.verified.at(-1).includes('--strict'));
    if (to === 'production') assert.ok(result.verified.at(-1).includes('-R=' + requirement));
  });
}

for (const [name, from, to, overrides, optIn] of [
  ['unsigned downgrade', 'production', 'development', {}, '1'],
  ['missing development opt-in', 'development', 'development', {}, '0'],
  ['unknown policy', 'development', 'unknown', {}, '1'],
  ['wrong bundle', 'development', 'development', {CFBundleIdentifier:'other.app'}, '1'],
  ['wrong version', 'development', 'development', {CFBundleShortVersionString:'2.0.2'}, '1'],
  ['invalid ad-hoc bundle', 'development', 'development', {fixtureValid:false}, '1'],
  ['invalid signed upgrade', 'development', 'production', {fixtureValid:false}, '1'],
  ['mismatched signature team', 'development', 'production', {fixtureTeam:'ZZZZZZZZZZ'}, '1'],
  ['changed production team', 'production', 'production', {ResonanceUpdateTeamIdentifier:'ZZZZZZZZZZ'}, '1'],
  ['changed production requirement', 'production', 'production', {ResonanceUpdateDesignatedRequirement:'anchor apple'}, '1'],
  ['unrelated signed publisher on development upgrade', 'development', 'production', {
    ResonanceUpdateTeamIdentifier:'ZZZZZZZZZZ', fixtureTeam:'ZZZZZZZZZZ',
    ResonanceUpdateDesignatedRequirement:'identifier "com.gavindietrich.LikedSongsFocus" and certificate leaf[subject.OU] = "ZZZZZZZZZZ"',
  }, '1'],
  ['changed pinned requirement on development upgrade', 'development', 'production', {ResonanceUpdateDesignatedRequirement:'anchor apple'}, '1'],
]) {
  installerTest(`macOS installer preserves installed app on ${name}`, async t => {
    const current = metadata(from, '2.0.0');
    const result = await install(t, current, metadata(to, '2.0.1', overrides), optIn);
    assert.notEqual(result.code, 0);
    assert.deepEqual(result.adopted, current);
  });
}

for (const [name, overrides] of [
  ['missing pin', {ResonanceUpdateTeamIdentifier:null, ResonanceUpdateDesignatedRequirement:null}],
  ['missing team', {ResonanceUpdateTeamIdentifier:null}],
  ['missing requirement', {ResonanceUpdateDesignatedRequirement:null}],
  ['invalid team', {ResonanceUpdateTeamIdentifier:'invalid'}],
  ['multiline requirement', {ResonanceUpdateDesignatedRequirement:requirement + '\nanchor apple'}],
]) {
  installerTest(`macOS development updater rejects signed upgrades with ${name} but still accepts ad-hoc updates`, async t => {
    const current = metadata('development', '2.0.0', overrides);
    const rejected = await install(t, current, metadata('production', '2.0.1'));
    assert.notEqual(rejected.code, 0);
    assert.deepEqual(rejected.adopted, current);
    const accepted = await install(t, current, metadata('development', '2.0.1', overrides));
    assert.equal(accepted.code, 0);
  });
}
