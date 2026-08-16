import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum MobileAuthenticatedStreamError: LocalizedError, Equatable {
    case invalidURL
    case invalidRange
    case invalidResponse
    case crossOriginResponse
    case truncatedResponse
    case authorizationExpired
    case resourceMismatch
    case unsupportedContentType

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The server stream URL is invalid."
        case .invalidRange:
            "The server returned an invalid media range."
        case .invalidResponse:
            "The server returned an invalid stream response."
        case .crossOriginResponse:
            "The server tried to redirect playback away from the configured Resonance server."
        case .truncatedResponse:
            "The server stream ended before the requested media range was complete."
        case .authorizationExpired:
            "The signed stream authorization expired or changed."
        case .resourceMismatch:
            "The server stream no longer matches the selected catalog song."
        case .unsupportedContentType:
            "Stream-only playback currently supports audio songs only. Download videos for playback."
        }
    }
}

struct MobileAuthenticatedStreamLeaseContext: Equatable, Sendable {
    let origin: String
    let requestContext: MobileClientRequestContext
    let tokenFingerprint: String
}

final class MobileAuthenticatedStreamAuthorizationLease: @unchecked Sendable {
    typealias InvalidationHandler = @Sendable () -> Void

    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private let context: MobileAuthenticatedStreamLeaseContext
    private var expiresAt: Date
    private var invalidated = false
    private var invalidationHandler: InvalidationHandler?

    init(
        context: MobileAuthenticatedStreamLeaseContext,
        expiresAt: Date,
        now: Date = .now
    ) throws {
        guard expiresAt > now else { throw MobileAuthenticatedStreamError.authorizationExpired }
        self.context = context
        self.expiresAt = expiresAt
        timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "mov.unblocked.resonance.ios.authenticated-stream-lease")
        )
        timer.setEventHandler { [weak self] in
            self?.expireIfNeeded()
        }
        scheduleTimer(now: now)
        timer.resume()
    }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
    }

    var expiration: Date {
        lock.withLock { expiresAt }
    }

    func setInvalidationHandler(_ handler: InvalidationHandler?) {
        let callImmediately = lock.withLock {
            invalidationHandler = handler
            return invalidated && handler != nil
        }
        if callImmediately { handler?() }
    }

    func authorize(at now: Date = .now) throws {
        var callback: InvalidationHandler?
        let authorized = lock.withLock {
            guard !invalidated else { return false }
            guard now < expiresAt else {
                invalidated = true
                callback = invalidationHandler
                invalidationHandler = nil
                return false
            }
            return true
        }
        callback?()
        guard authorized else { throw MobileAuthenticatedStreamError.authorizationExpired }
    }

    /// A verified response may update the lease in the exact same request context.
    /// Equal expirations retain the captured deadline while either an earlier or
    /// later authoritative expiration replaces and reschedules it.
    @discardableResult
    func renew(
        context newContext: MobileAuthenticatedStreamLeaseContext,
        expiresAt newExpiration: Date,
        now: Date = .now
    ) -> Bool {
        var callback: InvalidationHandler?
        let accepted = lock.withLock {
            guard !invalidated,
                  now < expiresAt,
                  newContext == context,
                  newExpiration > now else {
                if !invalidated {
                    invalidated = true
                    callback = invalidationHandler
                    invalidationHandler = nil
                }
                return false
            }
            if newExpiration != expiresAt {
                expiresAt = newExpiration
                scheduleTimer(now: now)
            }
            return true
        }
        callback?()
        return accepted
    }

    func invalidate() {
        let callback: InvalidationHandler? = lock.withLock {
            guard !invalidated else { return nil }
            invalidated = true
            let callback = invalidationHandler
            invalidationHandler = nil
            return callback
        }
        callback?()
    }

    private func expireIfNeeded() {
        var callback: InvalidationHandler?
        lock.withLock {
            guard !invalidated else { return }
            let now = Date.now
            guard now >= expiresAt else {
                scheduleTimer(now: now)
                return
            }
            invalidated = true
            callback = invalidationHandler
            invalidationHandler = nil
        }
        callback?()
    }

    private func scheduleTimer(now: Date) {
        let remaining = max(expiresAt.timeIntervalSince(now), 0)
        let nanoseconds = max(Int(remaining * 1_000_000_000), 1)
        timer.schedule(
            deadline: .now() + .nanoseconds(nanoseconds),
            leeway: .milliseconds(10)
        )
    }
}

