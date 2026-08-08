package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfilePictureScopeTest {
    @Test
    fun `profile pictures use canonical per-profile scopes`() {
        assertEquals(
            "https://music.example#profile=default",
            ProfilePictureScope.contextKey("https://MUSIC.example/library/", "  "),
        )
        assertNotEquals(
            ProfilePictureScope.filename("https://music.example", "default"),
            ProfilePictureScope.filename("https://music.example", "family"),
        )
        assertTrue(ProfilePictureScope.filename("https://music.example", "family").matches(
            Regex("[0-9a-f]{64}\\.jpg"),
        ))
    }
}
