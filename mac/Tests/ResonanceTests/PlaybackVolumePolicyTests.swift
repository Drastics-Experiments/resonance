import Testing
@testable import Resonance

struct PlaybackVolumePolicyTests {
    @Test
    func volumeSliderUsesAClampedPerceptualCurve() {
        #expect(PlaybackVolumePolicy.gain(for: -0.5) == 0)
        #expect(PlaybackVolumePolicy.gain(for: 0.25) == 0.0625)
        #expect(PlaybackVolumePolicy.gain(for: 0.5) == 0.25)
        #expect(PlaybackVolumePolicy.gain(for: 0.75) == 0.5625)
        #expect(PlaybackVolumePolicy.gain(for: 1) == 1)
        #expect(PlaybackVolumePolicy.gain(for: 2) == 1)
        #expect(PlaybackVolumePolicy.gain(for: .nan) == 0)
    }

    @Test
    func crossfadeUsesSpotifyStyleRangeAndProtectsShortTracks() {
        #expect(MacCrossfadePolicy.normalizedSeconds(-2) == 1)
        #expect(MacCrossfadePolicy.normalizedSeconds(30) == 12)
        #expect(MacCrossfadePolicy.effectiveDuration(
            requestedSeconds: 12,
            currentDuration: 4,
            nextDuration: 20
        ) == 2)
        #expect(MacCrossfadePolicy.progress(remaining: 2.5, duration: 5) == 0.5)
    }
}
