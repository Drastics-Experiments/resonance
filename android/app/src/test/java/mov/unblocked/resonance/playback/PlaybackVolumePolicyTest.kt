package mov.unblocked.resonance.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackVolumePolicyTest {
    @Test fun volumeSliderUsesAClampedPerceptualCurve() {
        assertEquals(0f, PlaybackVolumePolicy.gainForSlider(-.5f), 0f)
        assertEquals(.0625f, PlaybackVolumePolicy.gainForSlider(.25f), 0f)
        assertEquals(.25f, PlaybackVolumePolicy.gainForSlider(.5f), 0f)
        assertEquals(.5625f, PlaybackVolumePolicy.gainForSlider(.75f), 0f)
        assertEquals(1f, PlaybackVolumePolicy.gainForSlider(1f), 0f)
        assertEquals(1f, PlaybackVolumePolicy.gainForSlider(2f), 0f)
        assertEquals(0f, PlaybackVolumePolicy.gainForSlider(Float.NaN), 0f)
    }
}
