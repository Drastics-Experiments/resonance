import AppKit
import SwiftUI

struct TransferProgressOverlay: View {
    let title: String
    let detail: String
    let status: String
    let progress: Double?
    let symbol: String
    let color: Color
    let cancel: () -> Void

    private var clampedProgress: Double? {
        progress.map { min(max($0, 0), 1) }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.14), in: Circle())
                .symbolEffect(.pulse)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let clampedProgress {
                        Text("\(Int(clampedProgress * 100))%")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.appMuted)
                            .monospacedDigit()
                    }
                }

                Text(detail.isEmpty ? status : detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)

                if let clampedProgress {
                    ProgressView(value: clampedProgress)
                        .progressViewStyle(.linear)
                        .tint(color)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(color)
                }
            }

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.appMuted)
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.045), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel \(title.lowercased())")
            .accessibilityLabel("Cancel \(title.lowercased())")
        }
        .padding(15)
        .frame(width: 390)
        .background(Color.appSurfaceRaised.opacity(0.98), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.white.opacity(0.055))
        }
        .shadow(color: .black.opacity(0.34), radius: 22, y: 10)
        .accessibilityElement(children: .contain)
    }
}

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

private struct AppKitHoverTrackingArea: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onHover = onHover
    }

    static func dismantleNSView(_ nsView: HoverTrackingNSView, coordinator: ()) {
        nsView.onHover = nil
    }
}

private final class HoverTrackingNSView: NSView {
    var onHover: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct HoverCircleIconSurface: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 34
    var symbolSize: CGFloat = 13
    var background: Color = .clear
    var hoverBackground: Color? = nil
    var isActive = false
    var showsActiveBackground = true
    var foreground: Color = Color(hex: 0xAEB5C4)
    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(isActive ? Color.white : foreground)
            .frame(width: size, height: size)
            .background(circleBackground)
            .clipShape(Circle())
            .contentShape(Circle())
            .background {
                AppKitHoverTrackingArea { isHovering = $0 }
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .accessibilityLabel(label)
    }

    private var circleBackground: Color {
        if isHovering, let hoverBackground {
            return hoverBackground
        }
        if isActive && showsActiveBackground {
            return Color.white.opacity(0.10)
        }
        return background
    }
}

struct CircleIconButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 34
    var symbolSize: CGFloat = 13
    var background: Color = .clear
    var hoverBackground: Color? = nil
    var isActive: Bool = false
    var showsActiveBackground = true
    var foreground: Color = Color(hex: 0xAEB5C4)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HoverCircleIconSurface(
                systemImage: systemImage,
                label: label,
                size: size,
                symbolSize: symbolSize,
                background: background,
                hoverBackground: hoverBackground,
                isActive: isActive,
                showsActiveBackground: showsActiveBackground,
                foreground: foreground
            )
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
    var size: CGFloat? = nil

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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        }
    }
}

struct ClickableProgress: View {
    let progress: Double
    var activeColor: Color = .appAccent
    var height: CGFloat = 3
    var onSeek: (Double) -> Void
    @State private var isHovering = false

    private let hitSlop: CGFloat = 7
    private let hoverThumbSize: CGFloat = 8
    private var clampedProgress: Double { min(max(progress, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            let thumbOffset = min(
                max((proxy.size.width * clampedProgress) - (hoverThumbSize / 2), 0),
                max(proxy.size.width - hoverThumbSize, 0)
            )

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: height)

                Capsule()
                    .fill(activeColor)
                    .frame(width: proxy.size.width * clampedProgress, height: height)
            }
            .frame(height: height)
            .overlay(alignment: .leading) {
                if isHovering {
                    Circle()
                        .fill(activeColor)
                        .frame(width: hoverThumbSize, height: hoverThumbSize)
                        .shadow(color: activeColor.opacity(0.35), radius: 3)
                        .offset(x: thumbOffset)
                        .transition(.scale(scale: 0.65).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .padding(.vertical, hitSlop)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard proxy.size.width > 0 else { return }
                        onSeek(min(max(value.location.x / proxy.size.width, 0), 1))
                    }
            )
            .padding(.vertical, -hitSlop)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int((clampedProgress * 100).rounded())) percent")
        .accessibilityHint("Adjusts the playback position")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            switch direction {
            case .increment:
                onSeek(min(clampedProgress + step, 1))
            case .decrement:
                onSeek(max(clampedProgress - step, 0))
            @unknown default:
                break
            }
        }
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
        .foregroundStyle(Color.appAccent)
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
