import Foundation
import XCTest
@testable import Resonance

final class ThemeTests: XCTestCase {
    func testThemeIDsLabelsAndDefaultAreStable() {
        XCTAssertEqual(ResonanceTheme.storageKey, "Resonance.appearance.theme.v1")
        XCTAssertEqual(
            ResonanceTheme.allCases.map(\.id),
            ["midnight", "ocean", "forest", "sunset"]
        )
        XCTAssertEqual(
            ResonanceTheme.allCases.map(\.title),
            ["Midnight", "Ocean", "Forest", "Sunset"]
        )
        XCTAssertEqual(ResonanceTheme.midnight.id, ResonanceTheme.midnight.rawValue)
    }

    func testMissingAndUnknownStoredValuesFallBackToMidnight() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ResonanceTheme.stored(in: defaults), .midnight)

        defaults.set("future-theme", forKey: ResonanceTheme.storageKey)
        XCTAssertEqual(ResonanceTheme.stored(in: defaults), .midnight)
    }

    func testThemeStorePersistsADeviceLocalSelection() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ResonanceThemeStore(defaults: defaults)
        XCTAssertEqual(store.selectedTheme, .midnight)

        store.selectedTheme = .ocean

        XCTAssertEqual(
            defaults.string(forKey: ResonanceTheme.storageKey),
            ResonanceTheme.ocean.rawValue
        )
        XCTAssertEqual(ResonanceThemeStore(defaults: defaults).selectedTheme, .ocean)
    }

    func testThemePalettesMatchTheCrossPlatformContract() {
        let actual = ResonanceTheme.allCases.map { theme in
            let palette = theme.palette
            return [
                palette.backgroundHex,
                palette.panelHex,
                palette.surfaceHex,
                palette.raisedSurfaceHex,
                palette.accentHex,
                palette.secondaryHex,
                palette.tertiaryHex,
            ] + palette.gradientStopHexes
        }

        XCTAssertEqual(actual, [
            [0x020305, 0x07080C, 0x0B0C11, 0x12131A, 0x7547FF, 0x6540F5, 0x9B82FF, 0x6540F5, 0x874BFF, 0xB079FF],
            [0x02070D, 0x050D14, 0x07121B, 0x0D1D2A, 0x1769C2, 0x0F5CAA, 0x55B8FF, 0x0F5CAA, 0x218BD6, 0x62C3FF],
            [0x020805, 0x050D09, 0x07120C, 0x0D1D14, 0x198754, 0x126B43, 0x5FD49A, 0x126B43, 0x219C64, 0x69D89E],
            [0x0A0403, 0x100706, 0x150A07, 0x21120E, 0xC45132, 0xA33A53, 0xFF9A62, 0xA33A53, 0xD25B3F, 0xFF9A62],
        ])
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

    func testSettingsUseSemanticPaletteColors() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/Resonance/SidebarView.swift"),
            encoding: .utf8
        )

        for retiredColor in ["Color.appViolet", "Color.appInk", "Color.appMuted", "Color.appLine"] {
            XCTAssertFalse(sidebarSource.contains(retiredColor), "Retired color reference: \(retiredColor)")
        }
        XCTAssertTrue(sidebarSource.contains(".tint(palette.foregroundAccent)"))
        XCTAssertTrue(sidebarSource.contains(".stroke(palette.divider)"))
        XCTAssertTrue(sidebarSource.contains("Text(\"Sign in with Clerk\")"))
        XCTAssertTrue(sidebarSource.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(sidebarSource.contains(".minimumScaleFactor(0.82)"))
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

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "Resonance.ThemeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
