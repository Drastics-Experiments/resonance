const path = require("node:path");
const { sanitizeWindowsFilename } = require("./filename-policy.cjs");

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
  return sanitizeWindowsFilename(`${stem}${safeExtension}`, {
    fallback: `Untitled song${safeExtension}`,
    pathInput: false,
  });
}

function policyBlockedUploadEntries(requestedFiles, completedRetryIDs, attemptsByRetryID, message) {
  const completed = completedRetryIDs instanceof Set ? completedRetryIDs : new Set();
  const attempts = attemptsByRetryID instanceof Map ? attemptsByRetryID : new Map();
  return (Array.isArray(requestedFiles) ? requestedFiles : [])
    .filter((item) => item?.retryID && !completed.has(item.retryID))
    .map((item) => ({
      item,
      failure: {
        retryID: item.retryID,
        trackID: item.trackID || null,
        title: item.title || path.basename(item.uploadFilename || item.filePath, path.extname(item.uploadFilename || item.filePath)),
        artist: item.artist || "",
        filename: item.uploadFilename || path.basename(item.filePath),
        attempts: attempts.get(item.retryID) || 0,
        status: "policy_blocked",
        message: String(message || "Uploads were disabled by the signed server configuration."),
      },
    }));
}

module.exports = { policyBlockedUploadEntries, serverUploadFilename };
