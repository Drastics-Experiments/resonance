from pathlib import Path
import re


def read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def write(path: str, source: str) -> None:
    Path(path).write_text(source, encoding="utf-8")


def replace_once(path: str, old: str, new: str, label: str) -> None:
    source = read(path)
    count = source.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one literal match, found {count}")
    write(path, source.replace(old, new, 1))


def regex_once(path: str, pattern: str, replacement: str, label: str) -> None:
    source = read(path)
    updated, count = re.subn(pattern, replacement, source, count=1, flags=re.MULTILINE | re.DOTALL)
    if count != 1:
        raise RuntimeError(f"{label}: expected one regex match, found {count}")
    write(path, updated)


# ---------------------------------------------------------------------------
# Windows: consume the batch-reserved destination for source-provider imports.
# ---------------------------------------------------------------------------

main_path = "windows/main.cjs"
main = read(main_path)
if "reservedDestination: options.reservedDestination," not in main:
    replace_once(
        main_path,
        "    existing: options.existing,\n    destinationDirectory: options.destinationDirectory,\n    temporaryRoot: app.getPath(\"temp\"),",
        "    existing: options.existing,\n    destinationDirectory: options.destinationDirectory,\n    reservedDestination: options.reservedDestination,\n    temporaryRoot: app.getPath(\"temp\"),",
        "Windows pass reserved destination into provider importer",
    )
main = read(main_path)
if "reservedDestination: destination," not in main:
    replace_once(
        main_path,
        "          destinationDirectory: paths.remote,\n          serverOrigin: base.origin,",
        "          destinationDirectory: paths.remote,\n          reservedDestination: destination,\n          serverOrigin: base.origin,",
        "Windows pass batch reservation into saved-source download",
    )
main = read(main_path)
old_reusable = """    const reusable = pending.matching?.filePath
      && path.dirname(path.resolve(pending.matching.filePath)) === path.resolve(paths.remote)
      ? pending.matching.filePath
      : null;
"""
new_reusable = """    const reusable = !pending.savedSourceURL
      && pending.matching?.filePath
      && path.dirname(path.resolve(pending.matching.filePath)) === path.resolve(paths.remote)
      ? pending.matching.filePath
      : null;
"""
if old_reusable in main:
    replace_once(
        main_path,
        old_reusable,
        new_reusable,
        "Windows source imports reserve a fresh path instead of overwriting an installed file",
    )
elif new_reusable not in main:
    raise RuntimeError("Windows reusable-destination guard was not recognized")

platform_path = "windows/local-import-platform.cjs"
platform = read(platform_path)
if "async function reservedImportDestination(" not in platform:
    helper = """
async function reservedImportDestination(input, preferred) {
  if (typeof input?.reservedDestination !== "string" || !input.reservedDestination.trim()) {
    return uniqueDestination(input.destinationDirectory, preferred);
  }
  const directory = path.resolve(input.destinationDirectory);
  const destination = path.resolve(input.reservedDestination);
  if (path.dirname(destination) !== directory) {
    throw localImportError(
      "saving_local",
      "INVALID_RESERVED_DESTINATION",
      "The reserved provider download path is outside the managed library.",
    );
  }
  return destination;
}

"""
    replace_once(
        platform_path,
        "async function hashFile(filePath) {",
        helper + "async function hashFile(filePath) {",
        "Windows reserved provider destination helper",
    )
platform = read(platform_path)
platform = platform.replace(
    "savedPath = await uniqueDestination(input.destinationDirectory, preferred);",
    "savedPath = await reservedImportDestination(input, preferred);",
)
if platform.count("savedPath = await reservedImportDestination(input, preferred);") != 2:
    raise RuntimeError("Windows expected both audio and video provider adoptions to use the reservation")
write(platform_path, platform)
platform = read(platform_path)
if "  reservedImportDestination,\n" not in platform:
    replace_once(
        platform_path,
        "  resolveLocalImportSource,\n  runFFmpeg,",
        "  resolveLocalImportSource,\n  reservedImportDestination,\n  runFFmpeg,",
        "Windows export reserved provider destination helper",
    )

local_test_path = "windows/test/local-import.test.js"
local_test = read(local_test_path)
if "  reservedImportDestination,\n" not in local_test:
    replace_once(
        local_test_path,
        "  resolveLocalImportSource,\n  safeArtworkURL,",
        "  resolveLocalImportSource,\n  reservedImportDestination,\n  safeArtworkURL,",
        "Windows import reserved provider destination helper in tests",
    )
