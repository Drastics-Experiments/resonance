import Foundation

func parseTime(_ value: String) -> TimeInterval? {
    let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count),
          let last = Double(parts.last ?? ""),
          last >= 0, last < 60 || parts.count == 1 else { return nil }
    if parts.count == 1 { return last }
    guard let minutes = Double(parts[parts.count - 2]), minutes >= 0,
          parts.count != 3 || minutes < 60 else { return nil }
    if parts.count == 2 { return minutes * 60 + last }
    guard let hours = Double(parts[0]), hours >= 0 else { return nil }
    return hours * 3_600 + minutes * 60 + last
}

func formatTime(_ value: TimeInterval) -> String {
    let safe = max(value, 0)
    let whole = Int(safe)
    let tenth = Int((safe * 10).rounded()) % 10
    let base = whole >= 3_600
        ? "\(whole / 3_600):\(String(format: "%02d", (whole / 60) % 60)):\(String(format: "%02d", whole % 60))"
        : "\(whole / 60):\(String(format: "%02d", whole % 60))"
    return tenth == 0 ? base : "\(base).\(tenth)"
}
