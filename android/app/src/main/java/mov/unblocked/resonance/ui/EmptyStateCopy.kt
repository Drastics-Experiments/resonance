package mov.unblocked.resonance.ui

internal data class EmptyStateCopy(
    val title: String,
    val detail: String,
)

internal fun songCountLabel(count: Int): String =
    "$count ${if (count == 1) "song" else "songs"}"

internal fun libraryEmptyStateCopy(hasSongs: Boolean): EmptyStateCopy =
    if (hasSongs) {
        EmptyStateCopy(
            title = "No results",
            detail = "Try another search term.",
        )
    } else {
        EmptyStateCopy(
            title = "No songs yet",
            detail = "Import audio or video, or sync your music server.",
        )
    }

internal fun storageEmptyStateCopy(scope: StorageScope, hasQuery: Boolean): EmptyStateCopy {
    if (hasQuery) {
        return EmptyStateCopy(
            title = "No results",
            detail = "Try another search term.",
        )
    }
    return when (scope) {
        StorageScope.Songs -> EmptyStateCopy(
            title = "No stored songs",
            detail = "Import audio or video, or download songs from your music server.",
        )
        StorageScope.Downloads -> EmptyStateCopy(
            title = "No downloads",
            detail = "Download songs from your music server to keep them on this device.",
        )
        StorageScope.Files -> EmptyStateCopy(
            title = "No imported files",
            detail = "Import audio or video files from this device.",
        )
    }
}
