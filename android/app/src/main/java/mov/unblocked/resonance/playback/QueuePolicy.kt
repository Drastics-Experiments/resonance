package mov.unblocked.resonance.playback

import kotlin.random.Random

object QueuePolicy {
    fun nextIndex(size: Int, currentIndex: Int, shuffle: Boolean, random: Random = Random.Default): Int {
        if (size <= 0) return -1
        if (size == 1) return 0
        if (!shuffle) return (currentIndex.coerceAtLeast(0) + 1) % size
        var candidate: Int
        do candidate = random.nextInt(size) while (candidate == currentIndex)
        return candidate
    }

    fun previousIndex(size: Int, currentIndex: Int): Int {
        if (size <= 0) return -1
        return if (currentIndex <= 0) size - 1 else currentIndex - 1
    }
}
