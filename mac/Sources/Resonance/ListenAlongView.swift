import AppKit
import SwiftUI

struct MacListenAlongPopover: View {
    @Environment(\.resonancePalette) private var palette
    @EnvironmentObject private var model: PlayerModel
    @State private var joinCode = ""
    @State private var isBusy = false
    @State private var didCopyCode = false

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
                    Label("Start as Host", systemImage: "play.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || model.currentTrack == nil || model.serverToken.isEmpty)

                Divider()

                Text("Join a friend")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.muted)
                HStack(spacing: 8) {
                    TextField("XXXX-XXXX", text: $joinCode)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            run {
                                await model.joinListenAlong(code: joinCode)
                            }
                        }
                    Button("Join") {
                        run {
                            await model.joinListenAlong(code: joinCode)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || joinCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let error = model.listenAlongError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.listenAlongRole == nil,
                      model.listenAlongStatus != "Not connected" {
                Text(model.listenAlongStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.muted)
            }
        }
        .padding(16)
        .frame(width: 300)
        .foregroundStyle(palette.ink)
        .background(palette.raisedSurface)
    }

    @ViewBuilder
    private func sessionBody(for role: MacListenAlongRole) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                role == .host ? "You are hosting" : "Following the host",
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
                    .help("Copy Listen Along code")
                    .accessibilityLabel(didCopyCode ? "Listen Along code copied" : "Copy Listen Along code")
                    .accessibilityValue(didCopyCode ? "Copied" : code)
                }
            }

            Text(model.listenAlongStatus)
                .font(.system(size: 10))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            Button(role == .host ? "End Session" : "Leave Session") {
                run {
                    await model.leaveListenAlong()
                }
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
        }
    }

    private func run(_ operation: @escaping () async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            await operation()
            isBusy = false
        }
    }

    private func copyCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopyCode = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            didCopyCode = false
        }
    }
}
