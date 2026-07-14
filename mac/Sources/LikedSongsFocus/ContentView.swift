import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: PlayerModel
    @EnvironmentObject private var updateManager: UpdateManager

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

                PlayerBarView(compact: width < 980)
                    .frame(height: 83)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if model.isSyncingServer && !model.isRefreshingServerCatalog {
                        ServerTransferOverlay(
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
                        ServerTransferOverlay(
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
                }
                .padding(.bottom, 100)
                .animation(.easeInOut(duration: 0.2), value: model.isSyncingServer)
                .animation(.easeInOut(duration: 0.2), value: model.isRefreshingServerCatalog)
                .animation(.easeInOut(duration: 0.2), value: model.isUploadingServer)
            }
        }
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

private struct ServerTransferOverlay: View {
    let title: String
    let detail: String
    let status: String
    let progress: Double
    let symbol: String
    let color: Color
    let cancel: () -> Void

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
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
                    Text("\(Int(clampedProgress * 100))%")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.appMuted)
                        .monospacedDigit()
                }

                Text(detail.isEmpty ? status : detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)

                ProgressView(value: clampedProgress)
                    .progressViewStyle(.linear)
                    .tint(color)
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
