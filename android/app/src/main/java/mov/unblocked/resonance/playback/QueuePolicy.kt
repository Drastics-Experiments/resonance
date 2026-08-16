package mov.unblocked.resonance.playback

import kotlin.random.Random

object QueuePolicy {
    data class QueueEntry<T>(
        val mediaID: String,
        val item: T,
    )

    data class QueueRebuildPlan(
        val mediaIDs: List<String>,
        val currentMediaID: String?,
        val currentIndex: Int,
        val currentItemRemoved: Boolean,
        val requiresRebuild: Boolean,
    ) {
        val shouldStopPlayback: Boolean get() = currentItemRemoved
    }

    /**
     * Builds the sole library index used while assembling a queue. The first item
     * for a stable media ID wins so malformed duplicate records cannot silently
     * replace the item that the library presented first.
     */
    fun <T> indexByMediaID(items: Iterable<T>, mediaID: (T) -> String): Map<String, T> {
        val indexed = LinkedHashMap<String, T>()
        items.forEach { item ->
            val id = mediaID(item)
            if (id.isNotBlank()) indexed.putIfAbsent(id, item)
        }
        return indexed
    }

    /**
     * Resolves requested IDs through a pre-indexed library in O(requested IDs).
     * Missing items and items that cannot produce a playable queue item are
     * omitted while order is preserved.
     */
    fun <T, R : Any> assembleQueue(
        requestedMediaIDs: Iterable<String>,
        itemsByMediaID: Map<String, T>,
        queueItem: (T) -> R?,
    ): List<QueueEntry<R>> {
        val assembled = mutableListOf<QueueEntry<R>>()
        requestedMediaIDs.forEach { mediaID ->
            val source = itemsByMediaID[mediaID] ?: return@forEach
            val item = queueItem(source) ?: return@forEach
            assembled += QueueEntry(mediaID, item)
        }
        return assembled
    }

    /** Filters a requested queue through a precomputed visible-ID set in one pass. */
    fun retainAvailable(
        requestedMediaIDs: Iterable<String>,
        availableMediaIDs: Set<String>,
    ): List<String> = requestedMediaIDs.filter(availableMediaIDs::contains)

    /**
     * Removes queued media that are not visible in the newly active scope. If
     * the current item disappears, callers must stop playback instead of
     * allowing Media3 to advance into a different profile implicitly.
     */
    fun reconcileScope(
        queueMediaIDs: List<String>,
        inScopeMediaIDs: Set<String>,
        currentMediaID: String?,
    ): QueueRebuildPlan = rebuildPlan(
        originalMediaIDs = queueMediaIDs,
        retainedMediaIDs = queueMediaIDs.filter(inScopeMediaIDs::contains),
        currentMediaID = currentMediaID,
    )

    /** Removes every occurrence of a deleted stable media ID from the queue. */
    fun reconcileDeletion(
        queueMediaIDs: List<String>,
        deletedMediaIDs: Set<String>,
        currentMediaID: String?,
    ): QueueRebuildPlan = rebuildPlan(
        originalMediaIDs = queueMediaIDs,
        retainedMediaIDs = queueMediaIDs.filterNot(deletedMediaIDs::contains),
        currentMediaID = currentMediaID,
    )

    fun nextIndex(size: Int, currentIndex: Int, shuffle: Boolean, random: Random = Random.Default): Int {
        if (size <= 0) return -1
        if (size == 1) return 0
        if (!shuffle) return (currentIndex.coerceAtLeast(0) + 1) % size
        var candidate: Int
        do candidate = random.nextInt(size) while (candidate == currentIndex)
        return candidate
    }

    /**
     * Creates one complete shuffle cycle with the current item first. Keeping the current item at
     * the front prevents an order change from jumping playback, while every remaining item is
     * visited exactly once in a freshly randomized order.
     */
    fun shuffledOrder(
        size: Int,
        currentIndex: Int,
        random: Random = Random.Default,
    ): IntArray {
        if (size <= 0) return intArrayOf()
        val remaining = (0 until size).filterNot { it == currentIndex }.shuffled(random)
        return if (currentIndex in 0 until size) {
            (listOf(currentIndex) + remaining).toIntArray()
        } else {
            remaining.toIntArray()
        }
    }

    fun previousIndex(size: Int, currentIndex: Int): Int {
        if (size <= 0) return -1
        return if (currentIndex <= 0) size - 1 else currentIndex - 1
    }

    private fun rebuildPlan(
        originalMediaIDs: List<String>,
        retainedMediaIDs: List<String>,
        currentMediaID: String?,
    ): QueueRebuildPlan {
        val normalizedCurrentID = currentMediaID?.takeIf(String::isNotBlank)
        val currentIndex = normalizedCurrentID?.let(retainedMediaIDs::indexOf) ?: -1
        return QueueRebuildPlan(
            mediaIDs = retainedMediaIDs,
            currentMediaID = normalizedCurrentID?.takeIf { currentIndex >= 0 },
            currentIndex = currentIndex,
            currentItemRemoved = normalizedCurrentID != null && currentIndex < 0,
            requiresRebuild = originalMediaIDs != retainedMediaIDs,
        )
    }
}
