import Foundation
import SwiftUI

enum ResonanceTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    static let storageKey = "Resonance.appearance.theme.v1"

    case midnight
    case ocean
    case forest
    case sunset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .midnight: "Midnight"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .sunset: "Sunset"
        }
    }

    var palette: ResonanceThemePalette {
        switch self {
        case .midnight:
            ResonanceThemePalette(
                backgroundHex: 0x020305,
                panelHex: 0x07080C,
                surfaceHex: 0x0B0C11,
                raisedSurfaceHex: 0x12131A,
                accentHex: 0x7547FF,
                secondaryHex: 0x6540F5,
                tertiaryHex: 0x9B82FF,
                gradientStopHexes: [0x6540F5, 0x874BFF, 0xB079FF]
            )
        case .ocean:
            ResonanceThemePalette(
                backgroundHex: 0x02070D,
                panelHex: 0x050D14,
                surfaceHex: 0x07121B,
                raisedSurfaceHex: 0x0D1D2A,
                accentHex: 0x1769C2,
                secondaryHex: 0x0F5CAA,
                tertiaryHex: 0x55B8FF,
                gradientStopHexes: [0x0F5CAA, 0x218BD6, 0x62C3FF]
            )
        case .forest:
            ResonanceThemePalette(
                backgroundHex: 0x020805,
                panelHex: 0x050D09,
                surfaceHex: 0x07120C,
                raisedSurfaceHex: 0x0D1D14,
                accentHex: 0x198754,
                secondaryHex: 0x126B43,
                tertiaryHex: 0x5FD49A,
                gradientStopHexes: [0x126B43, 0x219C64, 0x69D89E]
            )
        case .sunset:
            ResonanceThemePalette(
                backgroundHex: 0x0A0403,
                panelHex: 0x100706,
                surfaceHex: 0x150A07,
                raisedSurfaceHex: 0x21120E,
                accentHex: 0xC45132,
                secondaryHex: 0xA33A53,
                tertiaryHex: 0xFF9A62,
                gradientStopHexes: [0xA33A53, 0xD25B3F, 0xFF9A62]
            )
        }
    }

    static func stored(in defaults: UserDefaults) -> ResonanceTheme {
        guard let rawValue = defaults.string(forKey: storageKey) else { return .midnight }
        return ResonanceTheme(rawValue: rawValue) ?? .midnight
    }
}

struct ResonanceThemePalette: Equatable, Sendable {
    let backgroundHex: UInt32
    let panelHex: UInt32
    let surfaceHex: UInt32
    let raisedSurfaceHex: UInt32
    let accentHex: UInt32
    let secondaryHex: UInt32
    let tertiaryHex: UInt32
    let gradientStopHexes: [UInt32]

    var background: Color { Color(hex: backgroundHex) }
    var surface: Color { Color(hex: surfaceHex) }
    var raisedSurface: Color { Color(hex: raisedSurfaceHex) }
    var accent: Color { Color(hex: accentHex) }
    var secondary: Color { Color(hex: secondaryHex) }
    var tertiary: Color { Color(hex: tertiaryHex) }
    var foregroundAccent: Color { tertiary }
    var gradientStops: [Color] { gradientStopHexes.map { Color(hex: $0) } }
    var ink: Color { Color(hex: 0xF5F5F7) }
    var divider: Color { Color.white.opacity(0.09) }
    var serverActionForeground: Color { Color(hex: 0xB0ADBF) }
}

final class ResonanceThemeStore: ObservableObject {
    @Published var selectedTheme: ResonanceTheme {
        didSet {
            guard selectedTheme != oldValue else { return }
            defaults.set(selectedTheme.rawValue, forKey: ResonanceTheme.storageKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedTheme = ResonanceTheme.stored(in: defaults)
    }

    var palette: ResonanceThemePalette { selectedTheme.palette }
}

private struct ResonanceThemePaletteKey: EnvironmentKey {
    static let defaultValue = ResonanceTheme.midnight.palette
}

extension EnvironmentValues {
    var resonancePalette: ResonanceThemePalette {
        get { self[ResonanceThemePaletteKey.self] }
        set { self[ResonanceThemePaletteKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}
