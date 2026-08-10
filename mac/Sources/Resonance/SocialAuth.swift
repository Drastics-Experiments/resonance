import AuthenticationServices
import CryptoKit
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private let resonanceLegacyProductionHost = "music.unblocked.mov"
private let resonanceProductionHost = "resonance-core.blithe-haven-9710.chatgpt.site"

enum ResonanceEmailPrivacy {
    static let censoredAddress = "••••••@••••••.•••"

    static func displayedAddress(_ email: String, isRevealed: Bool) -> String {
        isRevealed ? email : censoredAddress
    }

    static func safeDisplayName(_ value: String?, email: String?) -> String {
        let candidate = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !candidate.isEmpty, !looksLikeEmail(candidate),
              candidate.caseInsensitiveCompare(email ?? "") != .orderedSame else {
            return "Clerk account"
        }
        return candidate
    }

    private static func looksLikeEmail(_ value: String) -> Bool {
        guard let at = value.firstIndex(of: "@"), at != value.startIndex else { return false }
        return value[value.index(after: at)...].contains(".")
    }
}

enum ResonanceAccountScopePolicy {
    static func resolvedProfileID(
        accountID: String?,
        serverProfileID: String?,
        requestedLegacyProfileID: String?
    ) -> String? {
        let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !accountID.isEmpty else { return nil }
        let serverProfileID = serverProfileID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !serverProfileID.isEmpty {
            return serverProfileID == accountID ? accountID : nil
        }
        let legacyProfileID = requestedLegacyProfileID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return legacyProfileID.isEmpty ? "default" : legacyProfileID
    }
}

enum ResonanceSocialAuthProvider: String, CaseIterable, Identifiable {
    case clerk

    var id: String { rawValue }
    var title: String { "Clerk" }
}

struct ResonanceAccountSession: Codable, Equatable {
    static let nativeRefreshMarker = "clerk-native-session"

    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let email: String
    let role: String
    let baseURL: URL
    let accountID: String?
    let profileID: String?
    let displayName: String?
    let imageURL: URL?
    var migratedProfileID: String? = nil

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, expiresAt, email, role, baseURL
        case accountID, profileID, displayName, imageURL
    }

    var isAdmin: Bool { role == "admin" }
    var usesNativeClerkSession: Bool { refreshToken == Self.nativeRefreshMarker }
    var usesLegacyProductionServer: Bool {
        baseURL.scheme?.lowercased() == "https"
            && baseURL.host?.lowercased() == resonanceLegacyProductionHost
            && (baseURL.port == nil || baseURL.port == 443)
    }
    var profileDisplayName: String {
        ResonanceEmailPrivacy.safeDisplayName(displayName, email: email)
    }
}

struct ResonanceNativeAuthConfiguration: Equatable {
    let publishableKey: String
    let tokenTemplate: String
}

enum ResonanceSocialAuthError: LocalizedError {
    case invalidConfiguration
    case invalidCallback
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The server returned an invalid account sign-in configuration."
        case .invalidCallback: "The account sign-in callback was invalid or expired."
        case .rejected(let message): message
        }
    }
}

private struct ResonanceAuthConfigurationPayload: Decodable {
    let version: Int
    let issuer: URL
    let publishableKey: String?
    let tokenTemplate: String?
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let userEndpoint: URL
    let logoutEndpoint: URL
    let clientID: String
    let scope: String
    let redirectURI: String
    let providers: [String]

    enum CodingKeys: String, CodingKey {
        case version, issuer, scope, providers
        case publishableKey = "publishable_key"
        case tokenTemplate = "token_template"
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case userEndpoint = "user_endpoint"
        case logoutEndpoint = "logout_endpoint"
        case clientID = "client_id"
        case redirectURI = "redirect_uri"
    }
}

private struct ResonanceAuthTokenPayload: Decodable {
    let idToken: String?
    let refreshToken: String?
    let expiresIn: TimeInterval?
    let error: String?
    let errorDescription: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case error, message = "msg"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case errorDescription = "error_description"
    }
}

