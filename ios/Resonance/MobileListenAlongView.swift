import SwiftUI
import UIKit

enum MobileListenAlongCodeInputPolicy {
    static let maximumLength = 32

    static func normalized(_ value: String) -> String {
        let filtered = value
            .uppercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return String(filtered.prefix(maximumLength))
    }

    static func isJoinable(_ value: String) -> Bool {
        let normalized = normalized(value)
        return normalized.count >= 5 && normalized.contains("-")
    }
}

struct MobileListenAlongCard: View {
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var library: MusicLibrary
    @EnvironmentObject private var listenAlong: MobileListenAlongController
    @State private var code = ""
    @State private var didCopyCode = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @FocusState private var codeFieldFocused: Bool

    private var canStart: Bool {
        library.currentTrack != nil
            && library.listenAlongCurrentSourceURL != nil
            && !library.serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canJoin: Bool {
        MobileListenAlongCodeInputPolicy.isJoinable(code) && !listenAlong.isWorking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: listenAlong.room == nil ? "shareplay" : "person.2.wave.2")
                    .font(.headline)
                    .foregroundStyle(palette.accent)
                if let count = listenAlong.participantCount {
                    Text(count, format: .number)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(palette.accent)
                        .accessibilityLabel("\(count) people connected")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if listenAlong.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let room = listenAlong.room {
                HStack(spacing: 8) {
                    Text(room.code)
                        .font(.headline.monospaced().weight(.bold))
                        .tracking(1.4)
                    Spacer()
                    Button {
                        copyCode(room.code)
                    } label: {
                        Label(
                            didCopyCode ? "Copied" : "Copy",
                            systemImage: didCopyCode ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(palette.accent)
                    .accessibilityLabel(didCopyCode ? "Room code copied" : "Copy room code")
                    .accessibilityValue(didCopyCode ? "Copied" : room.code)
                    Button(room.role == .host ? "End" : "Leave", role: room.role == .host ? .destructive : nil) {
                        if room.role == .host {
                            Task { await listenAlong.end() }
                        } else {
                            listenAlong.leave()
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(room.role == .host ? .red : palette.accent)
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        Task { await listenAlong.startHosting() }
                    } label: {
                        Label("Start", systemImage: "play.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .disabled(!canStart || listenAlong.isWorking)

                    TextField(
                        "Room code",
                        text: Binding(
                            get: { code },
                            set: { code = MobileListenAlongCodeInputPolicy.normalized($0) }
                        )
                    )
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .textContentType(.oneTimeCode)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.join)
                    .focused($codeFieldFocused)
                    .onSubmit(join)

                    Button("Join", action: join)
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .disabled(!canJoin)
                }
            }

            if let message = listenAlong.message, !message.isEmpty {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(palette.raisedSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.accent.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
            didCopyCode = false
        }
    }

    private var title: String {
        guard let room = listenAlong.room else { return "Listen Along" }
        return room.role == .host ? "Hosting Listen Along" : "Listening Along"
    }

    private var detail: String {
        if let room = listenAlong.room {
            return room.role == .host
                ? "Share code \(room.code) so friends can follow your playback."
                : "The host controls playback for room \(room.code)."
        }
        return canStart
            ? "Start a room or enter a code to join."
            : "Play a track with a shareable source link to start a room."
    }

    private func join() {
        let normalized = MobileListenAlongCodeInputPolicy.normalized(code)
        guard MobileListenAlongCodeInputPolicy.isJoinable(normalized), !listenAlong.isWorking else { return }
        code = normalized
        Task { @MainActor in
            await listenAlong.oin(code: normalized)
            guard listenAlong.room != nil else { return }
            code = ""
            codeFieldFocused = false
        }
    }

    private func copyCode(_ code: String) {
        UIPasteboard.general.string = code
        didCopyCode = true

        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            didCopyCode = false
            copyFeedbackTask = nil
        }
    }
}
