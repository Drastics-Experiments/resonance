from pathlib import Path
import re


def replace_once(path: str, old: str, new: str, label: str) -> None:
    target = Path(path)
    source = target.read_text(encoding="utf-8")
    count = source.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one literal match, found {count}")
    target.write_text(source.replace(old, new, 1), encoding="utf-8")


def regex_once(path: str, pattern: str, replacement: str, label: str) -> None:
    target = Path(path)
    source = target.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, replacement, source, count=1, flags=re.MULTILINE)
    if count != 1:
        raise RuntimeError(f"{label}: expected one regex match, found {count}")
    target.write_text(updated, encoding="utf-8")


server_path = "windows/server-download.cjs"
server_source = Path(server_path).read_text(encoding="utf-8")
if "function serverDownloadBatchResultSnapshot(" not in server_source:
    marker = "\n\nfunction createServerDownloadPresentationCoordinator(itemCount, publish) {"
    helper = """

function serverDownloadBatchResultSnapshot({
  downloadedByIndex = [],
  replacedTrackIDsByIndex = [],
  failedByIndex = [],
} = {}) {
  const compact = (values) => Array.isArray(values) ? values.filter(Boolean) : [];
  return {
    downloaded: compact(downloadedByIndex),
    replacedTrackIDs: compact(replacedTrackIDsByIndex),
    failed: compact(failedByIndex),
  };
}
"""
    replace_once(server_path, marker, helper + marker, "snapshot helper insertion")
server_source = Path(server_path).read_text(encoding="utf-8")
if "  serverDownloadBatchResultSnapshot,\n" not in server_source:
    replace_once(
        server_path,
        "  runServerDownloadPool,\n  createServerCatalogSnapshotStore,",
        "  runServerDownloadPool,\n  serverDownloadBatchResultSnapshot,\n  createServerCatalogSnapshotStore,",
        "snapshot helper export",
    )

main_path = "windows/main.cjs"
main_source = Path(main_path).read_text(encoding="utf-8")
if "  serverDownloadBatchResultSnapshot,\n" not in main_source:
    replace_once(
        main_path,
        "  retryServerDownload,\n  runServerDownloadPool,\n  serverDownloadCanUseCatalogMetadata,",
        "  retryServerDownload,\n  runServerDownloadPool,\n  serverDownloadBatchResultSnapshot,\n  serverDownloadCanUseCatalogMetadata,",
        "snapshot helper import",
    )

main_source = Path(main_path).read_text(encoding="utf-8")
if "const completedBatchResult = () => serverDownloadBatchResultSnapshot" not in main_source:
    regex_once(
        main_path,
        r"  let policyLease = null;\n  let catalog = null;\n  const downloaded = \[\];\n  const replacedTrackIDs = \[\];\n  const failed = \[\];\n  try \{\n",
        "  let policyLease = null;\n  let catalog = null;\n  let downloadedByIndex = [];\n  let replacedTrackIDsByIndex = [];\n  let failedByIndex = [];\n  const completedBatchResult = () => serverDownloadBatchResultSnapshot({\n    downloadedByIndex,\n    replacedTrackIDsByIndex,\n    failedByIndex,\n  });\n  try {\n",
        "outer result state",
    )

main_source = Path(main_path).read_text(encoding="utf-8")
if "  downloadedByIndex = new Array(pendingDownloads.length);" not in main_source:
    regex_once(
        main_path,
        r"  const downloadedByIndex = new Array\(pendingDownloads\.length\);\n  const replacedTrackIDsByIndex = new Array\(pendingDownloads\.length\);\n  const failedByIndex = new Array\(pendingDownloads\.length\);\n",
        "  downloadedByIndex = new Array(pendingDownloads.length);\n  replacedTrackIDsByIndex = new Array(pendingDownloads.length);\n  failedByIndex = new Array(pendingDownloads.length);\n",
        "per-index result initialization",
    )

