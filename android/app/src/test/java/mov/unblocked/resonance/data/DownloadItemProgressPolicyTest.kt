package mov.unblocked.resonance.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadItemProgressPolicyTest {
    @Test fun zeroBytesHaveNoPreparingModeOrDeterminateZeroPercent() {
        assertEquals(
            DownloadProgressDisplayMode.IndeterminateTransfer,
            DownloadProgressDisplayPolicy.mode(bytesTransferred = 0L, totalBytes = 10_000L),
        )
        assertEquals(
            DownloadProgressDisplayMode.DeterminateTransfer,
            DownloadProgressDisplayPolicy.mode(bytesTransferred = 1L, totalBytes = 10_000L),
        )
        assertEquals(
            DownloadProgressDisplayMode.IndeterminateTransfer,
            DownloadProgressDisplayPolicy.mode(bytesTransferred = 1L, totalBytes = null),
        )
        assertEquals("<1%", DownloadProgressDisplayPolicy.percentageLabel(.001f))
        assertEquals("1%", DownloadProgressDisplayPolicy.percentageLabel(.01f))
    }

    @Test fun mediaAcquisitionDoesNotAwaitMetadataEnrichment() = runTest {
        val metadata = CompletableDeferred<String?>()
        var mediaStarted = false

        val acquisition = RemoteSourceDownloadCoordinator.acquireMedia(
            metadata = metadata,
        ) {
            mediaStarted = true
            "audio-bytes"
        }

        assertTrue(mediaStarted)
        assertEquals("audio-bytes", acquisition.media)
        assertFalse(metadata.isCompleted)
        assertNull(RemoteSourceDownloadCoordinator.completedMetadataOrNull(acquisition.metadata))

        metadata.complete("final tags")
        assertEquals(
            "final tags",
            RemoteSourceDownloadCoordinator.completedMetadataOrNull(acquisition.metadata),
        )
    }

    @Test fun credentialMutationRunsOnlyAfterDownloadInvalidation() {
        val events = mutableListOf<String>()

        RemoteDownloadContextChangePolicy.mutateAfterInvalidation(
            invalidateDownload = { events += "download invalidated" },
            mutation = { events += "credentials cleared" },
        )

        assertEquals(listOf("download invalidated", "credentials cleared"), events)
    }

    @Test fun catalogMetadataCanBeReusedForAStoredSourceDownload() {
        val song = RemoteSong(
            id = "song-a",
            filename = "opaque-record",
            title = "Catalog title",
            artist = "Catalog artist",
            album = "Catalog album",
            size = 0L,
            modifiedAt = "2026-01-01T00:00:00Z",
            contentType = "application/json",
            downloadURL = "/download/song-a",
            streamURL = "/stream/song-a",
            durationSeconds = 123.8,
            artworkURL = "https://images.example/song.jpg",
            sourceURL = "https://open.spotify.com/track/0123456789012345678901",
            mediaKind = "audio",
            isSourceLinkRecord = true,
            isMetadataLoading = false,
        )

        val metadata = requireNotNull(RemoteSongDownloadMetadataPolicy.knownTrack(song))
        assertEquals("Catalog title", metadata.title)
        assertEquals("Catalog artist", metadata.artist)
        assertEquals("Catalog album", metadata.album)
        assertEquals(123, metadata.durationSeconds)
        assertEquals(song.sourceURL, metadata.sourceURL)
    }

    @Test fun unresolvedCatalogPlaceholderIsNotTreatedAsKnownMetadata() {
        val song = RemoteSong(
            id = "song-a",
            filename = "opaque-record",
            title = "Resolving metadata…",
            artist = "On-device lookup",
            album = "Link only",
            size = 0L,
            modifiedAt = "2026-01-01T00:00:00Z",
            contentType = "application/json",
            downloadURL = "/download/song-a",
            streamURL = "/stream/song-a",
            sourceURL = "https://www.youtube.com/watch?v=abcdefghijk",
            mediaKind = "audio",
            isSourceLinkRecord = true,
            isMetadataLoading = true,
        )

        assertNull(RemoteSongDownloadMetadataPolicy.knownTrack(song))
    }

    @Test fun sourceResolutionKeysAreScopedToExactServerProfileAndAccountContext() {
        val source = "https://www.youtube.com/watch?v=abcdefghijk"
        val context = ServerProfileContext(
            serverURL = "https://Music.Example/library",
            profileID = "profile-a",
            connectionGeneration = 7L,
        )
        val key = requireNotNull(RemoteSourceResolutionCachePolicy.key(
            context = context,
            mediaMode = LinkImportMediaMode.Audio,
            sourceURL = source,
            accountScope = "account-a",
        ))
        val sameCanonicalContext = requireNotNull(RemoteSourceResolutionCachePolicy.key(
            context = context.copy(serverURL = "https://music.example:443/other-path"),
            mediaMode = LinkImportMediaMode.Audio,
            sourceURL = source,
            accountScope = "account-a",
        ))

        assertEquals(key, sameCanonicalContext)
        assertNotEquals(key, requireNotNull(RemoteSourceResolutionCachePolicy.key(
            context = context.copy(profileID = "profile-b"),
            mediaMode = LinkImportMediaMode.Audio,
            sourceURL = source,
            accountScope = "account-a",
        )))
        assertNotEquals(key, requireNotNull(RemoteSourceResolutionCachePolicy.key(
            context = context.copy(serverURL = "https://other.example"),
            mediaMode = LinkImportMediaMode.Audio,
            sourceURL = source,
            accountScope = "account-a",
        )))
        assertNotEquals(key, requireNotNull(RemoteSourceResolutionCachePolicy.key(
            context = context.copy(connectionGeneration = 8L),
            mediaMode = LinkImportMediaMode.Audio,
            sourceURL = source,
            accountScope = "account-a",
        )))
        assertNotEquals(key, requireNotNull(RemoteSourceResolutionCachePolicy.key(
            context = context,
            mediaMode = LinkImportMediaMode.Audio,
            sourceURL = source,
            accountScope = "account-b",
        )))
        assertNotEquals(key, requireNotNull(RemoteSourceResolutionCachePolicy.key(
            context = context,
            mediaMode = LinkImportMediaMode.Video,
            sourceURL = source,
            accountScope = "account-a",
        )))
        assertNull(RemoteSourceResolutionCachePolicy.key(
            context = context,
            mediaMode = LinkImportMediaMode.Audio,
            sourceURL = "https://user:secret@www.youtube.com/watch?v=abcdefghijk",
            accountScope = "account-a",
        ))
    }

    @Test fun correctedCatalogMetadataInvalidatesSameSourceResolution() {
        val source = "https://www.youtube.com/watch?v=abcdefghijk"
        val context = ServerProfileContext("https://music.example", "profile-a", 7L)
        val key = requireNotNull(RemoteSourceResolutionCachePolicy.key(
            context = context,
            mediaMode = LinkImportMediaMode.Audio,
            sourceURL = source,
            accountScope = "account-a",
        ))
        val cachedMetadata = LinkImportTrack(
            title = "Original title",
            artist = "Artist",
            sourceURL = source,
        )
        val resolution = LinkImportResolution(
            track = cachedMetadata,
            candidates = listOf(LinkImportCandidate(
                videoID = "abcdefghijk",
                title = cachedMetadata.title,
                artist = cachedMetadata.artist,
                durationSeconds = null,
                thumbnailURL = null,
                sourceURL = source,
                score = 1.0,
            )),
        )

        assertTrue(RemoteSourceResolutionCachePolicy.canReuse(
            resolution = resolution,
            cachedKey = key,
            expectedKey = key,
            knownCatalogMetadata = cachedMetadata,
        ))
        assertFalse(RemoteSourceResolutionCachePolicy.canReuse(
            resolution = resolution,
            cachedKey = key,
            expectedKey = key,
            knownCatalogMetadata = cachedMetadata.copy(title = "Corrected title"),
        ))
        val otherProfileKey = requireNotNull(RemoteSourceResolutionCachePolicy.key(
            context = context.copy(profileID = "profile-b"),
            mediaMode = LinkImportMediaMode.Audio,
            sourceURL = source,
            accountScope = "account-a",
        ))
        assertFalse(RemoteSourceResolutionCachePolicy.canReuse(
            resolution = resolution,
            cachedKey = key,
            expectedKey = otherProfileKey,
            knownCatalogMetadata = cachedMetadata,
        ))
    }

    @Test fun cachedSongsAreExcludedFromTheVisibleBatchCounter() {
        val cached = RemoteSong(
            id = "cached-a",
            filename = "cached.m4a",
            title = "Cached A",
            artist = "Artist",
            album = "Album",
            size = 1L,
            modifiedAt = "2026-01-01T00:00:00Z",
            contentType = "audio/mp4",
            downloadURL = "/download/cached-a",
            streamURL = "/stream/cached-a",
            durationSeconds = 1.0,
        )
        val pending = cached.copy(id = "pending-b", filename = "pending.m4a", title = "Pending B")

        val batch = PendingDownloadBatchPolicy.songs(
            requestedSongs = listOf(cached, pending),
            existingRemoteSongIDs = setOf(cached.id),
        )
        val presentation = DownloadItemProgressPolicy.fromCatalogTransfer(
            progress = TransferProgress(
                completed = 0,
                total = batch.size,
                currentFilename = pending.filename,
                currentItem = 1,
                currentSongID = pending.id,
                currentTitle = pending.title,
            ),
            completedBefore = 0,
            batchTotal = batch.size,
            catalogTitlesByID = batch.associate { it.id to it.title },
        )

        assertEquals(listOf("pending-b"), batch.map(RemoteSong::id))
        assertEquals(1, presentation.currentItem)
        assertEquals(1, presentation.totalItems)
    }

    @Test fun catalogTitleAndCurrentSongBytesDriveThePresentation() {
        val presentation = DownloadItemProgressPolicy.fromCatalogTransfer(
            progress = TransferProgress(
                completed = 1,
                total = 4,
                currentFilename = "3f1dd0f6-download.part",
                currentItem = 2,
                currentSongID = "song-b",
                currentTitle = "Stale resolver title",
                bytesTransferred = 25L,
                totalBytes = 100L,
            ),
            completedBefore = 1,
            batchTotal = 10,
            catalogTitlesByID = mapOf("song-b" to "Catalog Song Title"),
        )

        assertEquals(3, presentation.currentItem)
        assertEquals(10, presentation.totalItems)
        assertEquals("Catalog Song Title", presentation.title)
        assertEquals(25L, presentation.bytesTransferred)
        assertEquals(100L, presentation.totalBytes)
        assertEquals(.25f, presentation.fraction, 0f)
    }

    @Test fun retryStartsTheSameSongAtZeroInsteadOfKeepingAggregateProgress() {
        val retry = DownloadItemProgressPolicy.fromBytes(
            currentItem = 3,
            totalItems = 10,
            title = "Catalog Song Title",
            bytesTransferred = 0L,
            totalBytes = 200L,
        )

        assertEquals(3, retry.currentItem)
        assertEquals("Catalog Song Title", retry.title)
        assertEquals(0f, retry.fraction, 0f)
    }

    @Test fun failedCandidateBoundaryHidesPartialBytesBeforeRetryOrFinalFailure() {
        val boundary = DownloadItemProgressPolicy.hiddenBoundary(
            currentItem = 3,
            totalItems = 10,
            title = "Catalog Song Title",
        )

        assertEquals(3, boundary.currentItem)
        assertEquals(10, boundary.totalItems)
        assertEquals("Catalog Song Title", boundary.title)
        assertEquals(0L, boundary.bytesTransferred)
        assertNull(boundary.totalBytes)
        assertEquals(0f, boundary.fraction, 0f)
    }

    @Test fun postByteProcessingAndTerminalEventsCannotReopenTheByteCard() {
        val lastByte = TransferProgress(
            completed = 1,
            total = 4,
            currentFilename = "opaque-download.part",
            currentItem = 2,
            currentSongID = "song-b",
            currentTitle = "Catalog Song Title",
            bytesTransferred = 100L,
            totalBytes = 100L,
        )
        val processing = TransferProgressBoundaryPolicy.hidden(lastByte)
        val terminal = TransferProgressBoundaryPolicy.hidden(
            lastByte.copy(completed = 2, currentItemComplete = true),
        )

        listOf(processing, terminal).forEach { hidden ->
            assertEquals(0L, hidden.bytesTransferred)
            assertNull(hidden.totalBytes)
            assertEquals(2, hidden.currentItem)
            assertEquals("song-b", hidden.currentSongID)
        }
        assertFalse(processing.currentItemComplete)
        assertTrue(terminal.currentItemComplete)
        assertEquals(2, terminal.completed)
    }

    @Test fun completedUnknownLengthTransferCanStillFinishItsBar() {
        assertEquals(
            1f,
            DownloadItemProgressPolicy.fromBytes(
                currentItem = 1,
                totalItems = 1,
                title = "Song",
                bytesTransferred = 50L,
                totalBytes = null,
                isComplete = true,
            ).fraction,
            0f,
        )
    }

    @Test fun concurrentTransfersKeepTheFirstByteActivePresentationOwnerStable() {
        val coordinator = BatchDownloadPresentationCoordinator(4)
        val second = TransferProgress(
            completed = 0,
            total = 4,
            currentFilename = "second.m4a",
            currentItem = 2,
            currentTitle = "Second",
            bytesTransferred = 40L,
            totalBytes = 100L,
        )
        val first = second.copy(
            currentFilename = "first.m4a",
            currentItem = 1,
            currentTitle = "First",
            bytesTransferred = 10L,
        )
        val third = second.copy(
            currentFilename = "third.m4a",
            currentItem = 3,
            currentTitle = "Third",
            bytesTransferred = 70L,
        )

        assertEquals(second, coordinator.update(1, second))
        assertNull(coordinator.update(0, first))
        assertNull(coordinator.update(2, third))
        assertEquals(1, coordinator.currentIndex())

        assertEquals(first, coordinator.complete(1))
        assertEquals(0, coordinator.currentIndex())
        assertEquals(third, coordinator.complete(0))
        assertEquals(2, coordinator.currentIndex())
        assertNull(coordinator.update(0, first.copy(bytesTransferred = 90L)))
    }



    @Test fun mixedProviderBudgetKeepsDirectFilesMoving() {
        assertEquals(
            MixedProviderConcurrencyBudget(sourceConcurrency = 2, directConcurrency = 1),
            MixedProviderDownloadPolicy.budget(sourceCount = 8, directCount = 5),
        )
        assertEquals(
            MixedProviderConcurrencyBudget(sourceConcurrency = 0, directConcurrency = 3),
            MixedProviderDownloadPolicy.budget(sourceCount = 0, directCount = 5),
        )
        assertEquals(
            MixedProviderConcurrencyBudget(sourceConcurrency = 3, directConcurrency = 0),
            MixedProviderDownloadPolicy.budget(sourceCount = 5, directCount = 0),
        )
    }

    @Test fun byteActiveDirectSongCanReplaceEarlierProviderPreparation() {
        val coordinator = DownloadItemPresentationCoordinator(3)
        coordinator.update(0, DownloadItemProgressPolicy.fromBytes(
            currentItem = 1,
            totalItems = 3,
            title = "Slow YouTube song",
            bytesTransferred = 0L,
            totalBytes = null,
            detail = "Inspecting YouTube",
        ))
        val direct = DownloadItemProgressPolicy.fromBytes(
            currentItem = 2,
            totalItems = 3,
            title = "Direct song",
            bytesTransferred = 100L,
            totalBytes = 1_000L,
            detail = "Downloading from server",
        )
        assertEquals(direct, coordinator.update(1, direct))
        assertEquals(1, coordinator.currentIndex())
    }

    @Test fun providerPreparationNamesYouTubeSoundCloudAndSpotify() {
        assertEquals(
            "Inspecting YouTube",
            ProviderDownloadPreparationPolicy.detail(
                "https://www.youtube.com/watch?v=abcdefghijk",
                LinkImportStage.InspectingSource,
            ),
        )
        assertEquals(
            "Resolving SoundCloud",
            ProviderDownloadPreparationPolicy.detail(
                "https://soundcloud.com/artist/song",
                LinkImportStage.ResolvingMetadata,
            ),
        )
        assertEquals(
            "Finding a YouTube match",
            ProviderDownloadPreparationPolicy.detail(
                "https://open.spotify.com/track/0123456789012345678901",
                LinkImportStage.SearchingCandidates,
            ),
        )
    }
}
