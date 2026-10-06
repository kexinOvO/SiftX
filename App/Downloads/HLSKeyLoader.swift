import Foundation
import SiftXCore

/// Keys are fetched through ordinary HTTP(S), cached per download, and never written to disk.
actor HLSKeyLoader {
    private struct Identity: Hashable { var url: URL; var occurrence: String }
    private let session: URLSession
    private let headers: [String: String]
    private var pending: [Identity: Task<Data, Error>] = [:]

    init(headers: [String: String]) {
        self.headers = URLSafety.requestHeaders(headers)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: KeyRedirectDelegate(), delegateQueue: nil)
    }

    func key(for encryption: HLSEncryption) async throws -> Data {
        try Task.checkCancellation()
        try URLSafety.validate(encryption.keyURL)
        guard encryption.iv.count == 16 else { throw MediaError.invalidEncryptionKey }
        let identity = Identity(url: encryption.keyURL, occurrence: encryption.keyID)
        let task: Task<Data, Error>
        if let existing = pending[identity] { task = existing }
        else {
            task = Task { [session, headers] in
                try await Self.fetch(url: encryption.keyURL, headers: headers, session: session)
            }
            pending[identity] = task
        }
        do {
            let key = try await withTaskCancellationHandler {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: { task.cancel() }
            return key
        } catch {
            pending[identity] = nil
            throw error
        }
    }

    func close() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
        session.invalidateAndCancel()
    }

    private static func fetch(url: URL, headers: [String: String], session: URLSession) async throws -> Data {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do {
                var request = URLRequest(url: url)
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
                request.setValue("application/octet-stream, */*", forHTTPHeaderField: "Accept")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let (bytes, response) = try await session.bytes(for: request)
                guard let response = response as? HTTPURLResponse, let effectiveURL = response.url else { throw DownloadError.invalidResponse }
                try URLSafety.validate(effectiveURL)
                guard (200..<300).contains(response.statusCode) else {
                    throw DownloadError.http(response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
                }
                if let mime = response.mimeType?.lowercased(), mime.contains("html") || mime.contains("json") {
                    throw MediaError.invalidEncryptionKey
                }
                guard response.expectedContentLength < 0 || response.expectedContentLength == 16 else { throw MediaError.invalidEncryptionKey }
                var key = Data()
                for try await byte in bytes {
                    guard key.count < 16 else { throw MediaError.invalidEncryptionKey }
                    key.append(byte)
                }
                guard key.count == 16 else { throw MediaError.invalidEncryptionKey }
                return key
            } catch {
                try Task.checkCancellation()
                if attempt < 3, error.isTransientDownloadFailure {
                    let delay = min(max((error as? DownloadError)?.retryDelay ?? 1, pow(2, Double(attempt))), 30)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else if error is MediaError { throw error }
                else { throw DownloadError.keyAccess(error.downloadDescription) }
            }
        }
        throw MediaError.invalidEncryptionKey
    }
}

private final class KeyRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? URLSafety.validate(url)) != nil else { completionHandler(nil); return }
        var next = request
        if url.host?.lowercased() != response.url?.host?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}
