import Foundation

enum PlaybackVolumePolicy {
    static func gain(for sliderValue: Double) -> Float {
        guard sliderValue.isFinite else { return 0 }
        let normalized = min(max(sliderValue, 0), 1)
        return Float(normalized * normalized)
    }
}
