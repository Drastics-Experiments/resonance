package mov.unblocked.resonance.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class ServerContractTest {
    @Test
    fun uploadResponseAcceptsTheServersNameField() {
        val response = Json { ignoreUnknownKeys = true }.decodeFromString<RemoteUpload>(
            """{"id":"song-1","name":"Example.mp3","size":123}""",
        )

        assertEquals("song-1", response.id)
        assertEquals(123L, response.size)
        assertEquals("", response.filename)
    }
}
