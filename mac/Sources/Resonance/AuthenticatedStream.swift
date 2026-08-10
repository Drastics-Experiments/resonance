import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum MacAuthenticatedStreamError: LocalizedError, Equatable {
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
            "The signed stream authorization expired."
        case .resourceMismatch:
            "The server stream no longer matches the selected catalog song."
        case .unsupportedContentType:
            "The server returned a non-media stream response."
        }
    }
}

final class MacAuthenticatedStreamAuthorizationLease: @unchecked Sendable {
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private let context: MacClientConfigContext
    private var expiresAt: Date
    private var invalidated = false
    private var invalidationHandler: (@Sendable () -> Void)?

    init(
        context: MacClientConfigContext,
        expiresAt: Date,
        now: Date = .now
    ) throws {
        guard expiresAt > now else { throw MacAuthenticatedStreamError.authorizationExpired }
        self.context = context
        self.expiresAt = expiresAt
        timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "mov.unblocked.resonance.authenticated-stream-lease")
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

    func setInvalidationHandler(_ handler: (@Sendable () -> Void)?) {
        let callImmediately: Bool = lock.withLock {
            invalidationHandler = handler
            return invalidated && handler != nil
        }
        if callImmediately { handler?() }
    }

    func authorize(at now: Date = .now) throws {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !invalidated else { return nil }
            guard now < expiresAt else {
                invalidated = true
                let callback = invalidationHandler
                invalidationHandler = nil
                return callback
            }
            return nil
        }
        if let handler {
            handler()
            throw MacAuthenticatedStreamError.authorizationExpired
        }
        let isInvalid = lock.withLock { invalidated }
        if isInvalid { throw MacAuthenticatedStreamError.authorizationExpired }
    }

    func matches(context candidate: MacClientConfigContext) -> Bool {
        lock.withLock { !invalidated && context == candidate }
    }

    @discardableResult
    func renew(
        context newContext: MacClientConfigContext,
        expiresAt newExpiration: Date,
        now: Date = .now
    ) -> Bool {
        var callback: (@Sendable () -> Void)?
        let renewed: Bool = lock.withLock {
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
            expiresAt = newExpiration
            scheduleTimer(now: now)
            return true
        }
        callback?()
        return renewed
    }

    func invalidate() {
        let callback: (@Sendable () -> Void)? = lock.withLock {
            guard !invalidated else { return nil }
            invalidated = true
            let callback = invalidationHandler
            invalidationHandler = nil
            return callback
        }
        callback?()
    }

    private func expireIfNeeded() {
        var callback: (@Sendable () -> Void)?
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
        // Re-arm long-lived legacy/default leases periodically without risking
        // an integer overflow when their logical expiration is distantFuture.
        let remaining = min(max(expiresAt.timeIntervalSince(now), 0), 60 * 60)
        let nanoseconds = max(Int(remaining * 1_000_000_000), 1)
        timer.schedule(
            deadline: .now() + .nanoseconds(nanoseconds),
            leeway: .milliseconds(10)
        )
    }
}

enum MacAuthenticatedStreamSession {
    static func makeEphemeral() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }
}

enum MacRemoteStreamMediaPolicy {
    static let videoUnavailableMessage = "Video stream-only playback is not supported on macOS. Enable Verified file cache to download it, then use Watch Video."
    static let unknownSizeMessage = "Stream unavailable: the server did not publish a verified media size."

    static func unavailableMessage(kind: SongFilter, size: Int64) -> String? {
        if kind != .audio { return videoUnavailableMessage }
        if size <= 0 { return unknownSizeMessage }
        return nil
    }
}

enum MacRemoteStreamQueuePolicy {
    static func orderedNextID(current: String, eligible: [String]) -> String? {
        guard !eligible.isEmpty else { return nil }
        guard let index = eligible.firstIndex(of: current) else { return eligible.first }
        let following = eligible.index(after: index)
        return eligible[following == eligible.endIndex ? eligible.startIndex : following]
    }

