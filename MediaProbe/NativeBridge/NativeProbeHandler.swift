import Foundation
import AppKit
import SafariServices
import os
import SiftXCore

/// The Web Extension's native boundary accepts only small, typed media observations.
/// Browser cookies and authorization headers never cross this boundary or enter storage.
final class NativeProbeHandler: NSObject, NSExtensionRequestHandling {
    private static let ingestion = ProbeIngestion()

    func beginRequest(with context: NSExtensionContext) {
        let reply = NativeReply(context)
        guard let item = context.inputItems.first as? NSExtensionItem,
              let raw = item.userInfo?[SFExtensionMessageKey] as? [String: Any] else {
            reply.complete(["ok": false, "error": "invalid-message"])
            return
        }
        if raw["type"] as? String == "open-app" {
            Task { @MainActor in
                let opened = NSWorkspace.shared.open(URL(string: "siftx://downloads")!)
                reply.complete(["ok": opened])
            }
            return
        }
        guard let request = ProbeRequest(raw) else {
            reply.complete(["ok": false, "error": "invalid-message"])
            return
        }
        let ingestion = Self.ingestion
        Task.detached { [request, reply, ingestion] in
            do {
                let count = try await ingestion.handle(request)
                reply.complete(["ok": true, "count": count])
            } catch {
                // URLs can contain private tokens, so no request details are logged.
                Logger(subsystem: SiftXConfiguration.appBundleID, category: "Probe").error("Could not persist media observations.")
                reply.complete(["ok": false, "error": error.localizedDescription])
            }
        }
    }

}

/// NSExtensionContext supports asynchronous completion but lacks Sendable annotations.
/// One immutable reply holder owns the context and completes this request exactly once.
private final class NativeReply: @unchecked Sendable {
    private let context: NSExtensionContext
    init(_ context: NSExtensionContext) { self.context = context }
    func complete(_ response: [String: Any]) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}

private struct ProbeRequest: Sendable {
    enum Operation: String { case upsert, remove, prune }
    var operation: Operation
    var sessionID: String
    var pageURL: URL?
    var title: String
    var resources: [ProbeResource]
    var notices: Set<String>
    var privateBrowsing: Bool
    var forceReanalysis: Bool

    init?(_ raw: [String: Any]) {
        guard let name = raw["type"] as? String, let operation = Operation(rawValue: name) else { return nil }
        self.operation = operation
        forceReanalysis = raw["forceReanalysis"] as? Bool ?? false
        if operation == .prune {
            sessionID = ""; pageURL = nil; title = ""; resources = []; notices = []; privateBrowsing = false
            return
        }
        guard let id = raw["sessionID"] as? String, UUID(uuidString: id) != nil, id.count == 36 else { return nil }
        sessionID = id
        title = String((raw["title"] as? String ?? "").prefix(500))
        privateBrowsing = raw["privateBrowsing"] as? Bool ?? false
        notices = Set((raw["notices"] as? [String] ?? []).prefix(2).filter { ["blob", "protected"].contains($0) })
        resources = (raw["resources"] as? [[String: Any]] ?? []).prefix(64).compactMap(ProbeResource.init)
        if operation == .upsert {
            guard let text = raw["pageURL"] as? String, let url = URL(string: text), (try? URLSafety.validate(url)) != nil else { return nil }
            pageURL = url
        } else { pageURL = nil }
    }
}

private struct ProbeResource: Sendable {
    var url: URL
    var kind: MediaKind
    var transport: MediaTransport
    var title: String
    var width: Int?
    var height: Int?
    var bytes: Int64?
    var thumbnail: URL?
    var protected: Bool

    init?(_ raw: [String: Any]) {
        guard let text = raw["url"] as? String, let url = URL(string: text), (try? URLSafety.validate(url)) != nil else { return nil }
        let mime = String((raw["mime"] as? String ?? "").prefix(128))
        let classification: (MediaKind, MediaTransport)
        if let known = URLSafety.classify(url, mimeType: mime) { classification = known }
        else if raw["explicit"] as? Bool == true,
                !["ts", "m4s", "cmfv", "cmfa", "vtt", "srt", "key"].contains(url.pathExtension.lowercased()),
                !["video/mp2t", "video/iso.segment", "audio/iso.segment"].contains(mime.lowercased()),
                let kind = MediaKind(rawValue: raw["kind"] as? String ?? "") { classification = (kind, .direct) }
        else { return nil }
        self.url = url; kind = classification.0; transport = classification.1
        title = String((raw["title"] as? String ?? "").prefix(500))
        func dimension(_ name: String) -> Int? {
            guard let value = raw[name] as? Int, (1...32768).contains(value) else { return nil }
            return value
        }
        width = dimension("width"); height = dimension("height")
        if let value = raw["bytes"] as? Int64, value > 0 { bytes = value } else { bytes = nil }
        if let value = raw["thumbnail"] as? String, let url = URL(string: value), (try? URLSafety.validate(url)) != nil { thumbnail = url } else { thumbnail = nil }
        protected = raw["protected"] as? Bool ?? false
    }
}

