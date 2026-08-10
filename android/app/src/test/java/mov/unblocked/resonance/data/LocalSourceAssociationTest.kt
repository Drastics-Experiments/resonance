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
}
