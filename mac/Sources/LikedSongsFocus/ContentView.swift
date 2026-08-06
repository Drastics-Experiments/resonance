import SwiftUI

enum MacUpdateAlertState {
    static func visibleUpdate(
        available: MacUpdateIdentity?,
        dismissed: MacUpdateIdentity?
    ) -> MacUpdateIdentity? {
        guard let available, available != dismissed else { return nil }
        return available
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: PlayerModel
    @EnvironmentObject private var localImportModel: MacLocalImportViewModel
    @EnvironmentObject private var updateManager: UpdateManager
    @State private var dismissedUpdateAlert: MacUpdateIdentity?
    @State private var isNowPlayingPresented = false

    private var updateAlert: MacUpdateIdentity? {
        MacUpdateAlertState.visibleUpdate(
            available: updateManager.availableUpdate,
            dismissed: dismissedUpdateAlert
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let showSidebar = width >= 860
            let sidebarWidth: CGFloat = width >= 1180 ? 292 : 224

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if showSidebar {
                        SidebarView()
                            .frame(width: sidebarWidth)

                        Rectangle()
                            .fill(Color.appLine)
                            .frame(width: 1)
                    }

                    MainContentView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                Rectangle()
                    .fill(Color.appLine)
                    .frame(height: 1)

                PlayerBarView(
                    compact: width < 980,
                    onOpenNowPlaying: { isNowPlayingPresented = true }
                )
                    .frame(height: 83)
            }
            .accessibilityHidden(isNowPlayingPresented)
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if model.isSyncingServer && !model.isRefreshingServerCatalog {
                        TransferProgressOverlay(
                            title: "Downloading",
                            detail: model.downloadCurrentFile,
                            status: model.downloadStatus,
                            progress: model.downloadProgress,
                            symbol: "arrow.down.to.line",
                            color: Color.appViolet,
                            cancel: model.cancelServerDownload
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if model.isUploadingServer {
                        TransferProgressOverlay(
                            title: "Uploading",
                            detail: model.uploadCurrentFile,
                            status: model.uploadStatus,
                            progress: model.uploadProgress,
                            symbol: "arrow.up.to.line",
                            color: Color.appAccent,
                            cancel: model.cancelServerUpload
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if localImportModel.showsTransferPopup {
                        TransferProgressOverlay(
                            title: localImportModel.transferTitle,
                            detail: localImportModel.transferDetail,
                            status: localImportModel.transferStatus,
                            progress: localImportModel.transferProgress,
                            symbol: localImportModel.stage == .syncing
                                ? "arrow.up.to.line"
                                : "arrow.down.to.line",
                            color: localImportModel.stage == .syncing
                                ? Color.appAccent
                                : Color.appViolet,
                            cancel: localImportModel.cancel
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if localImportModel.showsFailurePopup, let error = localImportModel.error {
                        TransferResultOverlay(
                            title: localImportModel.failurePopupTitle,
                            detail: error.message,
                            symbol: "exclamationmark.triangle.fill",
                            color: Color.appAccent,
                            dismiss: localImportModel.reset
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.bottom, 100)
                .animation(.easeInOut(duration: 0.2), value: model.isSyncingServer)
                .animation(.easeInOut(duration: 0.2), value: model.isRefreshingServerCatalog)
                .animation(.easeInOut(duration: 0.2), value: model.isUploadingServer)
                .animation(.easeInOut(duration: 0.2), value: localImportModel.showsTransferPopup)
                .animation(.easeInOut(duration: 0.2), value: localImportModel.showsFailurePopup)
            }
            .overlay(alignment: .topTrailing) {
                if let update = updateAlert {
                    UpdateAvailableAlert(
                        version: update.version,
                        isBusy: updateManager.isBusy,
                        canInstall: updateManager.canInstall,
                        onPrimaryAction: {
                            if updateManager.canInstall {
                                updateManager.installAndRestart()
                            } else {
                                Task { await updateManager.downloadAndInstall() }
                            }
                        },
                        onDismiss: { dismissedUpdateAlert = update }
                    )
                    .padding(.top, 94)
                    .padding(.trailing, 18)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.22), value: updateAlert)
            .overlay {
                if isNowPlayingPresented {
                    NowPlayingView(onDismiss: { isNowPlayingPresented = false })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(10)
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.9), value: isNowPlayingPresented)
        }
        .environmentObject(model.playbackPositionState)
        .background {
            ZStack {
                Color.appBackground
                RadialGradient(
                    colors: [Color.appViolet.opacity(0.14), .clear],
                    center: UnitPoint(x: 0.72, y: 0.05),
                    startRadius: 10,
                    endRadius: 520
                )
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(Color.appInk)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.container, edges: .top)
        .task { await updateManager.automaticCheck() }
    }
}

private struct UpdateAvailableAlert: View {
    let version: String
    let isBusy: Bool
    let canInstall: Bool
    let onPrimaryAction: () -> Void
    let onDismiss: () -> Void

    @ViewBuilder
    var body: some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            alertContent
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .shadow(color: Color.black.opacity(0.32), radius: 18, y: 8)
        } else {
            fallbackAlert
        }
#else
        fallbackAlert
#endif
    }

    private var alertContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 38, height: 38)
                .background(Color.appAccent.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text("Update Available")
                    .font(.system(size: 13, weight: .semibold))

                Text(canInstall
                    ? "Resonance \(version) is ready to install."
                    : "Resonance \(version) is available.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appMuted)

                Button(canInstall ? "Restart to Install" : "Update and Restart", action: onPrimaryAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color.appAccent)
                    .disabled(isBusy)
            }

            Spacer(minLength: 6)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.appMuted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss update alert")
        }
        .padding(14)
        .frame(width: 300)
    }

    private var fallbackAlert: some View {
        alertContent
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(Color.appPanel.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10))
        }
        .shadow(color: Color.black.opacity(0.32), radius: 18, y: 8)
    }
}
