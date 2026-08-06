package mov.unblocked.resonance.playback

object PlaybackVolumePolicy {
    fun gainForSlider(sliderValue: Float): Float {
        if (!sliderValue.isFinite()) return 0f
        val normalized = sliderValue.coerceIn(0f, 1f)
        return normalized * normalized
    }
}