final class MobileRejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum MobileAuthenticatedStreamSession {
    static func makeEphemeral() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }
}

enum MobileAuthenticatedStreamPolicy {
    struct RequestPlan {
        let request: URLRequest
        let offset: Int64
        let end: Int64

        var responseLength: Int64 { end - offset + 1 }
    }

    struct ResponseMetadata: Equatable, Sendable {
        let contentLength: Int64
        let responseLength: Int64
        let contentType: String
        let supportsByteRanges: Bool
    }

    private static let assetScheme = "resonance-authenticated-stream"

    static func normalizedAudioMIMEType(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalized, normalized.hasPrefix("audio/") else { return nil }
        return normalized
    }

    static func validateDescriptor(
        catalogLength: Int64,
        catalogSHA256: String?,
        catalogContentType: String,
        locationLength: Int64,
        locationSHA256: String?,
        locationContentType: String,
        supportsRanges: Bool,
        state: String
    ) throws -> String {
        guard catalogLength > 0,
              locationLength == catalogLength,
              supportsRanges,
              state == "active" else {
            throw MobileAuthenticatedStreamError.resourceMismatch
        }
        guard let catalogMIME = normalizedAudioMIMEType(catalogContentType),
              let locationMIME = normalizedAudioMIMEType(locationContentType),
              catalogMIME == locationMIME else {
            throw MobileAuthenticatedStreamError.unsupportedContentType
        }
        let catalogHash = MobileContentHashPolicy.normalizedSHA256(catalogSHA256)
        let locationHash = MobileContentHashPolicy.normalizedSHA256(locationSHA256)
        if catalogHash != nil || locationHash != nil {
            guard catalogHash == locationHash else {
                throw MobileAuthenticatedStreamError.resourceMismatch
            }
        }
        return catalogMIME
    }

    static func assetURL(for sourceURL: URL) throws -> URL {
        guard isHTTPURL(sourceURL),
              sourceURL.user == nil,
              sourceURL.password == nil,
              var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            throw MobileAuthenticatedStreamError.invalidURL
        }
        components.scheme = assetScheme
        guard let url = components.url else { throw MobileAuthenticatedStreamError.invalidURL }
        return url
    }

    static func requestPlan(
        sourceURL: URL,
        headers: [String: String],
        offset: Int64,
        requestedLength: Int,
        requestsAllDataToEnd: Bool,
        expectedContentLength: Int64
    ) throws -> RequestPlan {
        guard isHTTPURL(sourceURL),
              offset >= 0,
              requestedLength >= 0,
              expectedContentLength > 0,
              offset < expectedContentLength else {
            throw MobileAuthenticatedStreamError.invalidRange
        }
        let end: Int64
        if requestsAllDataToEnd || requestedLength == 0 {
            end = expectedContentLength - 1
        } else {
            let (requestedEnd, overflow) = offset.addingReportingOverflow(Int64(requestedLength - 1))
            guard !overflow else { throw MobileAuthenticatedStreamError.invalidRange }
            end = min(requestedEnd, expectedContentLength - 1)
        }
        guard end >= offset else { throw MobileAuthenticatedStreamError.invalidRange }

        var request = URLRequest(
            url: sourceURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 60
        )
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        return RequestPlan(request: request, offset: offset, end: end)
    }

    static func validate(
        response: HTTPURLResponse,
        sourceURL: URL,
        requestPlan: RequestPlan,
        expectedContentLength: Int64,
        expectedContentType: String
    ) throws -> ResponseMetadata {
        guard response.url?.absoluteString == sourceURL.absoluteString else {
            throw MobileAuthenticatedStreamError.crossOriginResponse
        }
        if let contentEncoding = response.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !contentEncoding.isEmpty,
           contentEncoding != "identity" {
            throw MobileAuthenticatedStreamError.invalidResponse
        }
        guard let expectedMIME = normalizedAudioMIMEType(expectedContentType),
              let responseMIME = normalizedAudioMIMEType(response.mimeType),
              responseMIME == expectedMIME else {
            throw MobileAuthenticatedStreamError.unsupportedContentType
        }
        guard expectedContentLength > 0,
              response.statusCode == 206,
              let range = parseContentRange(response.value(forHTTPHeaderField: "Content-Range")),
              range.start == requestPlan.offset,
              range.end == requestPlan.end,
              range.total == expectedContentLength,
              let declaredLength = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
              declaredLength == requestPlan.responseLength else {
            throw MobileAuthenticatedStreamError.invalidRange
        }
        return ResponseMetadata(
            contentLength: expectedContentLength,
            responseLength: requestPlan.responseLength,
            contentType: UTType(mimeType: responseMIME)?.identifier ?? responseMIME,
            supportsByteRanges: true
        )
    }

    private static func parseContentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst("bytes ".count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int64(parts[1]), total > 0 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]) else { return nil }
        return (start, end, total)
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return false }
        return true
    }
}