local_test = read(local_test_path)
if 'test("provider imports consume distinct batch-reserved destinations"' not in local_test:
    regression = """test("provider imports consume distinct batch-reserved destinations", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "resonance-reserved-provider-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const library = path.join(root, "Music");
  await fs.mkdir(library, { recursive: true });
  const first = path.join(library, "same-song.m4a");
  const second = path.join(library, "same-song 2.m4a");

  const resolved = await Promise.all([
    reservedImportDestination({ destinationDirectory: library, reservedDestination: first }, "same-song.m4a"),
    reservedImportDestination({ destinationDirectory: library, reservedDestination: second }, "same-song.m4a"),
  ]);
  assert.deepEqual(resolved, [first, second]);
  await assert.rejects(
    reservedImportDestination({
      destinationDirectory: library,
      reservedDestination: path.join(root, "outside.m4a"),
    }, "same-song.m4a"),
    /outside the managed library/i,
  );
});

"""
    replace_once(
        local_test_path,
        'test("selects the largest YouTube artwork regardless of provider array order", () => {',
        regression + 'test("selects the largest YouTube artwork regardless of provider array order", () => {',
        "Windows provider destination regression",
    )

hardening_path = "windows/test/hardening.test.js"
hardening = read(hardening_path)
windows_assertions = (
    '  assert.match(serverSyncHandler, /reservedDestination: destination/);\n'
    '  assert.match(serverSyncHandler, /const reusable = !pending\\.savedSourceURL/);\n'
)
if windows_assertions not in hardening:
    anchor = '  assert.match(serverSyncHandler, /downloadPresentation\\.update\\(pendingIndex, progressEvent\\(\\{\\s+title: serverDownloadPreparationTitle\\(savedSourceURL, "starting"\\),\\s+\\}\\)\\)/);\n'
    replace_once(
        hardening_path,
        anchor,
        anchor + windows_assertions,
        "Windows provider reservation wiring assertions",
    )


# ---------------------------------------------------------------------------
# Android: serialize duplicate detection, destination adoption, and library add.
# ---------------------------------------------------------------------------

policy_path = "android/app/src/main/java/mov/unblocked/resonance/data/DownloadItemProgressPolicy.kt"
policy = read(policy_path)
if "import kotlinx.coroutines.sync.Mutex" not in policy:
    replace_once(
        policy_path,
        "import kotlinx.coroutines.Deferred\n",
        "import kotlinx.coroutines.Deferred\nimport kotlinx.coroutines.sync.Mutex\n",
        "Android Mutex import",
    )
policy = read(policy_path)
if "internal class RemoteSourceAdoptionGate" not in policy:
    gate = """
/** Serializes only the duplicate-check and managed-file adoption critical section. */
internal class RemoteSourceAdoptionGate {
    private val mutex = Mutex()

    suspend fun <Value> run(operation: suspend () -> Value): Value {
        mutex.lock()
        return try {
            operation()
        } finally {
            mutex.unlock()
        }
    }
}

"""
    replace_once(
        policy_path,
        "internal object ProviderDownloadPreparationPolicy {",
        gate + "internal object ProviderDownloadPreparationPolicy {",
        "Android remote-source adoption gate",
    )

view_model_path = "android/app/src/main/java/mov/unblocked/resonance/ResonanceViewModel.kt"
view_model = read(view_model_path)
if "import mov.unblocked.resonance.data.RemoteSourceAdoptionGate" not in view_model:
    replace_once(
        view_model_path,
        "import mov.unblocked.resonance.data.RemoteSourceDownloadCoordinator\n",
        "import mov.unblocked.resonance.data.RemoteSourceAdoptionGate\nimport mov.unblocked.resonance.data.RemoteSourceDownloadCoordinator\n",
        "Android adoption gate import",
    )
view_model = read(view_model_path)
if "private val remoteSourceAdoptionGate = RemoteSourceAdoptionGate()" not in view_model:
    replace_once(
        view_model_path,
        "    private val remoteSourceResolutions = mutableMapOf<RemoteSourceResolutionCacheKey, LinkImportResolution>()\n",
        "    private val remoteSourceResolutions = mutableMapOf<RemoteSourceResolutionCacheKey, LinkImportResolution>()\n    private val remoteSourceAdoptionGate = RemoteSourceAdoptionGate()\n",
        "Android adoption gate field",
    )
