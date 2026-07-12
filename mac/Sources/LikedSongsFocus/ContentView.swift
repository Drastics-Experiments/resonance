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
        }
        .background {
            ZStack {
                Color.appBackground
                RadialGradient(
                    colors: [Color(hex: 0x261A40).opacity(0.72), .clear],
                    center: UnitPoint(x: 0.65, y: 0.08),
                    startRadius: 10,
                    endRadius: 460
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
