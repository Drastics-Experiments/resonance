import AppKit
import SwiftUI

struct TrafficLightDots: View {
    var body: some View {
        HStack(spacing: 8) {
            trafficButton(color: Color(hex: 0xFF6B66), label: "Close") {
                NSApp.keyWindow?.performClose(nil)
            }
            trafficButton(color: Color(hex: 0xF6C851), label: "Minimize") {
                NSApp.keyWindow?.miniaturize(nil)
            }
            trafficButton(color: Color(hex: 0x61D889), label: "Zoom") {
                NSApp.keyWindow?.zoom(nil)
            }
        }
        .frame(width: 52, height: 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trafficButton(color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct CircleIconButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 34
    var symbolSize: CGFloat = 13
    var background: Color = .clear
    var isActive: Bool = false
    var foreground: Color = Color(hex: 0xAEB5C4)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : foreground)
                .frame(width: size, height: size)
                .background(isActive ? Color.white.opacity(0.10) : background)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressableScaleStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

struct MiniArtwork: View {
    let style: ArtworkStyle
    var symbol: String = "music.note"
    var size: CGFloat = 39
    var cornerRadius: CGFloat = 6

    var body: some View {
        ArtworkView(
            style: style,
            symbol: symbol,
            symbolSize: max(9, size * 0.28),
            cornerRadius: cornerRadius,
            glow: false
        )
        .frame(width: size, height: size)
    }
}

struct TrackArtworkView: View {
    let track: Track
    var symbol: String = "music.note"
    var symbolSize: CGFloat = 36
    var cornerRadius: CGFloat = 8
    var glow: Bool = false

    var body: some View {
        Group {
            if let artworkData = track.artworkData, let image = NSImage(data: artworkData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ArtworkView(
                    style: track.artwork,
                    symbol: symbol,
                    symbolSize: symbolSize,
                    cornerRadius: cornerRadius,
                    glow: glow
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        }
    }
}

struct ClickableProgress: View {
    let progress: Double
    var activeColor: Color = .appCoral
    var height: CGFloat = 3
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule()
                    .fill(activeColor)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard proxy.size.width > 0 else { return }
                        onSeek(min(max(value.location.x / proxy.size.width, 0), 1))
                    }
            )
        }
        .frame(height: height)
    }
}

struct EqualizerGlyph: View {
    var isAnimating: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            RoundedRectangle(cornerRadius: 1).frame(width: 2, height: isAnimating ? 8 : 4)
            RoundedRectangle(cornerRadius: 1).frame(width: 2, height: isAnimating ? 5 : 4)
            RoundedRectangle(cornerRadius: 1).frame(width: 2, height: isAnimating ? 10 : 4)
        }
        .foregroundStyle(Color.appCoral)
        .frame(width: 14, height: 12)
        .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true), value: isAnimating)
    }
}

struct HoverSurface<Content: View>: View {
    var cornerRadius: CGFloat = 8
    var selected: Bool = false
    @ViewBuilder var content: () -> Content
    @State private var isHovering = false

    var body: some View {
        content()
            .background((selected || isHovering) ? Color.white.opacity(0.055) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

struct SoftDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.appLine)
            .frame(height: 1)
    }
}
