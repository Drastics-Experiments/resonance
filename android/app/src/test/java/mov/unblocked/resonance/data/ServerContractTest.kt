package mov.unblocked.resonance.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URL

class ServerContractTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun accountEmailIsCensoredUntilExplicitlyRevealed() {
        val email = "private@example.com"
        assertEquals(AccountEmailPrivacy.CensoredAddress, AccountEmailPrivacy.displayedAddress(email, false))
        assertEquals(email, AccountEmailPrivacy.displayedAddress(email, true))
        assertEquals("Clerk account", AccountEmailPrivacy.safeDisplayName(email, email))
    }

    @Test
    fun accountScopeFallsBackOnlyWhenTheDeployedServerOmitsItsNewProfileField() {
        assertEquals(
            "legacy-library",
            AccountScopePolicy.resolvedProfileID("user_listener", null, "legacy-library"),
        )
        assertEquals(
            "default",
            AccountScopePolicy.resolvedProfileID("user_listener", null, null),
        )
        assertEquals(
            "user_listener",
            AccountScopePolicy.resolvedProfileID("user_listener", "user_listener", "legacy-library"),
        )
        assertEquals(
            null,
            AccountScopePolicy.resolvedProfileID("user_listener", "someone_else", "legacy-library"),
        )
    }

    @Test
    fun uploadResponseAcceptsTheServersNameField() {
        val response = json.decodeFromString<RemoteUpload>(
            """{"id":"song-1","name":"Example.mp3","size":123}""",
        )

        assertEquals("song-1", response.id)
        assertEquals(123L, response.size)
        assertEquals("", response.filename)
    }

    @Test
    fun audioLinkUploadsRetryOnlyTheExactOlderSchemaError() {
        assertTrue(SourceLinkSchemaCompatibility.shouldRetryLegacy(
            400,
            "Unsupported source-link schema_version",
            "audio",
        ))
        assertFalse(SourceLinkSchemaCompatibility.shouldRetryLegacy(
            400,
            "Unsupported source-link schema_version",
            "video",
        ))
        assertFalse(SourceLinkSchemaCompatibility.shouldRetryLegacy(400, "Invalid source URL", "audio"))
        assertFalse(SourceLinkSchemaCompatibility.shouldRetryLegacy(401, "Unsupported source-link schema_version", "audio"))
    }

    @Test
    fun artworkAuthorizationIsRestrictedToTheServerOrigin() {
        val server = URL("https://resonance-core.blithe-haven-9710.chatgpt.site/api/v1/songs")

        assertTrue(
            hasSameOrigin(
                URL("https://resonance-core.blithe-haven-9710.chatgpt.site/api/v1/songs/track/artwork"),
                server,
            ),
        )
        assertFalse(
            hasSameOrigin(
                URL("https://cdn.example.com/track.jpg"),
                server,
            ),
        )
        assertFalse(
            hasSameOrigin(
                URL("http://music.unblocked.mov/track.jpg"),
                server,
            ),
        )
    }

    @Test
    fun playlistDocumentDecodesSharedClipRanges() {
        val document = json.decodeFromString<RemotePlaylistsDocument>(
            """{"profile_id":"default","revision":4,"playlists":[],"liked_song_ids":[],"clip_ranges":[{"song_id":"song-1","start_seconds":15.5,"end_seconds":45.25}]}""",
        )

        assertEquals(1, document.clipRanges.size)
        assertEquals("song-1", document.clipRanges.single().songID)
        assertEquals(15.5, document.clipRanges.single().startSeconds, 0.0)
        assertEquals(45.25, document.clipRanges.single().endSeconds, 0.0)
    }

    @Test
    fun olderPlaylistDocumentsDefaultToNoClipRanges() {
        val document = json.decodeFromString<RemotePlaylistsDocument>(
            """{"revision":0,"playlists":[],"liked_song_ids":[]}""",
        )

        assertTrue(document.clipRanges.isEmpty())
    }
}
