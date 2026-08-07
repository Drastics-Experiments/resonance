const { randomUUID } = require("node:crypto");
const fs = require("node:fs/promises");

async function replaceBackupFromPrimary(destination, backup, mode) {
  const temporary = `${backup}.${process.pid}.${randomUUID()}.tmp`;
  let handle = null;
  try {
    await fs.copyFile(destination, temporary);
    await fs.chmod(temporary, mode);
    // Windows rejects fsync on a read-only handle with EPERM. The backup is a
    // private temporary file, so open it read/write before the durability flush.
    handle = await fs.open(temporary, "r+");
    await handle.sync();
    await handle.close();
    handle = null;
    await fs.rename(temporary, backup);
    return true;
  } catch (error) {
    await handle?.close().catch(() => undefined);
    await fs.rm(temporary, { force: true }).catch(() => undefined);
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function crashSafeReplace(destination, data, options = {}) {
  const temporary = `${destination}.${process.pid}.${randomUUID()}.tmp`;
  const backup = options.backupPath || `${destination}.backup`;
  const mode = options.mode || 0o600;
  let handle = null;
  try {
    handle = await fs.open(temporary, "wx", mode);
    await handle.writeFile(data, options.encoding ? { encoding: options.encoding } : undefined);
    await handle.sync();
    await handle.close();
    handle = null;
    await replaceBackupFromPrimary(destination, backup, mode);
    await fs.rename(temporary, destination);
    return true;
  } catch (error) {
    await handle?.close().catch(() => undefined);
    await fs.rm(temporary, { force: true }).catch(() => undefined);
    throw error;
  }
}

async function crashSafeReplaceMirrored(destination, data, options = {}) {
  // The first replacement advances the primary. The second copies that exact
  // primary into the backup before replacing it with identical bytes, so an
  // accepted monotonic high-water survives loss of either one file.
  await crashSafeReplace(destination, data, options);
  await crashSafeReplace(destination, data, options);
  return true;
}

async function readPrimaryOrBackup(destination, reader, options = {}) {
  const backup = options.backupPath || `${destination}.backup`;
  try {
    return { value: await reader(await fs.readFile(destination)), recoveredFromBackup: false };
  } catch (primaryError) {
    try {
      const backupData = await fs.readFile(backup);
      const value = await reader(backupData);
      if (options.repairPrimary !== false) {
        const temporary = `${destination}.${process.pid}.${randomUUID()}.recovery.tmp`;
        try {
          const handle = await fs.open(temporary, "wx", options.mode || 0o600);
          try {
            await handle.writeFile(backupData);
            await handle.sync();
          } finally {
            await handle.close();
          }
          await fs.rename(temporary, destination);
        } catch {
          await fs.rm(temporary, { force: true }).catch(() => undefined);
        }
      }
      return { value, recoveredFromBackup: true };
    } catch {
      throw primaryError;
    }
  }
}

module.exports = {
  crashSafeReplace,
  crashSafeReplaceMirrored,
  readPrimaryOrBackup,
};
