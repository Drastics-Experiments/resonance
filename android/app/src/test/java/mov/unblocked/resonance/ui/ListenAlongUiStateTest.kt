package mov.unblocked.resonance.ui

import mov.unblocked.resonance.data.ListenAlongRole
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ListenAlongUiStateTest {
    @Test
    fun activeGuestLocksTransportButHostDoesNot() {
        val guest = ListenAlongUiState(
            status = ListenAlongConnectionStatus.Active,
            code = "ABCD-EFGH",
            role = ListenAlongRole.Guest,
        )
        val host = guest.copy(role = ListenAlongRole.Host)

        assertTrue(guest.isGuest)
        assertFalse(guest.isHost)
        assertTrue(host.isHost)
        assertFalse(host.isGuest)
    }

    @Test
    fun reconnectingGuestRemainsTransportLocked() {
        val reconnecting = ListenAlongUiState(
            status = ListenAlongConnectionStatus.Reconnecting,
            code = "ABCD-EFGH",
            role = ListenAlongRole.Guest,
        )

        assertTrue(reconnecting.isGuest)
        assertFalse(reconnecting.isActive)
    }
}
