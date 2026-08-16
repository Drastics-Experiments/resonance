import Foundation

final class MacBoundedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let validator: @Sendable (URL) -> Bool

    init(validator: @escaping @Sendable (URL) -> Bool) {
        self.validator = validator
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(validator) == true ? request : nil)
    }
}

/// Reads a response incrementally so an attacker-controlled body cannot be
/// handed to a JSON/image decoder before its size has been checked.
enum MacBoundedResponse {
    static func data(
        for session: URLSession,
        request: URLRequest,
        limit: Int,
        rejectRedirects: Bool = true,
        redirectValidator: (@Sendable (URL) -> Bool)? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        guard limit > 0 else { throw MacBoundedResponseError.responseTooLarge }

        do {
            let bytes: URLSession.AsyncBytes
            let rawResponse: URLResponse
            if let redirectValidator {
                (bytes, rawResponse) = try await session.bytes(
                    for: request,
                    delegate: MacBoundedRedirectDelegate(validator: redirectValidator)
                )
            } else if rejectRedirects {
                (bytes, rawResponse) = try await session.bytes(
                    for: request,
                    delegate: MacRejectRedirectDelegate()
                )
            } else {
                (bytes, rawResponse) = try await session.bytes(for: request)
            }

            guard let response = rawResponse as? HTTPURLResponse else {
                throw MacBoundedResponseError.invalidResponse
            }
            if let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
               declared > limit {
                throw MacBoundedResponseError.responseTooLarge
            }

            var data = Data()
            data.reserveCapacity(min(limit, 64 * 1_024))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else {
                    throw MacBoundedResponseError.responseTooLarge
                }
                data.append(byte)
            }
            return (data, response)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}