view_model = read(view_model_path)
if "val track = remoteSourceAdoptionGate.run" not in view_model:
    old_block = """                linkTransferGeneration?.let(::requireLinkImportTransfer)
                val duplicate = library.tracks.firstOrNull {
                    it.sourceSHA256 == download.sourceSHA256 ||
                        it.contentSHA256 == download.sourceSHA256 ||
                        it.contentSHA256 == download.contentSHA256
                }
                val track = if (duplicate != null) {
                    download.file.parentFile?.deleteRecursively()
                    associateLocalImportSource(
                        duplicate,
                        download.metadata.sourceURL,
                        download.downloadSourceURL,
                        persistImmediately,
                    )
                } else {
                    if (linkTransferGeneration != null) {
                        applyLinkImportProgress(
                            LinkImportProgress(LinkImportStage.SavingLocal),
                            linkTransferGeneration,
                        )
                    }
                    repository.registerLocalImport(download).also { imported ->
                        library = normalizeLiked(library.copy(tracks = library.tracks + imported))
                        if (persistImmediately) persistLibrary()
                    }
                }
                return track
"""
    new_block = """                val track = remoteSourceAdoptionGate.run {
                    linkTransferGeneration?.let(::requireLinkImportTransfer)
                    val duplicate = library.tracks.firstOrNull {
                        it.sourceSHA256 == download.sourceSHA256 ||
                            it.contentSHA256 == download.sourceSHA256 ||
                            it.contentSHA256 == download.contentSHA256
                    }
                    if (duplicate != null) {
                        download.file.parentFile?.deleteRecursively()
                        associateLocalImportSource(
                            duplicate,
                            download.metadata.sourceURL,
                            download.downloadSourceURL,
                            persistImmediately = false,
                        )
                    } else {
                        if (linkTransferGeneration != null) {
                            applyLinkImportProgress(
                                LinkImportProgress(LinkImportStage.SavingLocal),
                                linkTransferGeneration,
                            )
                        }
                        repository.registerLocalImport(download).also { imported ->
                            library = normalizeLiked(library.copy(tracks = library.tracks + imported))
                        }
                    }
                }
                if (persistImmediately) persistLibrary()
                return track
"""
    replace_once(
        view_model_path,
        old_block,
        new_block,
        "Android serialize duplicate detection and local adoption",
    )

android_test_path = "android/app/src/test/java/mov/unblocked/resonance/data/DownloadItemProgressPolicyTest.kt"
android_test = read(android_test_path)
if "import kotlinx.coroutines.async" not in android_test:
    replace_once(
        android_test_path,
        "import kotlinx.coroutines.CompletableDeferred\n",
        "import kotlinx.coroutines.CompletableDeferred\nimport kotlinx.coroutines.async\nimport kotlinx.coroutines.yield\n",
        "Android adoption gate test imports",
    )
android_test = read(android_test_path)
if "sourceAdoptionGateSerializesDuplicateDetectionAndRegistration" not in android_test:
    regression = """    @Test fun sourceAdoptionGateSerializesDuplicateDetectionAndRegistration() = runTest {
        val gate = RemoteSourceAdoptionGate()
        val firstEntered = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val secondEntered = CompletableDeferred<Unit>()

        val first = async {
            gate.run {
                firstEntered.complete(Unit)
                releaseFirst.await()
                "first"
            }
        }
        firstEntered.await()
        val second = async {
            gate.run {
                secondEntered.complete(Unit)
                "second"
            }
        }
        yield()
        assertFalse(secondEntered.isCompleted)

        releaseFirst.complete(Unit)
        assertEquals("first", first.await())
        assertEquals("second", second.await())
        assertTrue(secondEntered.isCompleted)
    }

"""
    replace_once(
        android_test_path,
        "    @Test fun mediaAcquisitionDoesNotAwaitMetadataEnrichment() = runTest {",
        regression + "    @Test fun mediaAcquisitionDoesNotAwaitMetadataEnrichment() = runTest {",
        "Android adoption gate regression",
    )


