package mov.unblocked.resonance.ui

import mov.unblocked.resonance.data.ListenAlongRole
import org.junit.Assert.assertEquals
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
            participantCount = 3,
        )
        val host = guest.copy(role = ListenAlongRole.Host)

        assertTrue(guest.isGuest)
        assertTrue(guest.showsParticipantPlaybackIndicator)
        assertEquals(3, guest.participantCount)
        assertFalse(guest.isHost)
        assertTrue(host.isHost)
        assertFalse(host.isGuest)
        assertFalse(host.showsParticipantPlaybackIndicator)
    }

    @Test
    fun reconnectingGuestRemainsTransportLocked() {
        val reconnecting = ListenAlongUiState(
            status = ListenAlongConnectionStatus.Reconnecting,
            code = "ABCD-EFGH",
            role = ListenAlongRole.Guest,
        )

        assertTrue(reconnecting.isGuest)
        assertTrue(reconnecting.showsParticipantPlaybackIndicator)
        assertFalse(reconnecting.isActive)
    }

    @Test
    fun peopleIndicatorIsHiddenOutsideAListenAlongSession() {
        assertFalse(ListenAlongUiState().showsParticipantPlaybackIndicator)
        assertFalse(
            ListenAlongUiState(
                status = ListenAlongConnectionStatus.Ended,
                code = "ABCD-EFGH",
                role = ListenAlongRole.Guest,
            ).showsParticipantPlaybackIndicator,
        )
    }
}
