import ClerkKit
import ClerkKitUI
import Foundation
import SwiftUI

@MainActor
final class ResonanceClerkAuthCoordinator {
    static let shared = ResonanceClerkAuthCoordinator()

    private var configuredPublishableKey: String?
    private var configuredTemplate: String?

    private init() {}

    func configure(for client: ResonanceSocialAuthClient) async throws -> Clerk {
        let configuration = try await client.nativeConfiguration()
        let callbackScheme = "resonance"
        let options = Clerk.Options(
            telemetryEnabled: false,
            redirectConfig: .init(
                redirectUrl: "\(callbackScheme)://auth/callback",
                callbackUrlScheme: callbackScheme
            )
        )
        let clerk: Clerk
        if let configuredPublishableKey {
            if configuredPublishableKey == configuration.publishableKey {
                clerk = Clerk.shared
            } else {
                clerk = try await Clerk.reconfigure(
                    publishableKey: configuration.publishableKey,
                    options: options
                )
            }
        } else {
            clerk = Clerk.configure(
                publishableKey: configuration.publishableKey,
                options: options
            )
        }
        configuredPublishableKey = configuration.publishableKey
        configuredTemplate = configuration.tokenTemplate
        return clerk
    }

    func accountSession(
        for client: ResonanceSocialAuthClient,
        forceRefresh: Bool = false
    ) async throws -> ResonanceAccountSession {
        let clerk = try await configure(for: client)
        guard let template = configuredTemplate,
              let token = try await clerk.auth.getToken(.init(
                template: template,
                expirationBuffer: 15,
                skipCache: forceRefresh
              )) else {
            throw ResonanceSocialAuthError.rejected("Finish signing in to continue.")
        }
        return try await client.accountSession(nativeToken: token)
    }

    func signOut() async {
        guard configuredPublishableKey != nil else { return }
        try? await Clerk.shared.auth.signOut()
    }

    var hasActiveSession: Bool {
        configuredPublishableKey != nil && Clerk.shared.session?.status == .active
    }
}

struct ResonanceNativeAuthView: View {
    let serverURL: URL

    @State private var clerk: Clerk?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let clerk {
                AuthView(mode: .signInOrUp, isDismissible: true)
                    .environment(clerk)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Sign-in unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
                .frame(width: 560, height: 620)
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Preparing secure sign-in…")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 560, height: 620)
            }
        }
        .task {
            guard clerk == nil, errorMessage == nil else { return }
            do {
                let client = try ResonanceSocialAuthClient(baseURL: serverURL)
                clerk = try await ResonanceClerkAuthCoordinator.shared.configure(for: client)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
