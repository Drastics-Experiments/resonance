import Foundation
import XCTest
@testable import Resonance

final class ThemeTests: XCTestCase {
    func testThemeCatalogMatchesTheSharedAppleContract() {
        XCTAssertEqual(ResonanceTheme.storageKey, "Resonance.appearance.theme.v1")
        XCTAssertEqual(
            ResonanceTheme.allCases.map(\.id),
            ["midnight", "ocean", "forest", "sunset"]
        )
        XCTAssertEqual(
            ResonanceTheme.allCases.map(\.title),
            ["Midnight", "Ocean", "Forest", "Sunset"]
        )

        let palettes = ResonanceTheme.allCases.map { theme in
            let palette = theme.palette
            return [
                palette.backgroundHex,
                palette.panelHex,
                palette.surfaceHex,
                palette.raisedSurfaceHex,
                palette.accentHex,
                palette.secondaryHex,
                palette.tertiaryHex,
            ]
        }
        XCTAssertEqual(palettes, [
            [0x020305, 0x07080C, 0x0B0C11, 0x12131A, 0x7547FF, 0x6540F5, 0x9B82FF],
            [0x02070D, 0x050D14, 0x07121B, 0x0D1D2A, 0x1769C2, 0x0F5CAA, 0x55B8FF],
            [0x020805, 0x050D09, 0x07120C, 0x0D1D14, 0x198754, 0x126B43, 0x5FD49A],
            [0x0A0403, 0x100706, 0x150A07, 0x21120E, 0xC45132, 0xA33A53, 0xFF9A62],
        ])
    }

    func testThemePersistenceDefaultsAndToleratesUnknownValues() throws {
        let suiteName = "Resonance.MobileThemeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertEqual(ResonanceTheme.stored(in: defaults), .midnight)
        defaults.set("future-theme", forKey: ResonanceTheme.storageKey)
        XCTAssertEqual(ResonanceTheme.stored(in: defaults), .midnight)

        let store = ResonanceThemeStore(defaults: defaults)
        store.selectedTheme = .sunset
        XCTAssertEqual(defaults.string(forKey: ResonanceTheme.storageKey), "sunset")
        XCTAssertEqual(ResonanceThemeStore(defaults: defaults).selectedTheme, .sunset)
    }

    func testThemeForegroundAndContainerContrast() {
        for theme in ResonanceTheme.allCases {
            let palette = theme.palette
            for background in [
                palette.backgroundHex,
                palette.panelHex,
                palette.surfaceHex,
                palette.raisedSurfaceHex,
            ] {
                XCTAssertGreaterThanOrEqual(
                    contrastRatio(palette.tertiaryHex, background),
                    4.5,
                    "\(theme.title) foreground accent must remain readable"
                )
            }
            XCTAssertGreaterThanOrEqual(contrastRatio(0xFFFFFF, palette.accentHex), 4.5)
            XCTAssertGreaterThanOrEqual(contrastRatio(0xFFFFFF, palette.secondaryHex), 4.5)
        }
    }

    private func contrastRatio(_ first: UInt32, _ second: UInt32) -> Double {
        let brighter = max(relativeLuminance(first), relativeLuminance(second))
        let darker = min(relativeLuminance(first), relativeLuminance(second))
        return (brighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ value: UInt32) -> Double {
        let components = [
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255,
        ].map { component in
            if component <= 0.04045 {
                return component / 12.92
            }
            return pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
    }
}