private struct ResonanceAccountPayload: Decodable {
    let id: String?
    let email: String?
    let role: String?
    let profileID: String?
    let migratedProfileID: String?
    let displayName: String?
    let imageURL: URL?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, email, role, error
        case profileID = "profile_id"
        case migratedProfileID = "migrated_profile_id"
        case displayName = "display_name"
        case imageURL = "image_url"
    }
}

private struct ResonanceAuthConfiguration {
    let issuer: URL
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let logoutEndpoint: URL
    let clientID: String
    let scope: String
    let providers: Set<String>
    let native: ResonanceNativeAuthConfiguration?
}

struct ResonanceSocialAuthClient {
    static let callbackURL = "resonance://auth/callback"
    private static let supportedProviders = Set(ResonanceSocialAuthProvider.allCases.map(\.rawValue))

    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) throws {
        guard let origin = Self.httpsOrigin(baseURL) else { throw ResonanceSocialAuthError.invalidConfiguration }
        self.baseURL = origin
        self.session = session
    }

    func signIn(
        with provider: ResonanceSocialAuthProvider,
        migrationProfileID: String? = nil
    ) async throws -> ResonanceAccountSession {
        let configuration = try await configuration()
        guard configuration.providers.contains(provider.rawValue) else {
            throw ResonanceSocialAuthError.rejected("This sign-in provider is not enabled by the server.")
        }
        let verifier = try Self.randomToken(byteCount: 48)
        let state = try Self.randomToken(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)
        let existingQueryItems = components?.queryItems ?? []
        components?.queryItems = existingQueryItems + [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.callbackURL),
            URLQueryItem(name: "scope", value: configuration.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let destination = components?.url else { throw ResonanceSocialAuthError.invalidConfiguration }
        let callback = try await ResonanceSocialAuthPresenter().authenticate(destination)
        guard let callbackComponents = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              callback.scheme == "resonance", callback.host == "auth", callback.path == "/callback" else {
            throw ResonanceSocialAuthError.invalidCallback
        }
        let values = Dictionary(uniqueKeysWithValues: (callbackComponents.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard values["state"] == state else { throw ResonanceSocialAuthError.invalidCallback }
        if let providerError = values["error_description"] ?? values["error"], !providerError.isEmpty {
            throw ResonanceSocialAuthError.rejected(providerError)
        }
        guard let code = values["code"], !code.isEmpty else { throw ResonanceSocialAuthError.invalidCallback }
        let token = try await token(
            configuration: configuration,
            body: [
                "grant_type": "authorization_code",
                "client_id": configuration.clientID,
                "redirect_uri": Self.callbackURL,
                "code": code,
                "code_verifier": verifier,
            ]
        )
        return try await authorizedSession(token, migrationProfileID: migrationProfileID)
    }

    func nativeConfiguration() async throws -> ResonanceNativeAuthConfiguration {
        guard let native = try await configuration().native else {
            throw ResonanceSocialAuthError.rejected("This Resonance server has not enabled native account sign-in.")
        }
        return native
    }

    func accountSession(
        nativeToken: String,
        migrationProfileID: String? = nil
    ) async throws -> ResonanceAccountSession {
        let expiration = try Self.jwtExpiration(nativeToken)
        let account = try await account(accessToken: nativeToken, migrationProfileID: migrationProfileID)
        let profileID = ResonanceAccountScopePolicy.resolvedProfileID(
            accountID: account.id,
            serverProfileID: account.profileID,
            requestedLegacyProfileID: migrationProfileID
        )
        let displayName = try account.displayName.map { try Self.bounded($0) }
        guard let email = account.email?.lowercased(), !email.isEmpty,
              let role = account.role, role == "member" || role == "admin",
              let accountID = account.id, !accountID.isEmpty,
              let profileID else {
            throw ResonanceSocialAuthError.rejected(account.error ?? "This account could not access this Resonance server.")
        }
        return ResonanceAccountSession(
            accessToken: try Self.bounded(nativeToken),
            refreshToken: ResonanceAccountSession.nativeRefreshMarker,
            expiresAt: expiration,
            email: email,
            role: role,
            baseURL: baseURL,
            accountID: accountID,
            profileID: profileID,
            displayName: displayName,
            imageURL: account.imageURL,
            migratedProfileID: account.migratedProfileID
        )
    }

    func refresh(
        _ current: ResonanceAccountSession,
        migrationProfileID: String? = nil
    ) async throws -> ResonanceAccountSession {
        guard Self.httpsOrigin(current.baseURL) == baseURL else { throw ResonanceSocialAuthError.invalidConfiguration }
        let configuration = try await configuration()
        let token = try await token(
            configuration: configuration,
            body: [
                "grant_type": "refresh_token",
                "client_id": configuration.clientID,
                "refresh_token": try Self.bounded(current.refreshToken),
            ]
        )
        return try await authorizedSession(
            token,
            fallbackRefreshToken: current.refreshToken,
            migrationProfileID: current.profileID ?? migrationProfileID
        )
    }

    func signOut(_ current: ResonanceAccountSession) async {
        guard let configuration = try? await configuration() else { return }
        var request = URLRequest(url: configuration.logoutEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": current.refreshToken])
        _ = try? await session.data(for: request)
    }

    private func configuration() async throws -> ResonanceAuthConfiguration {
        let endpoint = baseURL.appendingPathComponent("api/v1/auth/config")
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let payload = try? JSONDecoder().decode(ResonanceAuthConfigurationPayload.self, from: data),
              (payload.version == 2 || payload.version == 3), payload.redirectURI == Self.callbackURL,
              payload.scope == "openid profile email",
              let issuer = Self.httpsOrigin(payload.issuer),
              Self.httpsOrigin(payload.authorizationEndpoint) == issuer,
              Self.httpsOrigin(payload.tokenEndpoint) == issuer,
              Self.httpsOrigin(payload.userEndpoint) == issuer,
              Self.httpsOrigin(payload.logoutEndpoint) == baseURL,
              payload.logoutEndpoint.path == "/api/v1/auth/logout",
              !payload.clientID.isEmpty else {
            throw ResonanceSocialAuthError.invalidConfiguration
        }
        let providers = Set(payload.providers).intersection(Self.supportedProviders)
        guard !providers.isEmpty else { throw ResonanceSocialAuthError.invalidConfiguration }
        let native: ResonanceNativeAuthConfiguration?
        if payload.version == 3 {
            guard let publishableKey = payload.publishableKey,
                  let tokenTemplate = payload.tokenTemplate,
                  Self.validPublishableKey(publishableKey, issuer: issuer),
                  tokenTemplate == "resonance" else {
                throw ResonanceSocialAuthError.invalidConfiguration
            }
            native = ResonanceNativeAuthConfiguration(
                publishableKey: try Self.bounded(publishableKey),
                tokenTemplate: tokenTemplate
            )
        } else {
            native = nil
        }
        return ResonanceAuthConfiguration(
            issuer: issuer,
            authorizationEndpoint: payload.authorizationEndpoint,
            tokenEndpoint: payload.tokenEndpoint,
            logoutEndpoint: payload.logoutEndpoint,
            clientID: try Self.bounded(payload.clientID),
            scope: payload.scope,
            providers: providers,
            native: native
        )
    }

    private func token(
        configuration: ResonanceAuthConfiguration,
        body: [String: String]
    ) async throws -> ResonanceAuthTokenPayload {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = body.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        let payload = try JSONDecoder().decode(ResonanceAuthTokenPayload.self, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ResonanceSocialAuthError.rejected(
                payload.message ?? payload.errorDescription ?? payload.error ?? "Sign-in could not be completed."
            )
        }
        return payload
    }

    private func authorizedSession(
        _ token: ResonanceAuthTokenPayload,
        fallbackRefreshToken: String = "",
        migrationProfileID: String? = nil
    ) async throws -> ResonanceAccountSession {
        guard let accessToken = token.idToken,
              let expiresIn = token.expiresIn, (1...604_800).contains(expiresIn) else {
            throw ResonanceSocialAuthError.invalidConfiguration
        }
        let refreshToken = token.refreshToken ?? fallbackRefreshToken
        let account = try await account(accessToken: accessToken, migrationProfileID: migrationProfileID)
        let profileID = ResonanceAccountScopePolicy.resolvedProfileID(
            accountID: account.id,
            serverProfileID: account.profileID,
            requestedLegacyProfileID: migrationProfileID
        )
        let displayName = try account.displayName.map { try Self.bounded($0) }
        guard let email = account.email?.lowercased(), !email.isEmpty,
              let role = account.role, role == "member" || role == "admin",
              let accountID = account.id, !accountID.isEmpty,
              let profileID else {
            throw ResonanceSocialAuthError.rejected(account.error ?? "This account could not access this Resonance server.")
        }
        return ResonanceAccountSession(
            accessToken: try Self.bounded(accessToken),
            refreshToken: try Self.bounded(refreshToken),
            expiresAt: Date().addingTimeInterval(expiresIn),
            email: email,
            role: role,
            baseURL: baseURL,
            accountID: accountID,
            profileID: profileID,
            displayName: displayName,
            imageURL: account.imageURL,
            migratedProfileID: account.migratedProfileID
        )
    }

    private func account(
        accessToken: String,
        migrationProfileID: String? = nil
    ) async throws -> ResonanceAccountPayload {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/auth/me"))
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try Self.bounded(accessToken))", forHTTPHeaderField: "Authorization")
        if let migrationProfileID,
           !migrationProfileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(migrationProfileID, forHTTPHeaderField: "X-Resonance-Profile")
        }
        let (data, response) = try await session.data(for: request)
        let account = try JSONDecoder().decode(ResonanceAccountPayload.self, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ResonanceSocialAuthError.rejected(account.error ?? "This account could not access this Resonance server.")
        }
        return account
    }

    private static func validPublishableKey(_ value: String, issuer: URL) -> Bool {
        let parts = value.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "pk", parts[1] == "test" || parts[1] == "live" else { return false }
        var encoded = String(parts[2]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let frontend = String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "$")),
              let url = URL(string: "https://\(frontend)") else { return false }
        return httpsOrigin(url) == issuer
    }

    private static func jwtExpiration(_ token: String) throws -> Date {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw ResonanceSocialAuthError.invalidConfiguration }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let seconds = payload["exp"] as? TimeInterval else {
            throw ResonanceSocialAuthError.invalidConfiguration
        }
        let expiration = Date(timeIntervalSince1970: seconds)
        guard expiration > Date(), expiration < Date().addingTimeInterval(7 * 24 * 60 * 60) else {
            throw ResonanceSocialAuthError.invalidConfiguration
        }
        return expiration
    }

    private static func httpsOrigin(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.host != nil else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        let host = url.host?.lowercased()
        components.host = host == resonanceLegacyProductionHost
            && (url.port == nil || url.port == 443)
            ? resonanceProductionHost
            : host
        if let port = url.port, port != 443 { components.port = port }
        return components.url
    }

    private static func randomToken(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ResonanceSocialAuthError.rejected("A secure sign-in challenge could not be created.")
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func bounded(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16 * 1024,
              text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
            throw ResonanceSocialAuthError.invalidConfiguration
        }
        return text
    }
}

@MainActor
private final class ResonanceSocialAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var webSession: ASWebAuthenticationSession?

    func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "resonance") { [self] callback, error in
                // Keep the presenter alive while AuthenticationServices owns the browser UI.
                // Clearing the session here breaks the temporary retention cycle on completion.
                webSession = nil
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? ResonanceSocialAuthError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                webSession = nil
                continuation.resume(throwing: ResonanceSocialAuthError.rejected("The sign-in browser could not be opened."))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
        #endif
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
