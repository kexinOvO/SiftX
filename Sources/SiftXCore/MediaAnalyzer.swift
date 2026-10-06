import Foundation
import CryptoKit

public actor MediaAnalyzer {
    private struct Document: Sendable { var text: String; var url: URL; var receivedAt: Date }
    private var cache: [String: Document] = [:]
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }
    /// Allows a caller to supply an isolated native networking session for tests or custom policy.
    public init(session: URLSession) { self.session = session }

    public func candidates(for candidate: MediaCandidate) async throws -> [MediaCandidate] {
        try URLSafety.validate(candidate.sourceURL)
        if candidate.transport == .youtube { throw MediaError.unsupported("请在 SiftX 应用中读取 YouTube 视频信息。") }
        if candidate.protection != nil || candidate.transport == .direct { return [candidate] }
        var candidate = candidate
        // The observed Content-Length is the manifest size, not the media size.
        candidate.estimatedBytes = nil; candidate.duration = nil; candidate.encryption = nil
        let document = try await fetch(candidate.sourceURL, headers: candidate.headers)
        switch candidate.transport {
        case .youtube: throw MediaError.unsupported("请在 SiftX 应用中读取 YouTube 视频信息。")
        case .direct: return [candidate]
        case .hls:
            let manifest = try HLSParser.parse(document.text, baseURL: document.url)
            if manifest.isProtected { return [protected(candidate, reason: MediaError.protectedMedia.localizedDescription)] }
            if manifest.variants.isEmpty {
                if manifest.isLive { return [protected(candidate, reason: "直播媒体暂不支持下载，请等待节目结束。") ] }
                var choice = candidate
                choice.id = MediaIdentity.stableID(sessionID: choice.sessionID, url: choice.sourceURL)
                choice.duration = manifest.duration
                choice.encryption = manifest.hasAES128Encryption ? .aes128 : nil
                if manifest.duration > 0, let bitrate = candidate.bitrate {
                    choice.estimatedBytes = estimateBytes(bitrate: bitrate, seconds: manifest.duration)
                }
                return [choice]
            }
            var output: [MediaCandidate] = []
            let variants = manifest.variants.sorted { ($0.height ?? 0, $0.bitrate ?? 0) > ($1.height ?? 0, $1.bitrate ?? 0) }
            for variant in variants.prefix(24) {
                var choice = candidate
                choice.sourceURL = variant.url
                choice.id = MediaIdentity.stableID(sessionID: choice.sessionID, url: variant.url)
                choice.width = variant.width; choice.height = variant.height; choice.bitrate = variant.bitrate
                choice.kind = variant.isAudioOnly ? .audio : .video
                choice.quality = variant.height.map { "\($0)p" } ?? (variant.isAudioOnly ? "仅音频" : candidate.quality)
                let renditions = manifest.audio.filter { $0.group == variant.audioGroup }
                choice.audioURL = renditions.first(where: \.isDefault)?.url ?? renditions.first?.url
                choice.hasAudio = variant.isAudioOnly || choice.audioURL != nil || variant.codecs.map { $0.contains("mp4a") || $0.contains("ac-3") || $0.contains("ec-3") || $0.contains("opus") } ?? candidate.hasAudio
                let child = try await inspectHLS(variant.url, headers: candidate.headers)
                choice.duration = child.duration
                choice.encryption = child.hasAES128Encryption ? .aes128 : nil
                if child.isProtected { choice.protection = MediaError.protectedMedia.localizedDescription }
                else if !child.variants.isEmpty { choice.protection = "此媒体包含多级质量信息，请重新播放后选择最终媒体。" }
                else if child.isLive { choice.protection = "直播媒体暂不支持下载，请等待节目结束。" }
                else if let bitrate = choice.bitrate { choice.estimatedBytes = estimateBytes(bitrate: bitrate, seconds: child.duration) }
                if let audio = choice.audioURL {
                    let childAudio = try await inspectHLS(audio, headers: candidate.headers)
                    if childAudio.hasAES128Encryption { choice.encryption = .aes128 }
                    if childAudio.isProtected { choice.protection = MediaError.protectedMedia.localizedDescription }
                    else if childAudio.isLive { choice.protection = "直播媒体暂不支持下载，请等待节目结束。" }
                }
                output.append(choice)
            }
            var audioSeen = Set<URL>()
            for rendition in manifest.audio where audioSeen.insert(rendition.url).inserted {
                var choice = candidate
                choice.sourceURL = rendition.url; choice.audioURL = nil
                choice.id = MediaIdentity.stableID(sessionID: choice.sessionID, url: rendition.url)
                choice.kind = .audio; choice.hasAudio = true; choice.quality = "仅音频"
                choice.width = nil; choice.height = nil; choice.bitrate = nil; choice.estimatedBytes = nil
                let child = try await inspectHLS(rendition.url, headers: candidate.headers)
                choice.duration = child.duration
                choice.encryption = child.hasAES128Encryption ? .aes128 : nil
                if child.isProtected { choice.protection = MediaError.protectedMedia.localizedDescription }
                else if child.isLive { choice.protection = "直播媒体暂不支持下载，请等待节目结束。" }
                output.append(choice)
                if output.count >= 50 { break }
            }
            return MediaIdentity.deduplicated(output)
        case .dash:
            let manifest = try DASHParser.parse(document.text, baseURL: document.url)
            if manifest.isProtected { return [protected(candidate, reason: MediaError.protectedMedia.localizedDescription)] }
            if manifest.isLive { return [protected(candidate, reason: "直播 DASH 媒体暂不支持下载。") ] }
            return dashChoices(candidate: candidate, manifest: manifest)
        }
    }

    public func plan(for candidate: MediaCandidate) async throws -> MediaPlan {
        try await resolvedPlan(for: candidate, visited: [], depth: 0)
    }
    private func resolvedPlan(for candidate: MediaCandidate, visited: Set<URL>, depth: Int) async throws -> MediaPlan {
        try URLSafety.validate(candidate.sourceURL)
        guard depth < 4, !visited.contains(candidate.sourceURL) else { throw MediaError.malformedManifest("playlist cycle or excessive nesting") }
        if let reason = candidate.protection { throw MediaError.unsupported(reason) }
        if let plan = candidate.plan {
            guard !plan.isLive else { throw MediaError.unsupported("直播媒体暂不支持下载。") }
            guard plan.segments.count <= SiftXConfiguration.maximumSegments, plan.audioSegments.count <= SiftXConfiguration.maximumSegments else { throw MediaError.resourceTooLarge }
            var budget = ManifestBudget()
            for segment in plan.segments + plan.audioSegments {
                try URLSafety.validate(segment.url); try budget.consume(segment.url)
                if let encryption = segment.encryption {
                    guard candidate.transport == .hls, encryption.iv.count == 16, encryption.keyID.utf8.count <= 512 else { throw MediaError.invalidEncryptionKey }
                    try URLSafety.validate(encryption.keyURL); try budget.consume(encryption.keyURL)
                }
            }
            return plan
        }
        switch candidate.transport {
        case .youtube: throw MediaError.unsupported("YouTube 视频由专用下载组件处理。")
        case .direct:
            let ext = candidate.sourceURL.pathExtension.lowercased()
            let known = Set(["mp4", "mov", "webm", "mkv", "m4v", "ogv", "m4a", "aac", "mp3", "wav", "flac", "ogg", "oga", "aiff", "opus"])
            return MediaPlan(segments: [MediaSegment(url: candidate.sourceURL)], outputExtension: known.contains(ext) ? ext : candidate.kind == .audio ? "m4a" : "mp4")
        case .hls:
            let manifest = try await inspectHLS(candidate.sourceURL, headers: candidate.headers)
            if manifest.isProtected { throw MediaError.protectedMedia }
            if !manifest.variants.isEmpty {
                let choices = try await candidates(for: candidate)
                guard let best = choices.first(where: { $0.kind == candidate.kind && $0.protection == nil }) else {
                    throw MediaError.unsupported(choices.first?.protection ?? "此媒体没有可下载的完整音视频。")
                }
                return try await resolvedPlan(for: best, visited: visited.union([candidate.sourceURL]), depth: depth + 1)
            }
            guard !manifest.isLive else { throw MediaError.unsupported("直播媒体暂不支持下载，请等待节目结束。") }
            var audio: [MediaSegment] = []
            if let audioURL = candidate.audioURL {
                let audioManifest = try await inspectHLS(audioURL, headers: candidate.headers)
                if audioManifest.isProtected { throw MediaError.protectedMedia }
                guard !audioManifest.isLive, audioManifest.variants.isEmpty else { throw MediaError.unsupported("此音频流不能作为完整媒体下载。") }
                audio = audioManifest.segments
            }
            return MediaPlan(segments: manifest.segments, audioSegments: audio, outputExtension: candidate.kind == .audio ? "m4a" : "mp4")
        case .dash:
            let document = try await fetch(candidate.sourceURL, headers: candidate.headers)
            let manifest = try DASHParser.parse(document.text, baseURL: document.url)
            if manifest.isProtected { throw MediaError.protectedMedia }
            guard !manifest.isLive else { throw MediaError.unsupported("直播 DASH 媒体暂不支持下载。") }
            let choices = dashChoices(candidate: candidate, manifest: manifest)
            guard let choice = choices.first(where: { $0.id == candidate.id }) ?? choices.first(where: { $0.kind == candidate.kind && $0.height == candidate.height && $0.bitrate == candidate.bitrate }) ?? choices.first(where: { $0.kind == candidate.kind }), let plan = choice.plan else { throw MediaError.malformedManifest("requested quality is no longer available") }
            return plan
        }
    }

    public func clearCache() { cache.removeAll() }
    private func inspectHLS(_ url: URL, headers: [String: String]) async throws -> HLSManifest {
        let document = try await fetch(url, headers: headers)
        let manifest = try HLSParser.parse(document.text, baseURL: document.url)
        // Nested masters are uncommon and can otherwise recurse indefinitely on hostile sites.
        return manifest
    }
    private func dashChoices(candidate: MediaCandidate, manifest: DASHManifest) -> [MediaCandidate] {
        let audio = manifest.representations.filter { $0.kind == .audio }.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
        return manifest.representations.sorted { ($0.kind == .video ? 1 : 0, $0.height ?? 0, $0.bitrate ?? 0) > ($1.kind == .video ? 1 : 0, $1.height ?? 0, $1.bitrate ?? 0) }.map { representation in
            var choice = candidate
            choice.id = MediaIdentity.stableID(sessionID: candidate.sessionID, url: candidate.sourceURL, variant: representation.id)
            choice.kind = representation.kind; choice.width = representation.width; choice.height = representation.height; choice.bitrate = representation.bitrate
            choice.quality = representation.height.map { "\($0)p" } ?? (representation.kind == .audio ? representation.bitrate.map { "\($0 / 1_000) kbps" } ?? "仅音频" : nil)
            choice.hasAudio = representation.kind == .audio || audio != nil
            choice.duration = manifest.duration
            let audioSegments = representation.kind == .video ? audio?.segments ?? [] : []
            choice.plan = MediaPlan(segments: representation.segments, audioSegments: audioSegments, outputExtension: representation.kind == .audio ? "m4a" : "mp4")
            if let seconds = manifest.duration, let bitrate = representation.bitrate {
                let combined = bitrate.addingReportingOverflow(representation.kind == .video ? audio?.bitrate ?? 0 : 0)
                if !combined.overflow { choice.estimatedBytes = estimateBytes(bitrate: combined.partialValue, seconds: seconds) }
            }
            return choice
        }
    }
    private func estimateBytes(bitrate: Int, seconds: Double) -> Int64? {
        let value = Double(bitrate) * seconds / 8
        return value.isFinite && value > 0 && value < Double(Int64.max) ? Int64(value) : nil
    }
    private func protected(_ candidate: MediaCandidate, reason: String) -> MediaCandidate { var copy = candidate; copy.protection = reason; return copy }

    private func fetch(_ url: URL, headers: [String: String]) async throws -> Document {
        try URLSafety.validate(url)
        let headerKey = headers.sorted(by: { $0.key < $1.key }).map { $0.key + ":" + $0.value }.joined(separator: "\n")
        let fingerprint = SHA256.hash(data: Data(headerKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = url.absoluteString + fingerprint
        if let cached = cache[key], Date().timeIntervalSince(cached.receivedAt) < 60 { return cached }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.apple.mpegurl, application/dash+xml, text/plain, */*", forHTTPHeaderField: "Accept")
        for (name, value) in URLSafety.requestHeaders(headers) { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw MediaError.invalidURL }
        guard (200..<300).contains(response.statusCode) else { throw MediaError.httpStatus(response.statusCode) }
        guard response.expectedContentLength <= 4_194_304 else { throw MediaError.resourceTooLarge }
        guard let effectiveURL = response.url else { throw MediaError.invalidURL }
        try URLSafety.validate(effectiveURL)
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            if data.count >= 4_194_304 { throw MediaError.resourceTooLarge }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw MediaError.malformedManifest("document is not UTF-8") }
        let document = Document(text: text, url: effectiveURL, receivedAt: Date())
        cache = cache.filter { Date().timeIntervalSince($0.value.receivedAt) < 60 }
        while cache.count >= 16 || cache.values.reduce(0, { $0 + $1.text.utf8.count }) + data.count > 16_777_216 {
            guard let oldest = cache.min(by: { $0.value.receivedAt < $1.value.receivedAt })?.key else { break }
            cache.removeValue(forKey: oldest)
        }
        cache[key] = document
        return document
    }
}
