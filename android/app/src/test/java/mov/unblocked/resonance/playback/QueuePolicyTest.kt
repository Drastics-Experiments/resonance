package mov.unblocked.resonance.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QueuePolicyTest {
    @Test fun queueAssemblyUsesOneIndexedLookupPerRequestedIdAndPreservesOrder() {
        data class Source(val id: String, val playable: Boolean = true)

        val indexed = QueuePolicy.indexByMediaID(
            listOf(Source("a"), Source("b"), Source("skip", playable = false)),
            Source::id,
        )
        var lookups = 0
        val countingIndex = object : Map<String, Source> by indexed {
            override fun get(key: String): Source? {
                lookups += 1
                return indexed[key]
            }
        }

        val queue = QueuePolicy.assembleQueue(
            requestedMediaIDs = listOf("b", "missing", "a", "b", "skip"),
            itemsByMediaID = countingIndex,
        ) { source -> source.id.uppercase().takeIf { source.playable } }

        assertEquals(5, lookups)
        assertEquals(listOf("b", "a", "b"), queue.map { it.mediaID })
        assertEquals(listOf("B", "A", "B"), queue.map { it.item })
    }

    @Test fun indexKeepsFirstRecordForDuplicateStableMediaId() {
        data class Source(val id: String, val value: String)

        val indexed = QueuePolicy.indexByMediaID(
            listOf(Source("same", "first"), Source("same", "second"), Source("", "blank")),
            Source::id,
        )

        assertEquals(setOf("same"), indexed.keys)
        assertEquals("first", indexed.getValue("same").value)
    }

    @Test fun playlistFilteringDropsHiddenAndStaleIdsWhilePreservingVisibleOrder() {
        val visible = setOf("local", "active-profile", "later")

        assertEquals(
            listOf("local", "active-profile", "later"),
            QueuePolicy.retainAvailable(
                requestedMediaIDs = listOf("hidden-profile", "local", "missing", "active-profile", "later"),
                availableMediaIDs = visible,
            ),
        )
    }

    @Test fun profileReconciliationDropsEveryOutOfScopeItemButKeepsLocalCurrentItem() {
        val plan = QueuePolicy.reconcileScope(
            queueMediaIDs = listOf("local", "old-profile-a", "new-profile", "old-profile-b"),
            inScopeMediaIDs = setOf("local", "new-profile"),
            currentMediaID = "local",
        )

        assertEquals(listOf("local", "new-profile"), plan.mediaIDs)
        assertEquals("local", plan.currentMediaID)
        assertEquals(0, plan.currentIndex)
        assertFalse(plan.currentItemRemoved)
        assertFalse(plan.shouldStopPlayback)
        assertTrue(plan.requiresRebuild)
    }

    @Test fun profileReconciliationStopsWhenCurrentItemLeavesScope() {
        val plan = QueuePolicy.reconcileScope(
            queueMediaIDs = listOf("local", "old-profile", "new-profile"),
            inScopeMediaIDs = setOf("local", "new-profile"),
            currentMediaID = "old-profile",
        )

        assertEquals(listOf("local", "new-profile"), plan.mediaIDs)
        assertNull(plan.currentMediaID)
        assertEquals(-1, plan.currentIndex)
        assertTrue(plan.currentItemRemoved)
        assertTrue(plan.shouldStopPlayback)
    }

    @Test fun deletionReconciliationRemovesAllOccurrencesAndPreservesCurrentIndex() {
        val plan = QueuePolicy.reconcileDeletion(
            queueMediaIDs = listOf("before", "deleted", "current", "deleted", "after"),
            deletedMediaIDs = setOf("deleted"),
            currentMediaID = "current",
        )

        assertEquals(listOf("before", "current", "after"), plan.mediaIDs)
        assertEquals("current", plan.currentMediaID)
        assertEquals(1, plan.currentIndex)
        assertFalse(plan.shouldStopPlayback)
        assertTrue(plan.requiresRebuild)
    }

    @Test fun deletionReconciliationStopsWhenCurrentItemWasDeleted() {
        val plan = QueuePolicy.reconcileDeletion(
            queueMediaIDs = listOf("before", "deleted", "after"),
            deletedMediaIDs = setOf("deleted"),
            currentMediaID = "deleted",
        )

        assertEquals(listOf("before", "after"), plan.mediaIDs)
        assertNull(plan.currentMediaID)
        assertEquals(-1, plan.currentIndex)
        assertTrue(plan.shouldStopPlayback)
    }

    @Test fun unchangedScopeDoesNotRequestAQueueRebuild() {
        val plan = QueuePolicy.reconcileScope(
            queueMediaIDs = listOf("a", "b"),
            inScopeMediaIDs = setOf("a", "b"),
            currentMediaID = "b",
        )

        assertEquals(1, plan.currentIndex)
        assertFalse(plan.shouldStopPlayback)
        assertFalse(plan.requiresRebuild)
    }
}