private actor ProbeIngestion {
    private let analyzer = MediaAnalyzer()
    private var generations: [String: Int] = [:]
    private var analyzed: [String: (date: Date, candidates: [MediaCandidate])] = [:]

    func handle(_ request: ProbeRequest) async throws -> Int {
        let store = try SharedStore()
        try store.prunePages()
        if request.operation == .prune {
            analyzed = analyzed.filter { Date().timeIntervalSince($0.value.date) < 120 }
            return 0
        }
        let generation = (generations[request.sessionID] ?? 0) + 1
        generations[request.sessionID] = generation
        if generations.count > 500 { generations = [request.sessionID: generation] }
        if request.operation == .remove || request.privateBrowsing {
            analyzed = analyzed.filter { !$0.key.hasPrefix(request.sessionID + "|") }
            try store.removePage(id: request.sessionID)
            return 0
        }
        guard let pageURL = request.pageURL else { return 0 }
        if YouTubeURL.canonical(pageURL) != nil {
            let choices = YouTubeURL.pageCandidates(url: pageURL, title: request.title, sessionID: request.sessionID,
                                                    protected: request.notices.contains("protected") || request.resources.contains(where: \.protected))
            try store.savePage(PageSession(id: request.sessionID, pageURL: pageURL, title: request.title, candidates: choices))
            return choices.filter { $0.protection == nil }.count
        }
        if request.forceReanalysis {
            analyzed = analyzed.filter { !$0.key.hasPrefix(request.sessionID + "|") }
            await analyzer.clearCache()
        }
        // Reanalysis must not replace available choices with temporary protected
        // placeholders; publish the refreshed result atomically when it is ready.
        if (try store.page(id: request.sessionID))?.candidates.isEmpty != false,
           request.resources.contains(where: { $0.transport != .direct && analyzed[request.sessionID + "|" + $0.url.absoluteString] == nil }) {
            let initial = request.resources.map { resource in
                MediaCandidate(id: MediaIdentity.stableID(sessionID: request.sessionID, url: resource.url), sessionID: request.sessionID, title: resource.title.isEmpty ? request.title : resource.title, pageTitle: request.title, pageURL: pageURL, sourceURL: resource.url, kind: resource.kind, transport: resource.transport, width: resource.width, height: resource.height, estimatedBytes: resource.transport == .direct ? resource.bytes : nil, protection: resource.protected ? MediaError.protectedMedia.localizedDescription : resource.transport == .direct ? nil : "正在分析媒体…", headers: ["Referer": pageURL.absoluteString])
            }
            try store.savePage(PageSession(id: request.sessionID, pageURL: pageURL, title: request.title, candidates: initial))
        }
        var candidates: [MediaCandidate] = []
        for resource in request.resources {
            let base = MediaCandidate(
                id: MediaIdentity.stableID(sessionID: request.sessionID, url: resource.url),
                sessionID: request.sessionID, title: resource.title.isEmpty ? request.title : resource.title,
                pageTitle: request.title, pageURL: pageURL, sourceURL: resource.url,
                kind: resource.kind, transport: resource.transport,
                quality: resource.height.map { "\($0)p" }, width: resource.width, height: resource.height,
                estimatedBytes: resource.transport == .direct ? resource.bytes : nil, hasAudio: resource.kind == .audio || resource.transport == .direct,
                protection: resource.protected ? MediaError.protectedMedia.localizedDescription : nil,
                headers: ["Referer": pageURL.absoluteString], thumbnailURL: resource.thumbnail
            )
            if resource.transport == .direct || resource.protected {
                candidates.append(base)
                continue
            }
            let key = request.sessionID + "|" + resource.url.absoluteString
            if let cache = analyzed[key], Date().timeIntervalSince(cache.date) < 120 {
                candidates.append(contentsOf: cache.candidates)
                continue
            }
            do {
                let choices = try await analyzer.candidates(for: base).map { candidate in
                    var choice = candidate
                    // Download plans are re-resolved by the app; the probe caches only choices.
                    choice.plan = nil
                    return choice
                }
                guard generations[request.sessionID] == generation else { return 0 }
                analyzed[key] = (Date(), choices)
                if analyzed.count > 100 { analyzed = analyzed.filter { Date().timeIntervalSince($0.value.date) < 60 } }
                while analyzed.count > 100 {
                    guard let oldest = analyzed.min(by: { $0.value.date < $1.value.date })?.key else { break }
                    analyzed.removeValue(forKey: oldest)
                }
                candidates.append(contentsOf: choices)
            } catch {
                var failed = base
                failed.protection = "暂时无法分析此媒体。\(error.localizedDescription)"
                candidates.append(failed)
            }
        }
        if request.notices.contains("protected"), !candidates.contains(where: { $0.protection != nil }) {
            candidates.append(notice(request, pageURL: pageURL, key: "protected", text: MediaError.protectedMedia.localizedDescription))
        }
        if request.notices.contains("blob"), candidates.isEmpty {
            candidates.append(notice(request, pageURL: pageURL, key: "blob", text: "此网页使用浏览器内存媒体。请播放视频以发现原始媒体资源；内存地址无法直接下载。"))
        }
        // Prefer an analyzed master quality to its separately observed variant playlist.
        candidates.sort {
            let left = ($0.height ?? 0, $0.audioURL == nil ? 0 : 1, $0.bitrate ?? 0)
            let right = ($1.height ?? 0, $1.audioURL == nil ? 0 : 1, $1.bitrate ?? 0)
            return left > right
        }
        var hls = Set<String>()
        candidates = candidates.filter { candidate in
            guard candidate.transport == .hls else { return true }
            return hls.insert(candidate.sourceURL.absoluteString).inserted
        }
        candidates = MediaIdentity.deduplicated(candidates)
        guard generations[request.sessionID] == generation else { return 0 }
        try store.savePage(PageSession(id: request.sessionID, pageURL: pageURL, title: request.title, candidates: candidates))
        return candidates.filter { $0.protection == nil }.count
    }

    private func notice(_ request: ProbeRequest, pageURL: URL, key: String, text: String) -> MediaCandidate {
        MediaCandidate(id: MediaIdentity.stableID(sessionID: request.sessionID, url: pageURL, variant: key), sessionID: request.sessionID, title: request.title, pageTitle: request.title, pageURL: pageURL, sourceURL: pageURL, protection: text)
    }
}
