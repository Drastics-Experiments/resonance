const path = require("node:path");

function cleanFilenameStem(value) {
  return String(value || "")
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, "-")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/[. ]+$/g, "")
    .slice(0, 180);
}

function serverUploadFilename(filePath, title) {
  const sourceName = path.basename(String(filePath || ""));
  const sourceExtension = path.extname(sourceName);
  const safeExtension = sourceExtension.replace(/[^.a-z0-9]/gi, "").slice(0, 16);
  const sourceStem = path.basename(sourceName, sourceExtension);
  let preferredStem = String(title || "").trim();
  if (safeExtension && preferredStem.toLocaleLowerCase().endsWith(safeExtension.toLocaleLowerCase())) {
    preferredStem = preferredStem.slice(0, -safeExtension.length);
  }
  const stem = cleanFilenameStem(preferredStem) || cleanFilenameStem(sourceStem) || "Untitled song";
  return `${stem}${safeExtension}`;
}

module.exports = { serverUploadFilename };
