import Foundation
import Network
import SiftXCore

/// A short-lived loopback stream for AVPlayer. Keeps source headers on every media
/// request and combines the selected video/audio renditions into one HLS player.
/// No media, cookies, keys or download requests are persisted.
public actor MediaPreviewProxy {
    private enum Resource {
        case remote(URL, playlist: Bool)
        case playlist(String)
    }
    private let scope = UUID().uuidString
    private let queue = DispatchQueue(label: "com.siftx.preview.network", qos: .userInitiated)
    private let session: URLSession
    private var listener: NWListener?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var port: UInt16?
    private var headers: [String: String] = [:]
    private var resources: [String: Resource] = [:]
    private var remotePaths: [String: String] = [:]
    private var connections: [UUID: NWConnection] = [:]
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: PreviewRedirectDelegate(), delegateQueue: nil)
    }

    public func start(candidate: MediaCandidate) async throws -> URL {
        try URLSafety.validate(candidate.sourceURL)
        guard !stopped, listener == nil, candidate.protection == nil else { throw CancellationError() }
        headers = URLSafety.requestHeaders(candidate.headers)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        let listeningPort = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    let value = listener?.port?.rawValue
                    Task { await self?.listenerChanged(state, port: value) }
                }
                listener.start(queue: queue)
            }
        } onCancel: {
            Task { await self.stop() }
        }
        port = listeningPort
        do {
            try Task.checkCancellation()
            let url: URL
            switch candidate.transport {
            case .direct:
                url = try route(candidate.sourceURL)
            case .hls:
                let video = try route(candidate.sourceURL, playlist: true)
                let audio = try candidate.audioURL.map { try route($0, playlist: true) }
                url = try master(video: video, audio: audio, candidate: candidate)
            case .dash:
                url = try await dash(candidate)
            case .youtube, .bilibili:
                throw MediaError.unsupported("请使用网页播放器预览此视频。")
            }
            guard !stopped else { throw CancellationError() }
            return url
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        ready?.resume(throwing: CancellationError()); ready = nil
        listener?.cancel(); listener = nil
        workers.values.forEach { $0.cancel() }; workers.removeAll()
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        session.invalidateAndCancel()
        resources.removeAll(); remotePaths.removeAll(); headers.removeAll()
    }

    private func listenerChanged(_ state: NWListener.State, port: UInt16?) {
        switch state {
        case .ready:
            if let port { ready?.resume(returning: port); ready = nil }
        case .failed(let error):
            ready?.resume(throwing: error); ready = nil
            stop()
        case .cancelled:
            ready?.resume(throwing: CancellationError()); ready = nil
        default: break
        }
    }

    private func route(_ url: URL, playlist: Bool = false, identity: String = "") throws -> URL {
        try URLSafety.validate(url)
        let key = url.absoluteString + (playlist ? "|playlist" : "") + "|" + identity
        if let path = remotePaths[key] { return try localURL(path) }
        guard resources.count < 50_000 else { throw MediaError.resourceTooLarge }
        let ext = playlist ? "m3u8" : (["mp4", "m4a", "mp3", "mov", "aac", "ts", "m4s"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "media")
        let path = "/\(scope)/\(UUID().uuidString).\(ext)"
        resources[path] = .remote(url, playlist: playlist)
        remotePaths[key] = path
        return try localURL(path)
    }

    private func inline(_ text: String) throws -> URL {
        let path = "/\(scope)/\(UUID().uuidString).m3u8"
        resources[path] = .playlist(text)
        return try localURL(path)
    }

    private func localURL(_ path: String) throws -> URL {
        guard let port, !stopped, let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { throw CancellationError() }
        return url
    }

    private func master(video: URL, audio: URL?, candidate: MediaCandidate) throws -> URL {
        // Exactly one variant: the preview cannot silently switch to another quality.
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n"
        if let audio {
            text += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"sound\",NAME=\"原始音轨\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(audio.absoluteString)\"\n"
        }
        text += "#EXT-X-STREAM-INF:BANDWIDTH=\(max(1, candidate.bitrate ?? 2_000_000))"
        if let width = candidate.width, let height = candidate.height, width > 0, height > 0 {
            text += ",RESOLUTION=\(width)x\(height)"
        }
        if audio != nil { text += ",AUDIO=\"sound\"" }
        text += "\n\(video.absoluteString)\n"
        return try inline(text)
    }

    private func dash(_ candidate: MediaCandidate) async throws -> URL {
        let (data, response) = try await smallResource(candidate.sourceURL)
        guard let text = String(data: data, encoding: .utf8) else { throw MediaError.malformedManifest("invalid DASH encoding") }
        let manifest = try DASHParser.parse(text, baseURL: response.url ?? candidate.sourceURL)
        guard !manifest.isProtected, !manifest.isLive else { throw MediaError.protectedMedia }
        let representation = manifest.representations.first {
            MediaIdentity.stableID(sessionID: candidate.sessionID, url: candidate.sourceURL, variant: $0.id) == candidate.id
        } ?? manifest.representations.first {
            $0.kind == candidate.kind && $0.width == candidate.width && $0.height == candidate.height && $0.bitrate == candidate.bitrate
        }
        guard let representation else { throw MediaError.unsupported("所选画质已变更，请刷新媒体列表后重试。") }
        if representation.initializationSegment == nil, representation.segments.count == 1, candidate.kind == .audio || !candidate.hasAudio {
            return try route(representation.segments[0].url)
        }
        let video = try dashPlaylist(representation)
        let sound = candidate.kind == .video ? manifest.representations.filter { $0.kind == .audio }.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) } : nil
        return try master(video: video, audio: try sound.map(dashPlaylist), candidate: candidate)
    }

    private func dashPlaylist(_ representation: DASHRepresentation) throws -> URL {
        guard let initialization = representation.initializationSegment else {
            throw MediaError.unsupported("此 DASH 文件需要在原网页播放器中预览。")
        }
        let media = Array(representation.segments.dropFirst())
        let durations = representation.segmentDurations
        guard media.count == durations.count, !durations.isEmpty,
              durations.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 86_400 }) else {
            throw MediaError.unsupported("此 DASH 文件缺少预览所需的分片时间，请在原网页预览。")
        }
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(ceil(durations.max()!)))\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n"
        let initURL = try route(initialization.url)
        text += "#EXT-X-MAP:URI=\"\(initURL.absoluteString)\""
        if let range = hlsRange(initialization.byteRange) { text += ",BYTERANGE=\"\(range)\"" }
        text += "\n"
        for (segment, duration) in zip(media, durations) {
            text += "#EXTINF:\(duration),\n"
            if let range = hlsRange(segment.byteRange) { text += "#EXT-X-BYTERANGE:\(range)\n" }
            text += try route(segment.url).absoluteString + "\n"
        }
        text += "#EXT-X-ENDLIST\n"
        return try inline(text)
    }

    private func hlsRange(_ value: String?) -> String? {
        guard let value, value.hasPrefix("bytes=") else { return nil }
        let bounds = value.dropFirst(6).split(separator: "-")
        guard bounds.count == 2, let low = Int64(bounds[0]), let high = Int64(bounds[1]), low >= 0, high >= low, high < Int64.max else { return nil }
        return "\(high - low + 1)@\(low)"
    }

    private func rewrite(_ text: String, baseURL: URL) throws -> String {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { throw MediaError.malformedManifest("invalid HLS preview") }
        let expression = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        var variant = false
        return try text.components(separatedBy: .newlines).enumerated().map { index, raw in
            var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, !line.hasPrefix("#") {
                let url = try URLSafety.resolve(line, against: baseURL)
                line = try route(url, playlist: variant || url.pathExtension.lowercased() == "m3u8").absoluteString
                variant = false
            } else {
                let playlist = line.hasPrefix("#EXT-X-MEDIA:") || line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
                for match in expression.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                    guard let range = Range(match.range(at: 1), in: line) else { continue }
                    let url = try URLSafety.resolve(String(line[range]), against: baseURL)
                    // A later EXT-X-KEY may rotate the key at the same source URL.
                    let keyScope = line.hasPrefix("#EXT-X-KEY:") ? baseURL.absoluteString + "|\(index)" : ""
                    let replacement = try route(url, playlist: playlist, identity: keyScope).absoluteString
                    line.replaceSubrange(range, with: replacement)
                }
                if line.hasPrefix("#EXT-X-STREAM-INF:") { variant = true }
            }
            return line
        }.joined(separator: "\n")
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        workers[id] = Task { [weak self] in
            guard let self else { connection.cancel(); return }
            await self.serve(connection)
            await self.finished(id)
        }
    }

    private func finished(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
        workers.removeValue(forKey: id)
    }

    private func serve(_ connection: NWConnection) async {
        do {
            var requestData = Data()
            while requestData.range(of: Data("\r\n\r\n".utf8)) == nil {
                let data = try await receive(connection)
                guard !data.isEmpty, requestData.count + data.count <= 16_384 else { throw MediaError.invalidURL }
                requestData.append(data)
            }
            guard let text = String(data: requestData, encoding: .utf8) else { throw MediaError.invalidURL }
            let lines = text.components(separatedBy: "\r\n")
            let first = lines[0].split(separator: " ")
            guard first.count == 3, ["GET", "HEAD"].contains(String(first[0])) else {
                try await sendResponse(connection, status: 405); return
            }
            guard let resource = resources[String(first[1])], !stopped else {
                try await sendResponse(connection, status: 404); return
            }
            let head = first[0] == "HEAD"
            let range = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("range:") }).map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            switch resource {
            case .playlist(let text):
                try await sendPlaylist(connection, text: text, head: head)
            case .remote(let url, let playlist):
                if playlist {
                    let (data, response) = try await smallResource(url)
                    guard let text = String(data: data, encoding: .utf8) else { throw MediaError.malformedManifest("invalid playlist encoding") }
                    try await sendPlaylist(connection, text: rewrite(text, baseURL: response.url ?? url), head: head)
                } else {
                    var request = sourceRequest(url)
                    request.httpMethod = head ? "HEAD" : "GET"
                    if let range {
                        guard range.range(of: #"^bytes=(\d+-\d*|-\d+)$"#, options: .regularExpression) != nil else {
                            try await sendResponse(connection, status: 416); return
                        }
                        request.setValue(range, forHTTPHeaderField: "Range")
                    }
                    let (bytes, response) = try await session.bytes(for: request)
                    defer { bytes.task.cancel() }
                    guard let response = response as? HTTPURLResponse else { throw MediaError.invalidURL }
                    let type = response.mimeType?.lowercased() ?? ""
                    guard !type.contains("text/html"), !type.contains("json") else { throw MediaError.unsupported("媒体链接返回了网页。") }
                    var fields: [String: String] = [:]
                    for name in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] {
                        if let value = response.value(forHTTPHeaderField: name), !value.contains("\r"), !value.contains("\n") { fields[name] = value }
                    }
                    try await sendResponse(connection, status: response.statusCode, fields: fields)
                    if !head {
                        var chunk = Data(); chunk.reserveCapacity(65_536)
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            chunk.append(byte)
                            if chunk.count == 65_536 { try await send(connection, chunk); chunk.removeAll(keepingCapacity: true) }
                        }
                        if !chunk.isEmpty { try await send(connection, chunk) }
                    }
                }
            }
        } catch {
            // An incomplete stream fails normally in AVPlayer. Do not append another
            // HTTP response after headers/body were already sent.
            connection.cancel()
        }
    }

    private func sourceRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return request
    }

    private func smallResource(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: sourceRequest(url))
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw MediaError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 502)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4_194_304 else { throw MediaError.resourceTooLarge }
            data.append(byte)
        }
        return (data, response)
    }

    private func sendPlaylist(_ connection: NWConnection, text: String, head: Bool) async throws {
        let data = Data(text.utf8)
        try await sendResponse(connection, status: 200, fields: ["Content-Type": "application/vnd.apple.mpegurl", "Content-Length": String(data.count)])
        if !head { try await send(connection, data) }
    }

    private func sendResponse(_ connection: NWConnection, status: Int, fields: [String: String] = [:]) async throws {
        var text = "HTTP/1.1 \(status) Response\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (key, value) in fields { text += "\(key): \(value)\r\n" }
        if fields["Content-Length"] == nil, fields.isEmpty { text += "Content-Length: 0\r\n" }
        text += "\r\n"
        try await send(connection, Data(text.utf8))
    }

    private func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}

private final class PreviewRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? URLSafety.validate(url)) != nil else { completionHandler(nil); return }
        var next = request
        if url.host?.lowercased() != response.url?.host?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Cookie"); next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}
