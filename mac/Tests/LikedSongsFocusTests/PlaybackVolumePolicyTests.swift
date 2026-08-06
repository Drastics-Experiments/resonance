import Testing
@testable import LikedSongsFocus

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
}
