package mov.unblocked.resonance.playback

/** Pure normalization for clip metadata before it is handed to Media3. */
object ClipBoundaryPolicy {
    const val MIN_CLIP_DURATION_MS = 250L

    /**
     * Returns an exact Media3 end boundary, or null when the range is unset/invalid.
     *
     * A one-millisecond default historically represented an unknown track duration. Treating it
     * as a real boundary makes an otherwise playable stream end immediately, so it is deliberately
     * rejected here together with every range shorter than the editor's minimum clip duration.
     */
    fun exactEndMs(startMs: Long, endMs: Long): Long? {
        val normalizedStart = startMs.coerceAtLeast(0L)
        return endMs.takeIf { it >= normalizedStart + MIN_CLIP_DURATION_MS }
    }
}
