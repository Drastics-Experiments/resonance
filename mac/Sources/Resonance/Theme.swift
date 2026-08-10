import SwiftUI

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

    static let appInk = Color(hex: 0xF5F5F7)
    static let appMuted = Color(hex: 0xA1A1AC)
    static let appBackground = Color(hex: 0x020305)
    static let appPanel = Color(hex: 0x07080C)
    static let appSurface = Color(hex: 0x0B0C11)
    static let appSurfaceRaised = Color(hex: 0x12131A)
    static let appLine = Color.white.opacity(0.09)
    static let appAccent = Color(hex: 0x7547FF)
    static let appViolet = Color(hex: 0x6540F5)
}

enum AppGradient {
    static func colors(for style: ArtworkStyle) -> [Color] {
        switch style {
        case .liked, .midnight:
            [Color(hex: 0x3349C9), Color(hex: 0x6857FF), Color(hex: 0xF18CB2)]
        case .electric:
            [Color(hex: 0x263857), Color(hex: 0x95B5D6)]
        case .echoes:
            [Color(hex: 0x5B281E), Color(hex: 0xE76542)]
        case .golden:
            [Color(hex: 0xF49C44), Color(hex: 0xFFD77A)]
        case .weightless:
            [Color(hex: 0x151A29), Color(hex: 0x7895AE)]
        case .falling:
            [Color(hex: 0x42435F), Color(hex: 0xC1A9C6)]
        case .lateNight:
            [Color(hex: 0x26345A), Color(hex: 0x8AC1DB)]
        case .softFocus:
            [Color(hex: 0x715A6D), Color(hex: 0xC0A6C5)]
        case .onRepeat:
            [Color(hex: 0x13233A), Color(hex: 0xCB3877)]
        }
    }
}

struct ArtworkView: View {
    let style: ArtworkStyle
    var symbol: String = "heart.fill"
    var symbolSize: CGFloat = 48
    var cornerRadius: CGFloat = 8
    var glow: Bool = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: AppGradient.colors(for: style),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if glow {
                    RadialGradient(
                        colors: [Color.white.opacity(0.28), .clear],
                        center: UnitPoint(x: 0.48, y: 0.46),
                        startRadius: 0,
                        endRadius: max(30, proxy.size.width * 0.44)
                    )
                }

                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .shadow(color: .white.opacity(glow ? 0.65 : 0.2), radius: glow ? 22 : 5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        }
    }
}

struct PressableScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
