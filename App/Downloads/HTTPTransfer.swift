import Foundation
import SiftXCore

/// Streams bytes to disk. A single serial delegate queue owns the file handle;
/// the lock only coordinates cancellation and the async continuation.
final class HTTPTransfer: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private struct ResumeMetadata: Codable {
        var url: String
        var validator: String?
        var total: Int64?
    }

    private let url: URL
    private let headers: [String: String]
    private let destination: URL
    private let fixedRange: String?
    private let progress: @Sendable (TransferProgress) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<TransferProgress, Error>?
    private var cancellationRequested = false
    private var responseError: Error?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var initialOffset: Int64 = 0
    private var expectedTotal: Int64?
    private var expectedRangeBytes: Int64?
    private var lastReport: TimeInterval = 0

    init(url: URL, headers: [String: String], destination: URL, range: String? = nil,
         progress: @escaping @Sendable (TransferProgress) -> Void) {
        self.url = url
        self.headers = headers
        self.destination = destination
        self.fixedRange = range
        self.progress = progress
    }

    func run() async throws -> TransferProgress {
        try URLSafety.validate(url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                if cancellationRequested {
                    self.continuation = nil
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                lock.unlock()
                do {
                    try prepareRequest()
                } catch {
                    finish(error: error)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func prepareRequest() throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
        for (key, value) in URLSafety.requestHeaders(headers) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Byte ranges refer to the identity representation, never gzip bytes.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        initialOffset = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if let fixedRange {
            // A partially downloaded segment is deliberately fetched again.
            // Completed segments are reused by SegmentedDownloader.
            initialOffset = 0
            request.setValue(fixedRange, forHTTPHeaderField: "Range")
            if let parsed = Self.parseRange(fixedRange) { expectedRangeBytes = parsed.end - parsed.start + 1 }
            else { throw DownloadError.invalidRange }
        } else if initialOffset > 0 {
            if let metadata = try? JSONDecoder().decode(ResumeMetadata.self, from: Data(contentsOf: metadataURL)),
               metadata.url == url.absoluteString, let validator = metadata.validator {
                request.setValue("bytes=\(initialOffset)-", forHTTPHeaderField: "Range")
                request.setValue(validator, forHTTPHeaderField: "If-Range")
                expectedTotal = metadata.total
            } else {
                // A representation without a strong identity cannot safely be
                // appended after a restart. Fetch it again instead of mixing
                // bytes from two potentially different versions of the URL.
                initialOffset = 0
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 24 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "SiftX.MediaTransfer"
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        lock.lock()
        self.session = session
        self.task = task
        let cancelled = cancellationRequested
        lock.unlock()
        if cancelled { task.cancel() }
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw DownloadError.invalidResponse }
            if response.statusCode == 416, fixedRange == nil,
               let text = response.value(forHTTPHeaderField: "Content-Range"),
               let total = Int64(text.split(separator: "/").last ?? ""), total > 0, total == initialOffset {
                received = initialOffset
                expectedTotal = total
                // The saved partial already contains the entire resource.
                completionHandler(.cancel)
                finish(error: nil)
                return
            }
            guard (200...299).contains(response.statusCode) else {
                let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
                throw DownloadError.http(response.statusCode, retryAfter: delay)
            }
            if let mime = response.mimeType?.lowercased(),
               ["text/html", "application/xhtml+xml", "application/json"].contains(mime) || mime.hasSuffix("+json") {
                throw DownloadError.unexpectedContent
            }
            if let fixedRange {
                guard response.statusCode == 206,
                      let requested = Self.parseRange(fixedRange),
                      let actual = Self.parseContentRange(response.value(forHTTPHeaderField: "Content-Range")),
                      requested.start == actual.start, requested.end == actual.end else { throw DownloadError.invalidRange }
                expectedTotal = expectedRangeBytes
            } else if response.statusCode == 206 {
                guard let range = Self.parseContentRange(response.value(forHTTPHeaderField: "Content-Range")),
                      range.start == initialOffset, range.total != nil else { throw DownloadError.invalidRange }
                expectedTotal = range.total
            } else {
                // A server ignoring Range, or a changed If-Range validator,
                // must reset the file before the replacement body is written.
                initialOffset = 0
                expectedTotal = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            }
            if !FileManager.default.fileExists(atPath: destination.path) {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw DownloadError.disk("无法创建临时文件。") }
            }
            let handle = try FileHandle(forWritingTo: destination)
            self.handle = handle
            if initialOffset == 0 { try handle.truncate(atOffset: 0) }
            try handle.seek(toOffset: UInt64(initialOffset))
            received = initialOffset
            let etag = response.value(forHTTPHeaderField: "ETag")
            let validator = etag.flatMap { $0.hasPrefix("W/") ? nil : $0 } ?? response.value(forHTTPHeaderField: "Last-Modified")
            let metadata = ResumeMetadata(url: url.absoluteString, validator: validator, total: expectedTotal)
            if fixedRange == nil { try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic) }
            report(force: true)
            completionHandler(.allow)
        } catch {
            responseError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard responseError == nil else { return }
        do {
            guard let handle else { throw DownloadError.disk("无法打开临时文件。") }
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            if let total = expectedTotal, received > total { throw DownloadError.invalidResponse }
            report(force: false)
        } catch {
            responseError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        do {
            try handle?.synchronize()
            try handle?.close()
            handle = nil
            lock.lock()
            let cancelled = cancellationRequested
            lock.unlock()
            if cancelled { finish(error: CancellationError()) }
            else if let error = responseError ?? error { finish(error: error) }
            else if received == 0 { finish(error: DownloadError.emptyFile) }
            else if let total = expectedTotal, received != total { finish(error: URLError(.networkConnectionLost)) }
            else { report(force: true); finish(error: nil) }
        } catch { finish(error: error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, (try? URLSafety.validate(next)) != nil else {
            responseError = DownloadError.invalidResponse
            completionHandler(nil)
            return
        }
        var request = request
        if next.host?.lowercased() != response.url?.host?.lowercased() {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(request)
    }

    private func report(force: Bool) {
        let now = Date.timeIntervalSinceReferenceDate
        guard force || now - lastReport > 0.15 else { return }
        lastReport = now
        progress(TransferProgress(bytes: received, total: expectedTotal))
    }

    private func finish(error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        lock.unlock()
        guard let continuation else { return }
        session?.finishTasksAndInvalidate()
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: TransferProgress(bytes: received, total: expectedTotal)) }
    }

    private var metadataURL: URL { destination.appendingPathExtension("http.json") }

    private static func parseRange(_ value: String) -> (start: Int64, end: Int64)? {
        guard value.hasPrefix("bytes=") else { return nil }
        let pieces = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2, let start = Int64(pieces[0]), let end = Int64(pieces[1]), start >= 0, end >= start else { return nil }
        return (start, end)
    }

    private static func parseContentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let pieces = value.dropFirst(6).split(separator: "/")
        guard pieces.count == 2 else { return nil }
        let range = pieces[0].split(separator: "-")
        guard range.count == 2, let start = Int64(range[0]), let end = Int64(range[1]), start >= 0, end >= start else { return nil }
        let total = Int64(pieces[1])
        if let total, total <= end { return nil }
        return (start, end, total)
    }
}

enum TransferRetry {
    static func download(url: URL, headers: [String: String], destination: URL, range: String? = nil,
                         progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferProgress {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            do {
                return try await HTTPTransfer(url: url, headers: headers, destination: destination, range: range, progress: progress).run()
            } catch {
                try Task.checkCancellation()
                guard attempt < 3, error.isTransientDownloadFailure else { throw error }
                if case DownloadError.invalidRange = error {
                    try? FileManager.default.removeItem(at: destination)
                    try? FileManager.default.removeItem(at: destination.appendingPathExtension("http.json"))
                }
                let suggested = (error as? DownloadError)?.retryDelay ?? 1
                let delay = min(max(suggested, pow(2, Double(attempt))), 30)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw DownloadError.invalidResponse
    }
}