    static func orderedPreviousID(current: String, eligible: [String]) -> String? {
        guard !eligible.isEmpty else { return nil }
        guard let index = eligible.firstIndex(of: current) else { return eligible.last }
        let previous = index == eligible.startIndex ? eligible.index(before: eligible.endIndex) : eligible.index(before: index)
        return eligible[previous]
    }

    static func reconciledShuffleQueue(
        existing: [String],
        history: [String],
        current: String,
        eligible: [String],
        shuffleMissing: ([String]) -> [String] = { $0.shuffled() }
    ) -> [String] {
        let eligibleSet = Set(eligible).subtracting([current])
        var seen = Set<String>()
        var output = existing.filter { eligibleSet.contains($0) && seen.insert($0).inserted }
        let played = Set(history).union([current])
        let missing = eligible.filter { eligibleSet.contains($0) && !seen.contains($0) && !played.contains($0) }
        output.append(contentsOf: shuffleMissing(missing))
        return output
    }

    static func popPreviousID(history: inout [String], eligible: Set<String>) -> String? {
        while let candidate = history.popLast() {
            if eligible.contains(candidate) { return candidate }
        }
        return nil
    }
}

enum MacOfflineDownloadAuthorizationPolicy {
    static func remainsAuthorized(
        lease: MacAuthenticatedStreamAuthorizationLease,
        context: MacClientConfigContext
    ) -> Bool {
        guard lease.matches(context: context) else { return false }
        do {
            try lease.authorize()
            return true
        } catch {
            return false
        }
    }
}

enum MacAuthorizedDownloadFinalizer {
    static func finalize(
        authorizationLease: MacAuthenticatedStreamAuthorizationLease,
        install: () throws -> Void
    ) throws {
        try authorizationLease.authorize()
        try install()
    }
}

enum MacLeaseBoundDownloader {
    static func download(
        request originalRequest: URLRequest,
        to destination: URL,
        expectedContentLength: Int64,
        authorizationLease: MacAuthenticatedStreamAuthorizationLease,
        session: URLSession
    ) async throws -> HTTPURLResponse {
        try authorizationLease.authorize()
        let worker = Task {
            try await downloadBody(
                request: originalRequest,
                to: destination,
                expectedContentLength: expectedContentLength,
                authorizationLease: authorizationLease,
                session: session
            )
        }
        authorizationLease.setInvalidationHandler { worker.cancel() }
        defer { authorizationLease.setInvalidationHandler(nil) }
        return try await worker.value
    }

