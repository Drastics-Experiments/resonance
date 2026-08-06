const path = require("node:path");

function isManagedLibraryFile(filePath, roots) {
  const resolvedFile = path.resolve(String(filePath || ""));
  return (Array.isArray(roots) ? roots : []).some((root) => {
    const relative = path.relative(path.resolve(String(root || "")), resolvedFile);
    return Boolean(relative) && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
  });
}

module.exports = { isManagedLibraryFile };