final class MobileAuthenticatedStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let delegateQueue = DispatchQueue(label: "mov.unblocked.resonance.ios.authenticated-stream-loader")

    private final class LoadingRequestBox: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest

        init(_ request: AVAssetResourceLoadingRequest) {
            self.request = request
        }
    }

    private let sourceURL: URL
    private let headers: [String: String]
    private let expectedContentLength: Int64
    private let expectedContentType: String
    private let authorizationLease: MobileAuthenticatedStreamAuthorizationLease
    private let session: URLSession
    private let ownsSession: Bool
    private let onAuthorizationInvalidated: (@Sendable () -> Void)?
    private let stateQueue = DispatchQueue(label: "mov.unblocked.resonance.ios.authenticated-stream-loader.state")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var invalidated = false

    init(
        sourceURL: URL,
        headers: [String: String],
        expectedContentLength: Int64,
        expectedContentType: String,
        authorizationLease: MobileAuthenticatedStreamAuthorizationLease,
        session: URLSession? = nil,
        onAuthorizationInvalidated: (@Sendable () -> Void)? = nil
    ) {
        self.sourceURL = sourceURL
        self.headers = headers
        self.expectedContentLength = expectedContentLength
        self.expectedContentType = expectedContentType
        self.authorizationLease = authorizationLease
        self.onAuthorizationInvalidated = onAuthorizationInvalidated
        if let session {
            self.session = session
            ownsSession = false
        } else {
            self.session = MobileAuthenticatedStreamSession.makeEphemeral()
            ownsSession = true
        }
        super.init()
        authorizationLease.setInvalidationHandler { [weak self] in
            self?.authorizationDidInvalidate()
        }
    }

    deinit {
        authorizationLease.setInvalidationHandler(nil)
        let active = stateQueue.sync {
            let active = Array(tasks.values)
            tasks.removeAll()
            invalidated = true
            return active
        }
        active.forEach { $0.cancel() }
        if ownsSession { session.invalidateAndCancel() }
    }

    func invalidate() {
        let active = stateQueue.sync {
            guard !invalidated else { return [Task<Void, Never>]() }
            invalidated = true
            let active = Array(tasks.values)
            tasks.removeAll()
            return active
        }
        active.forEach { $0.cancel() }
        if ownsSession { session.invalidateAndCancel() }
    }

    private func authorizationDidInvalidate() {
        invalidate()
        onAuthorizationInvalidated?()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let identifier = ObjectIdentifier(loadingRequest)
        let box = LoadingRequestBox(loadingRequest)
        do {
            try authorizationLease.authorize()
        } catch {
            loadingRequest.finishLoading(with: error)
            return true
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await fulfill(box, identifier: identifier)
        }
        let accepted = stateQueue.sync {
            guard !invalidated else { return false }
            tasks[identifier]?.cancel()
            tasks[identifier] = task
            return true
        }
        if !accepted {
            task.cancel()
            loadingRequest.finishLoading(with: MobileAuthenticatedStreamError.authorizationExpired)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let identifier = ObjectIdentifier(loadingRequest)
        let task = stateQueue.sync { tasks.removeValue(forKey: identifier) }
        task?.cancel()
    }

    private func fulfill(_ box: LoadingRequestBox, identifier: ObjectIdentifier) async {
        defer { _ = stateQueue.sync { tasks.removeValue(forKey: identifier) } }
        let loadingRequest = box.request
        do {
            try Task.checkCancellation()
            try authorizationLease.authorize()
            let dataRequest = loadingRequest.dataRequest
            let requestedOffset = dataRequest.map {
                $0.currentOffset != 0 ? $0.currentOffset : $0.requestedOffset
            } ?? 0
            let plan = try MobileAuthenticatedStreamPolicy.requestPlan(
                sourceURL: sourceURL,
                headers: headers,
                offset: requestedOffset,
                requestedLength: dataRequest?.requestedLength ?? 1,
                requestsAllDataToEnd: dataRequest?.requestsAllDataToEndOfResource ?? false,
                expectedContentLength: expectedContentLength
            )
            let (bytes, rawResponse) = try await session.bytes(
                for: plan.request,
                delegate: MobileRejectRedirectDelegate()
            )
            guard let response = rawResponse as? HTTPURLResponse else {
                throw MobileAuthenticatedStreamError.invalidResponse
            }
            let metadata = try MobileAuthenticatedStreamPolicy.validate(
                response: response,
                sourceURL: sourceURL,
                requestPlan: plan,
                expectedContentLength: expectedContentLength,
                expectedContentType: expectedContentType
            )
            try authorizationLease.authorize()
            if let content = loadingRequest.contentInformationRequest {
                content.contentType = metadata.contentType
                content.contentLength = metadata.contentLength
                content.isByteRangeAccessSupported = metadata.supportsByteRanges
            }
            guard let dataRequest else {
                loadingRequest.finishLoading()
                return
            }

            var received: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1_024)
            for try await byte in bytes {
                try Task.checkCancellation()
                guard received < metadata.responseLength else {
                    throw MobileAuthenticatedStreamError.invalidRange
                }
                buffer.append(byte)
                received += 1
                if buffer.count >= 64 * 1_024 || received == metadata.responseLength {
                    try authorizationLease.authorize()
                    dataRequest.respond(with: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try authorizationLease.authorize()
            guard received == metadata.responseLength else {
                throw MobileAuthenticatedStreamError.truncatedResponse
            }
            loadingRequest.finishLoading()
        } catch is CancellationError {
            let loaderWasInvalidated = stateQueue.sync { invalidated }
            if loaderWasInvalidated {
                loadingRequest.finishLoading(with: MobileAuthenticatedStreamError.authorizationExpired)
            }
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }
}

/// Range-capable YouTube playback for transient Listen Along media. Supplying
/// headers through AVURLAsset options is not reliable across AVFoundation's
/// follow-up range requests, so this loader applies the same verified range
/// contract used by the working download path.
final class MobileYouTubeStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let delegateQueue = DispatchQueue(label: "mov.unblocked.resonance.ios.youtube-stream-loader")

    private final class LoadingRequestBox: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
        init(_ request: AVAssetResourceLoadingRequest) { self.request = request }
    }

    private let sourceURL: URL
    private let headers: [String: String]
    private let contentLength: Int64
    private let contentType: String
    private let session: URLSession
    private let stateQueue = DispatchQueue(label: "mov.unblocked.resonance.ios.youtube-stream-loader.state")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var invalidated = false

    init(sourceURL: URL, headers: [String: String], contentLength: Int64, contentType: String) throws {
        guard Self.isGoogleVideo(sourceURL), contentLength > 0 else {
            throw MobileAuthenticatedStreamError.invalidURL
        }
        self.sourceURL = sourceURL
        self.headers = try Self.safeHeaders(headers)
        self.contentLength = contentLength
        self.contentType = contentType
        self.session = MobileAuthenticatedStreamSession.makeEphemeral()
        super.init()
    }

    deinit { invalidate() }

    static func assetURL(for sourceURL: URL) throws -> URL {
        guard isGoogleVideo(sourceURL),
              var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            throw MobileAuthenticatedStreamError.invalidURL
        }
        components.scheme = "resonance-youtube"
        guard let url = components.url else { throw MobileAuthenticatedStreamError.invalidURL }
        return url
    }

    func invalidate() {
        let active = stateQueue.sync {
            guard !invalidated else { return [Task<Void, Never>]() }
            invalidated = true
            let active = Array(tasks.values)
            tasks.removeAll()
            return active
        }
        active.forEach { $0.cancel() }
        session.invalidateAndCancel()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let identifier = ObjectIdentifier(loadingRequest)
        let box = LoadingRequestBox(loadingRequest)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.fulfill(box, identifier: identifier)
        }
        let accepted = stateQueue.sync {
            guard !invalidated else { return false }
            tasks[identifier]?.cancel()
            tasks[identifier] = task
            return true
        }
        if !accepted {
            task.cancel()
            loadingRequest.finishLoading(with: CancellationError())
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let task = stateQueue.sync { tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) }
        task?.cancel()
    }

    private func fulfill(_ box: LoadingRequestBox, identifier: ObjectIdentifier) async {
        defer { _ = stateQueue.sync { tasks.removeValue(forKey: identifier) } }
        let loadingRequest = box.request
        do {
            try Task.checkCancellation()
            let dataRequest = loadingRequest.dataRequest
            let offset = dataRequest.map { $0.currentOffset != 0 ? $0.currentOffset : $0.requestedOffset } ?? 0
            guard offset >= 0, offset < contentLength else { throw MobileAuthenticatedStreamError.invalidRange }
            let requestedCount = dataRequest.map {
                $0.requestsAllDataToEndOfResource
                    ? contentLength - offset
                    : min(Int64($0.requestedLength), contentLength - offset)
            } ?? 1
            guard requestedCount > 0 else { throw MobileAuthenticatedStreamError.invalidRange }

            if let information = loadingRequest.contentInformationRequest {
                information.contentType = UTType(mimeType: contentType)?.identifier ?? contentType
                information.contentLength = contentLength
                information.isByteRangeAccessSupported = true
            }
            guard let dataRequest else {
                loadingRequest.finishLoading()
                return
            }
            var received: Int64 = 0
            while received < requestedCount {
                let chunkStart = offset + received
                let chunkCount = min(10 * 1_024 * 1_024, requestedCount - received)
                var request = URLRequest(url: sourceURL)
                request.httpMethod = "GET"
                request.cachePolicy = .reloadIgnoringLocalCacheData
                headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue("bytes=\(chunkStart)-\(chunkStart + chunkCount - 1)", forHTTPHeaderField: "Range")
                let (bytes, rawResponse) = try await session.bytes(for: request, delegate: MobileRejectRedirectDelegate())
                guard let response = rawResponse as? HTTPURLResponse,
                      response.statusCode == 206,
                      Self.isGoogleVideo(response.url),
                      let range = Self.contentRange(response.value(forHTTPHeaderField: "Content-Range")),
                      range.start == chunkStart,
                      range.end - range.start + 1 == chunkCount,
                      range.total == contentLength else {
                    throw MobileAuthenticatedStreamError.invalidRange
                }
                var chunkReceived: Int64 = 0
                var buffer = Data()
                buffer.reserveCapacity(64 * 1_024)
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard chunkReceived < chunkCount else { throw MobileAuthenticatedStreamError.invalidRange }
                    buffer.append(byte)
                    chunkReceived += 1
                    if buffer.count >= 64 * 1_024 || chunkReceived == chunkCount {
                        dataRequest.respond(with: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                guard chunkReceived == chunkCount else { throw MobileAuthenticatedStreamError.truncatedResponse }
                received += chunkReceived
            }
            loadingRequest.finishLoading()
        } catch is CancellationError {
            return
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }

    private static func safeHeaders(_ headers: [String: String]) throws -> [String: String] {
        guard !headers.keys.contains(where: {
            $0.caseInsensitiveCompare("Authorization") == .orderedSame
                || $0.caseInsensitiveCompare("Cookie") == .orderedSame
        }) else { throw MobileAuthenticatedStreamError.invalidURL }
        let allowed = Set(["accept", "accept-language", "origin", "referer", "user-agent", "x-goog-visitor-id"])
        return headers.filter { allowed.contains($0.key.lowercased()) && !$0.value.isEmpty && $0.value.count <= 2_048 }
    }

    private static func isGoogleVideo(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else { return false }
        return host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }

    private static func contentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let halves = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        let bounds = halves.first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
        guard halves.count == 2, bounds.count == 2,
              let start = Int64(bounds[0]), let end = Int64(bounds[1]), let total = Int64(halves[1]) else { return nil }
        return (start, end, total)
    }
}
