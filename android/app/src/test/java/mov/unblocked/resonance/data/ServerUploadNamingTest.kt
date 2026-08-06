package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Test

class ServerUploadNamingTest {
    @Test
    fun `managed cache hashes are replaced by track titles`() {
        assertEquals(
            "No Dogs Allowed.m4a",
            ServerUploadNaming.filename(
                "980026786a7d6c4928bb9b3fdd9e42b9b53eb7432473cac2b.m4a",
                "No Dogs Allowed",
            ),
        )
    }

    @Test
    fun `direct names are preserved and track titles are sanitized`() {
        assertEquals("Real Song.mp3", ServerUploadNaming.filename("Real Song.mp3"))
        assertEquals("Real-Song-.mp3", ServerUploadNaming.filename("cache.mp3", "Real/Song?.mp3"))
    }
}