    private static func downloadBody(
        request originalRequest: URLRequest,
        to destination: URL,
        expectedContentLength: Int64,
        authorizationLease: MacAuthenticatedStreamAuthorizationLease,
        session: URLSession
    ) async throws -> HTTPURLResponse {
        guard expectedContentLength > 0,
              let expectedURL = originalRequest.url else {
            throw MacAuthenticatedStreamError.resourceMismatch
        }
        var request = originalRequest
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try authorizationLease.authorize()
            let (bytes, rawResponse) = try await session.bytes(
                for: request,
                delegate: MacRejectRedirectDelegate()
            )
            guard let response = rawResponse as? HTTPURLResponse,
                  response.url?.absoluteString == expectedURL.absoluteString,
                  response.statusCode == 200 else {
                throw MacAuthenticatedStreamError.invalidResponse
            }
            if let contentEncoding = response.value(forHTTPHeaderField: "Content-Encoding")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
               !contentEncoding.isEmpty,
               contentEncoding != "identity" {
                throw MacAuthenticatedStreamError.invalidResponse
            }
            if let declaredLength = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
               declaredLength != expectedContentLength {
                throw MacAuthenticatedStreamError.resourceMismatch
            }

            var received: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1_024)
            for try await byte in bytes {
                try Task.checkCancellation()
                guard received < expectedContentLength else {
                    throw MacAuthenticatedStreamError.resourceMismatch
                }
                buffer.append(byte)
                received += 1
                if buffer.count >= 64 * 1_024 || received == expectedContentLength {
                    try authorizationLease.authorize()
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try authorizationLease.authorize()
            guard received == expectedContentLength else {
                throw MacAuthenticatedStreamError.truncatedResponse
            }
            return response
        } catch {
            try? fileManager.removeItem(at: destination)
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}

enum MacAuthenticatedStreamPolicy {
    struct ResponseMetadata: Equatable, Sendable {
        let contentLength: Int64
        let responseLength: Int64
        let contentType: String?
        let supportsByteRanges: Bool
    }

    private static let assetScheme = "resonance-authenticated-stream"

    static func assetURL(for sourceURL: URL) throws -> URL {
        guard isHTTPURL(sourceURL),
              sourceURL.user == nil,
              sourceURL.password == nil,
              var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            throw MacAuthenticatedStreamError.invalidURL
        }
        components.scheme = assetScheme
        guard let url = components.url else { throw MacAuthenticatedStreamError.invalidURL }
        return url
    }

    static func request(
        sourceURL: URL,
        headers: [String: String],
        offset: Int64,
        requestedLength: Int,
        requestsAllDataToEnd: Bool
    ) throws -> URLRequest {
        guard isHTTPURL(sourceURL), offset >= 0, requestedLength >= 0 else {
            throw MacAuthenticatedStreamError.invalidRange
        }
        var request = URLRequest(
            url: sourceURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if requestsAllDataToEnd || requestedLength == 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        } else {
            let (end, overflow) = offset.addingReportingOverflow(Int64(requestedLength - 1))
            guard !overflow else { throw MacAuthenticatedStreamError.invalidRange }
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        }
        return request
    }

    static func validate(
        response: HTTPURLResponse,
        sourceURL: URL,
        requestedOffset: Int64,
        expectedContentLength: Int64? = nil
    ) throws -> ResponseMetadata {
        guard response.url?.absoluteString == sourceURL.absoluteString else {
            throw MacAuthenticatedStreamError.crossOriginResponse
        }
        if let contentEncoding = response.value(forHTTPHeaderField: "Content-Encoding")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !contentEncoding.isEmpty,
           contentEncoding != "identity" {
            throw MacAuthenticatedStreamError.invalidResponse
        }
        guard let responseMIME = response.mimeType?.lowercased(),
              responseMIME.hasPrefix("audio/") || responseMIME.hasPrefix("video/") else {
            throw MacAuthenticatedStreamError.unsupportedContentType
        }
        let contentType = UTType(mimeType: responseMIME)?.identifier ?? responseMIME
        let expectedLength: Int64?
        if let expectedContentLength {
            guard expectedContentLength > 0 else {
                throw MacAuthenticatedStreamError.resourceMismatch
            }
            expectedLength = expectedContentLength
        } else {
            expectedLength = nil
        }
        switch response.statusCode {
        case 206:
            guard let range = parseContentRange(response.value(forHTTPHeaderField: "Content-Range")),
                  range.start == requestedOffset,
                  range.end >= range.start,
                  range.total > range.end else {
                throw MacAuthenticatedStreamError.invalidRange
            }
            if let expectedLength, range.total != expectedLength {
                throw MacAuthenticatedStreamError.resourceMismatch
            }
            let responseLength = range.end - range.start + 1
            if let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
               declared != responseLength {
                throw MacAuthenticatedStreamError.invalidRange
            }
            return ResponseMetadata(
                contentLength: range.total,
                responseLength: responseLength,
                contentType: contentType,
                supportsByteRanges: true
            )
        case 200:
            guard requestedOffset == 0,
                  let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                  length > 0 else {
                throw MacAuthenticatedStreamError.invalidResponse
            }
            if let expectedLength, length != expectedLength {
                throw MacAuthenticatedStreamError.resourceMismatch
            }
            return ResponseMetadata(
                contentLength: length,
                responseLength: length,
                contentType: contentType,
                supportsByteRanges: response.value(forHTTPHeaderField: "Accept-Ranges")?
                    .lowercased()
                    .split(separator: ",")
                    .contains(where: { $0.trimmingCharacters(in: .whitespaces) == "bytes" }) == true
            )
        default:
            throw MacAuthenticatedStreamError.invalidResponse
        }
    }

    private static func parseContentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let value,
              value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst("bytes ".count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let total = Int64(parts[1]) else { return nil }
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

final class MacAuthenticatedStreamResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let delegateQueue = DispatchQueue(label: "mov.unblocked.resonance.authenticated-stream-loader")

    private final class LoadingRequestBox: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest

        init(_ request: AVAssetResourceLoadingRequest) {
            self.request = request
        }
    }

    private let sourceURL: URL
    private let headers: [String: String]
    private let expectedContentLength: Int64
    private let authorizationLease: MacAuthenticatedStreamAuthorizationLease
    private let session: URLSession
    private let ownsSession: Bool
    private let onAuthorizationInvalidated: (@Sendable () -> Void)?
    private let stateQueue = DispatchQueue(label: "mov.unblocked.resonance.authenticated-stream-loader.state")
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var invalidated = false

    init(
        sourceURL: URL,
        headers: [String: String],
        expectedContentLength: Int64,
        authorizationLease: MacAuthenticatedStreamAuthorizationLease,
        session: URLSession? = nil,
        onAuthorizationInvalidated: (@Sendable () -> Void)? = nil
    ) {
        self.sourceURL = sourceURL
        self.headers = headers
        self.expectedContentLength = expectedContentLength
        self.authorizationLease = authorizationLease
        self.onAuthorizationInvalidated = onAuthorizationInvalidated
        if let session {
            self.session = session
            ownsSession = false
        } else {
            self.session = MacAuthenticatedStreamSession.makeEphemeral()
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
            loadingRequest.finishLoading(with: MacAuthenticatedStreamError.authorizationExpired)
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
        defer {
            _ = stateQueue.sync { tasks.removeValue(forKey: identifier) }
        }
        let loadingRequest = box.request
        do {
            try Task.checkCancellation()
            try authorizationLease.authorize()
            let dataRequest = loadingRequest.dataRequest
            let requestedOffset = dataRequest.map {
                $0.currentOffset != 0 ? $0.currentOffset : $0.requestedOffset
            } ?? 0
            let request = try MacAuthenticatedStreamPolicy.request(
                sourceURL: sourceURL,
                headers: headers,
                offset: requestedOffset,
                requestedLength: dataRequest?.requestedLength ?? 1,
                requestsAllDataToEnd: dataRequest?.requestsAllDataToEndOfResource ?? false
            )
            let (bytes, rawResponse) = try await session.bytes(
                for: request,
                delegate: MacRejectRedirectDelegate()
            )
            guard let response = rawResponse as? HTTPURLResponse else {
                throw MacAuthenticatedStreamError.invalidResponse
            }
            let metadata = try MacAuthenticatedStreamPolicy.validate(
                response: response,
                sourceURL: sourceURL,
                requestedOffset: requestedOffset,
                expectedContentLength: expectedContentLength
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

            let requestedCount = dataRequest.requestsAllDataToEndOfResource
                ? metadata.responseLength
                : min(Int64(dataRequest.requestedLength), metadata.responseLength)
            guard requestedCount >= 0 else { throw MacAuthenticatedStreamError.invalidRange }
            var received: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(64 * 1_024)
            for try await byte in bytes {
                try Task.checkCancellation()
                guard received < requestedCount else { break }
                buffer.append(byte)
                received += 1
                if buffer.count >= 64 * 1_024 || received == requestedCount {
                    try authorizationLease.authorize()
                    dataRequest.respond(with: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try authorizationLease.authorize()
            guard received == requestedCount else {
                throw MacAuthenticatedStreamError.truncatedResponse
            }
            loadingRequest.finishLoading()
        } catch is CancellationError {
            let loaderWasInvalidated = stateQueue.sync { invalidated }
            if loaderWasInvalidated {
                loadingRequest.finishLoading(with: MacAuthenticatedStreamError.authorizationExpired)
            }
            return
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }
}
