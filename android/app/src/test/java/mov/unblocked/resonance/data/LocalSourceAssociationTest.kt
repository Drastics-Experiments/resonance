package mov.unblocked.resonance.data

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class LocalSourceAssociationTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun storesStableAndMediaLinksBesideTheRelativeFilePath() {
        val track = Track(
            id = "local-track",
            title = "Local song",
            relativePath = "Device - Local song.m4a",
        ).associatedWithLocalSource(
            sourceURL = " https://www.youtube.com/watch?v=jNQXAC9IVRw ",
            downloadSourceURL = "https://media.example/local-song.m4a",
        )

        val decoded = json.decodeFromString<Track>(json.encodeToString(track))
        assertEquals("Device - Local song.m4a", decoded.relativePath)
        assertEquals("https://www.youtube.com/watch?v=jNQXAC9IVRw", decoded.sourceURL)
        assertEquals("https://media.example/local-song.m4a", decoded.downloadSourceURL)
    }

    @Test
    fun keepsAnExistingLinkWhenAnImportHasNoReplacement() {
        val track = Track(
            title = "Local song",
            relativePath = "local.m4a",
            sourceURL = "https://soundcloud.com/artist/song",
            downloadSourceURL = "https://media.example/original.m4a",
        )

        assertEquals(track, track.associatedWithLocalSource(null, null))
    }

    @Test
    fun metadataRefreshPreservesPlaybackAndSourceProvenance() {
        val track = Track(
            id = "downloaded",
            title = "Old title",
            artist = "Old artist",
            album = "Old album",
            durationMs = 217_000,
            relativePath = "song.m4a",
            remoteID = "remote",
            sourceServer = "https://music.test",
            syncProfileID = "profile",
            sourceURL = "https://www.youtube.com/watch?v=jNQXAC9IVRw",
            downloadSourceURL = "https://media.example/song.m4a",
            artworkFilename = "old.artwork",
            contentSHA256 = "hash",
        )
        val metadata = LinkImportTrack(
            title = "Fresh title",
            artist = "Fresh artist",
            album = "Fresh album",
            durationSeconds = 999,
            artworkURL = "https://i.ytimg.com/vi/jNQXAC9IVRw/maxresdefault.jpg",
            sourceURL = "https://youtu.be/jNQXAC9IVRw",
        )

        val refreshed = DownloadedSongMetadataRefreshPolicy.apply(
            track,
            metadata,
            artworkFilename = "fresh.artwork",
        )

        assertEquals("Fresh title", refreshed.title)
        assertEquals("Fresh artist", refreshed.artist)
        assertEquals("Fresh album", refreshed.album)
        assertEquals("fresh.artwork", refreshed.artworkFilename)
        assertEquals(217_000, refreshed.durationMs)
        assertEquals(track.sourceURL, refreshed.sourceURL)
        assertEquals(track.downloadSourceURL, refreshed.downloadSourceURL)
        assertEquals("hash", refreshed.contentSHA256)
        assertEquals(track.sourceURL, DownloadedSongMetadataRefreshPolicy.sourceURL(track, fileExists = true))
        assertEquals(null, DownloadedSongMetadataRefreshPolicy.sourceURL(track, fileExists = false))
    }
}
