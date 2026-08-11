package mov.unblocked.resonance.data

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ServerRefreshPresentationPolicyTest {
    @Test fun connectedCatalogStaysConnectedThroughoutTransientRefreshFailure() {
        val snapshot = ServerRefreshPresentationPolicy.snapshot(
            message = "Connected • 0 songs",
            isConnected = true,
        )

        assertEquals(
            "Connected • 0 songs",
            ServerRefreshPresentationPolicy.messageWhileRefreshing(snapshot),
        )
        assertEquals(
            "Connected • 0 songs",
            ServerRefreshPresentationPolicy.messageAfterFailure(snapshot, "Timed out"),
        )
    }

    @Test fun firstConnectionStillReportsProgressAndFailure() {
        val snapshot = ServerRefreshPresentationPolicy.snapshot(
            message = "Not connected",
            isConnected = false,
        )

        assertEquals("Connecting…", ServerRefreshPresentationPolicy.messageWhileRefreshing(snapshot))
        assertEquals("Timed out", ServerRefreshPresentationPolicy.messageAfterFailure(snapshot, "Timed out"))
        assertEquals("Connection failed", ServerRefreshPresentationPolicy.messageAfterFailure(snapshot, ""))
    }

    @Test fun authenticationFailureRequiresReconnectInsteadOfPreservingStaleCatalog() {
        val snapshot = ServerRefreshPresentationPolicy.snapshot(
            message = "Connected • 4 songs",
            isConnected = true,
        )
        val unauthorized = ServerException(401)
        val wrappedForbidden = IOException("Request failed", ServerException(403))

        assertTrue(ServerRefreshPresentationPolicy.isAuthenticationFailure(unauthorized))
        assertTrue(ServerRefreshPresentationPolicy.isAuthenticationFailure(wrappedForbidden))
        assertFalse(ServerRefreshPresentationPolicy.isAuthenticationFailure(ServerException(500)))
        assertFalse(ServerRefreshPresentationPolicy.preservesConnectedSession(snapshot, unauthorized))
        assertTrue(
            ServerRefreshPresentationPolicy.preservesConnectedSession(
                snapshot,
                IOException("Timed out"),
            ),
        )
        assertEquals(
            "Authentication failed. Sign in again.",
            ServerRefreshPresentationPolicy.messageAfterFailure(
                snapshot,
                unauthorized.message,
                authenticationFailure = true,
            ),
        )
    }
}