main_source = Path(main_path).read_text(encoding="utf-8")
if "return { catalog, ...completedBatchResult(), cancelled: true };" not in main_source:
    regex_once(
        main_path,
        r"  downloaded\.push\(\.\.\.downloadedByIndex\.filter\(Boolean\)\);\n  replacedTrackIDs\.push\(\.\.\.replacedTrackIDsByIndex\.filter\(Boolean\)\);\n  failed\.push\(\.\.\.failedByIndex\.filter\(Boolean\)\);\n  return \{ catalog, downloaded, replacedTrackIDs, failed \};\n  \} catch \(error\) \{\n    if \(error\?\.name === \"AbortError\"\) return \{ catalog, downloaded, replacedTrackIDs, failed, cancelled: true \};\n",
        "  return { catalog, ...completedBatchResult() };\n  } catch (error) {\n    if (error?.name === \"AbortError\") {\n      return { catalog, ...completedBatchResult(), cancelled: true };\n    }\n",
        "success and cancellation reconciliation",
    )

core_path = "windows/test/core.test.js"
core_source = Path(core_path).read_text(encoding="utf-8")
if "  serverDownloadBatchResultSnapshot,\n" not in core_source:
    replace_once(
        core_path,
        "  runServerDownloadPool,\n  retryServerDownload,",
        "  runServerDownloadPool,\n  serverDownloadBatchResultSnapshot,\n  retryServerDownload,",
        "core helper import",
    )
core_source = Path(core_path).read_text(encoding="utf-8")
if 'test("cancelled download pools retain every completed result bucket"' not in core_source:
    regression = """test(\"cancelled download pools retain every completed result bucket\", async () => {
  const controller = new AbortController();
  const downloadedByIndex = new Array(2);
  const replacedTrackIDsByIndex = new Array(2);
  const failedByIndex = new Array(2);
  let markFirstComplete;
  const firstComplete = new Promise((resolve) => { markFirstComplete = resolve; });

  await assert.rejects(
    runServerDownloadPool([0, 1], async (_value, index) => {
      if (index === 0) {
        downloadedByIndex[index] = { id: \"downloaded-a\" };
        replacedTrackIDsByIndex[index] = \"replaced-a\";
        markFirstComplete();
        return;
      }
      await firstComplete;
      failedByIndex[index] = { id: \"failed-b\", message: \"failed before cancellation\" };
      controller.abort();
    }, { concurrency: 2, signal: controller.signal }),
    { name: \"AbortError\" },
  );

  assert.deepEqual(serverDownloadBatchResultSnapshot({
    downloadedByIndex,
    replacedTrackIDsByIndex,
    failedByIndex,
  }), {
    downloaded: [{ id: \"downloaded-a\" }],
    replacedTrackIDs: [\"replaced-a\"],
    failed: [{ id: \"failed-b\", message: \"failed before cancellation\" }],
  });
});

"""
    replace_once(
        core_path,
        'test("catalog metadata fast path requires resolved context and duration", () => {',
        regression + 'test("catalog metadata fast path requires resolved context and duration", () => {',
        "cancellation regression",
    )

hardening_path = "windows/test/hardening.test.js"
hardening_source = Path(hardening_path).read_text(encoding="utf-8")
assertion = '  assert.match(serverSyncHandler, /const completedBatchResult = \\(\\) => serverDownloadBatchResultSnapshot\\(\\{[\\s\\S]+downloadedByIndex,[\\s\\S]+replacedTrackIDsByIndex,[\\s\\S]+failedByIndex/);\n'
cancellation = '  assert.match(serverSyncHandler, /if \\(error\\?\\.name === "AbortError"\\) \\{\\s+return \\{ catalog, \\.\\.\\.completedBatchResult\\(\\), cancelled: true \\};/);\n'
if assertion not in hardening_source:
    anchor = '  assert.match(appSource, /const displayedTransferComplete = itemTotal !== undefined'
    if anchor not in hardening_source:
        raise RuntimeError("hardening assertion anchor was not found")
    Path(hardening_path).write_text(
        hardening_source.replace(anchor, assertion + cancellation + anchor, 1),
        encoding="utf-8",
    )

print("patch_applied=1")
