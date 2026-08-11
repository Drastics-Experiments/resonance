package mov.unblocked.resonance.data

/** Keeps a proven server session visually stable while a best-effort catalog refresh runs. */
object ServerRefreshPresentationPolicy {
    data class Snapshot(
        val message: String,
        val wasConnected: Boolean,
    )

    fun snapshot(message: String, isConnected: Boolean): Snapshot = Snapshot(
        message = message,
        wasConnected = isConnected,
    )

    fun messageWhileRefreshing(snapshot: Snapshot): String =
        snapshot.message.takeIf { snapshot.wasConnected } ?: "Connecting…"

    fun isAuthenticationFailure(error: Throwable): Boolean =
        generateSequence(error) { it.cause }
            .filterIsInstance<ServerException>()
            .any { it.status == 401 || it.status == 403 }

    fun preservesConnectedSession(snapshot: Snapshot, error: Throwable): Boolean =
        snapshot.wasConnected && !isAuthenticationFailure(error)

    fun messageAfterFailure(snapshot: Snapshot, failure: String?, authenticationFailure: Boolean = false): String =
        if (authenticationFailure) {
            "Authentication failed. Sign in again."
        } else snapshot.message.takeIf { snapshot.wasConnected }
            ?: failure?.takeIf(String::isNotBlank)
            ?: "Connection failed"
}
