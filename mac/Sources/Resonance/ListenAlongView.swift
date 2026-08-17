import AppKit
import SwiftUI

enum MacListenAlongCodeInputPolicy {
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

struct MacListenAlongPopover: View {
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var model: PlayerModel
    @State private var joinCode = ""
    @State private var isBusy = false
    @State private var didCopyCode = false
    @State private var copyFeedbackTask: Task<Void, Never>?
    @FocusState private var joinCodeFocused: Bool

    private var canStartRoom: Bool {
        model.currentTrack != nil
            && !model.serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.2.wave.2.fill")
                    .foregroundStyle(palette.foregroundAccent)
                Text("Listen Along")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }

            if let role = model.listenAlongRole {
                sessionBody(for: role)
            } else {
                Button {
                    run {
                        await model.startListenAlongHost()
                    }
                } label: {
                    Label("Start Room", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || !canStartRoom)

                Divider()

                Text("Join a room")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.muted)
                HStack(spacing: 8) {
                    TextField(
                        "Room code",
                        text: Binding(
                            get: { joinCode },
                            set: { joinCode = MacListenAlongCodeInputPolicy.normalized($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($joinCodeFocused)
                    .onSubmit(join)

                    Button("Join", action: join)
                        .buttonStyle(.bordered)
                        .disabled(isBusy || !MacListenAlongCodeInputPolicy.isJoinable(joinCode))
                }
            }

            if let error = model.listenAlongError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if model.listenAlongRole == nil,
                      model.listenAlongStatus != "Not connected" {
                Text(model.listenAlongStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 300)
        .foregroundStyle(palette.ink)
        .background(palette.raisedSurface)
        .onDisappear {
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
            didCopyCode = false
        }
    }

    @ViewBuilder
    private func sessionBody(for role: MacListenAlongRole) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                role == .host ? "Hosting" : "Following host",
                systemImage: role == .host ? "crown.fill" : "headphones"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(palette.muted)

            if let code = model.listenAlongCode {
                HStack {
                    Text(code)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                    Spacer()
                    Button {
                        copyCode(code)
                    } label: {
                        Label(
                            didCopyCode ? "Copied" : "Copy",
                            systemImage: didCopyCode ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.foregroundAccent)
                    .help("Copy room code")
                    .accessibilityLabel(didCopyCode ? "Room code copied" : "Copy room code")
                    .accessibilityValue(didCopyCode ? "Copied" : code)
                }
            }

            Text(model.listenAlongStatus)
                .font(.system(size: 11))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button(role == .host ? "End Room" : "Leave Room") {
                run {
                    await model.leaveListenAlong()
                }
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
    }

    private func join() {
        let normalized = MacListenAlongCodeInputPolicy.normalized(joinCode)
        guard MacListenAlongCodeInputPolicy.isJoinable(normalized) else { return }
        joinCode = normalized
        run {
            await model.joinListenAlong(code: normalized)
            guard model.listenAlongRole != nil else { return }
            joinCode = ""
            joinCodeFocused = false
        }
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task { @MainActor in
            defer { isBusy = false }
            await operation()
        }
    }

    private func copyCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
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