# ---------------------------------------------------------------------------
# macOS: reconcile and persist every installed prefetch before cancellation.
# ---------------------------------------------------------------------------

mac_path = "mac/Sources/Resonance/PlayerModel.swift"
mac = read(mac_path)
if "static func shouldCheckpointInstalledPrefetch(" not in mac:
    methods = """
    static func shouldCheckpointInstalledPrefetch(
        isSourceLinkRecord: Bool,
        downloadedThisSync: Bool
    ) -> Bool {
        !isSourceLinkRecord && downloadedThisSync
    }

    static func reconciliationOrder(
        itemCount: Int,
        checkpointIndices: Set<Int>
    ) -> [Int] {
        let indices = Array(0..<max(itemCount, 0))
        let checkpointed = indices.filter(checkpointIndices.contains)
        return checkpointed + indices.filter { !checkpointIndices.contains($0) }
    }

"""
    replace_once(
        mac_path,
        "    static func canUseCatalogMetadata(\n",
        methods + "    static func canUseCatalogMetadata(\n",
        "macOS installed-prefetch checkpoint policy",
    )
mac = read(mac_path)
if "let checkpointPrefetchIndices = Set(songs.indices.filter" not in mac:
    insertion = """            let checkpointPrefetchIndices = Set(songs.indices.filter { index in
                MacBatchDownloadPolicy.shouldCheckpointInstalledPrefetch(
                    isSourceLinkRecord: songs[index].isSourceLinkRecord,
                    downloadedThisSync: downloadPlans[index].validatedCache?.downloadedThisSync == true
                )
            })
            let reconciliationOrder = MacBatchDownloadPolicy.reconciliationOrder(
                itemCount: songs.count,
                checkpointIndices: checkpointPrefetchIndices
            )

"""
    replace_once(
        mac_path,
        "            downloadBatchTotal = pendingSongIDs.count\n",
        insertion + "            downloadBatchTotal = pendingSongIDs.count\n",
        "macOS checkpoint reconciliation order",
    )
mac = read(mac_path)
old_loop = """            for (remote, plan) in zip(songs, downloadPlans) {
                try Task.checkCancellation()
                guard catalogProfileID == syncProfileID,
"""
new_loop = """            for index in reconciliationOrder {
                let remote = songs[index]
                let plan = downloadPlans[index]
                let checkpointsInstalledPrefetch = checkpointPrefetchIndices.contains(index)
                if !checkpointsInstalledPrefetch {
                    try Task.checkCancellation()
                }
                guard catalogProfileID == syncProfileID,
"""
if old_loop in mac:
    replace_once(
        mac_path,
        old_loop,
        new_loop,
        "macOS process installed prefetches before cancellation",
    )
elif new_loop not in mac:
    raise RuntimeError("macOS reconciliation loop was not recognized")
mac = read(mac_path)
if "if checkpointsInstalledPrefetch { persistLibrary() }" not in mac:
    replace_once(
        mac_path,
        "                    changedCount += 1\n                    if isPendingDownload { downloadProgress = 1 }\n",
        "                    changedCount += 1\n                    if checkpointsInstalledPrefetch { persistLibrary() }\n                    if isPendingDownload { downloadProgress = 1 }\n",
        "macOS persist installed prefetch checkpoint",
    )

mac_test_path = "mac/Tests/ResonanceTests/DownloadPreparationProgressTests.swift"
mac_test = read(mac_test_path)
if "installedPrefetchesReconcileBeforeCancelledWork" not in mac_test:
    regression = """
    @Test("installed prefetches reconcile before cancelled or unfinished work")
    func installedPrefetchesReconcileBeforeCancelledWork() {
        #expect(MacBatchDownloadPolicy.shouldCheckpointInstalledPrefetch(
            isSourceLinkRecord: false,
            downloadedThisSync: true
        ))
        #expect(!MacBatchDownloadPolicy.shouldCheckpointInstalledPrefetch(
            isSourceLinkRecord: true,
            downloadedThisSync: true
        ))
        #expect(MacBatchDownloadPolicy.reconciliationOrder(
            itemCount: 5,
            checkpointIndices: [3, 1]
        ) == [1, 3, 0, 2, 4])
    }
"""
    replace_once(
        mac_test_path,
        "\n}\n",
        regression + "\n}\n",
        "macOS installed-prefetch cancellation regression",
    )

print("patch_applied=1")
