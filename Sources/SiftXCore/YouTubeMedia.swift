import Foundation

/// Persist the watch URL and format identities, never an expiring CDN URL.
public struct YouTubeFormatSelection: Codable, Hashable, Sendable {
    public var mediaFormatID: String
    public var audioFormatID: String?
    public init(mediaFormatID: String, audioFormatID: String? = nil) {
        self.mediaFormatID = mediaFormatID; self.audioFormatID = audioFormatID
    }
}

public enum YouTubeURL {
    public static func isYouTubeHost(_ url: URL) -> Bool {
        ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(url.host?.lowercased() ?? "")
    }

    public static func canonical(_ url: URL) -> URL? {
        guard (try? URLSafety.validate(url)) != nil, isYouTubeHost(url), url.port == nil || [80, 443].contains(url.port!) else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        let host = url.host!.lowercased()
        let id: String?
        if ["youtu.be", "www.youtu.be"].contains(host), path.count == 1 { id = path.first }
        else if path.count == 2, ["shorts", "embed", "live"].contains(path[0]) { id = path[1] }
        else if path == ["watch"], !host.contains("nocookie") {
            let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "v" } ?? []
            id = values.count == 1 ? values[0].value : nil
        } else { id = nil }
        guard let id, id.utf8.count == 11, id.unicodeScalars.allSatisfy({
            (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value) || $0 == "_" || $0 == "-"
        }) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    /// Safari can offer a useful action before large site-specific extraction runs in the app.
    public static func pageCandidates(url: URL, title: String, sessionID: String, protected: Bool = false) -> [MediaCandidate] {
        guard let watch = canonical(url) else { return [] }
        let videoID = URLComponents(url: watch, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
        let thumbnail = URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
        return [MediaKind.video, .audio].map { kind in
            MediaCandidate(id: MediaIdentity.stableID(sessionID: sessionID, url: watch, variant: "youtube-\(kind.rawValue)"),
                           sessionID: sessionID, title: title, pageTitle: title, pageURL: url, sourceURL: watch,
                           kind: kind, transport: .youtube, quality: kind == .video ? "自动清晰度" : "仅音频",
                           protection: protected ? MediaError.protectedMedia.localizedDescription : nil,
                           thumbnailURL: kind == .video ? thumbnail : nil)
        }
    }
}

public enum YouTubeMedia {
    private struct Info: Decodable {
        var id: String
        var title: String?
        var duration: Double?
        var thumbnail: String?
        var is_live: Bool?
        var live_status: String?
        var _type: String?
        var formats: [Format]?
    }
    private struct Format: Decodable {
        var format_id: String
        var ext: String?
        var protocolName: String?
        var vcodec: String?
        var acodec: String?
        var width: Int?
        var height: Int?
        var fps: Double?
        var tbr: Double?
        var abr: Double?
        var filesize: Int64?
        var filesize_approx: Int64?
        var has_drm: Bool?
        enum CodingKeys: String, CodingKey {
            case format_id, ext, vcodec, acodec, width, height, fps, tbr, abr, filesize, filesize_approx, has_drm
            case protocolName = "protocol"
        }
        var supported: Bool {
            has_drm != true && Self.validID(format_id) && ["https", "http", "m3u8_native", "http_dash_segments"].contains(protocolName ?? "")
        }
        var audio: Bool { acodec?.hasPrefix("mp4a") == true || acodec == "aac" }
        var video: Bool { vcodec?.hasPrefix("avc1") == true || vcodec == "h264" }
        var bytes: Int64? {
            let value = filesize ?? filesize_approx
            return value.flatMap { $0 > 0 ? $0 : nil }
        }
        static func validID(_ value: String) -> Bool {
            !value.isEmpty && value.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    public static func choices(data: Data, base: MediaCandidate) throws -> [MediaCandidate] {
        guard data.count <= 8_388_608 else { throw MediaError.resourceTooLarge }
        guard let watch = YouTubeURL.canonical(base.sourceURL) else { throw MediaError.invalidURL }
        let info = try JSONDecoder().decode(Info.self, from: data)
        guard watch.absoluteString.hasSuffix("v=\(info.id)"), info._type == nil || info._type == "video" else {
            throw MediaError.unsupported("请添加单个 YouTube 视频链接。")
        }
        guard info.is_live != true, !["is_live", "is_upcoming", "post_live"].contains(info.live_status ?? "") else {
            throw MediaError.unsupported("请等待 YouTube 直播结束并完成处理后再下载。")
        }
        let all = Array((info.formats ?? []).prefix(1000))
        let supported = all.filter(\.supported)
        let audios = supported.filter { $0.ext == "m4a" && $0.vcodec == "none" && $0.audio }
        let audio = audios.max { ($0.abr ?? $0.tbr ?? 0) < ($1.abr ?? $1.tbr ?? 0) }
        let videos = supported.filter {
            $0.ext == "mp4" && $0.video && ($0.audio || (($0.acodec == nil || $0.acodec == "none") && audio != nil))
                && (1...32768).contains($0.height ?? 0) && (1...32768).contains($0.width ?? 0)
        }.sorted {
            ($0.height ?? 0, $0.fps ?? 0, $0.tbr ?? 0) > ($1.height ?? 0, $1.fps ?? 0, $1.tbr ?? 0)
        }
        var sizes = Set<String>()
        var choices = videos.filter { sizes.insert("\($0.width ?? 0)x\($0.height ?? 0)").inserted }.prefix(20).map { format in
            makeCandidate(format: format, audio: format.audio ? nil : audio, kind: .video, info: info, base: base, watch: watch)
        }
        if let audio { choices.append(makeCandidate(format: audio, audio: nil, kind: .audio, info: info, base: base, watch: watch)) }
        guard !choices.isEmpty else {
            if all.contains(where: { $0.has_drm == true }) { throw MediaError.protectedMedia }
            throw MediaError.unsupported("YouTube 暂未提供可下载的 MP4 视频或 M4A 音频。请稍后重新读取。")
        }
        return choices
    }

    private static func makeCandidate(format: Format, audio: Format?, kind: MediaKind, info: Info, base: MediaCandidate, watch: URL) -> MediaCandidate {
        var choice = base
        choice.sourceURL = watch; choice.transport = .youtube; choice.kind = kind
        choice.title = base.title.isEmpty ? String((info.title ?? "YouTube 视频").prefix(500)) : base.title
        choice.pageTitle = String((info.title ?? base.pageTitle).prefix(500))
        choice.id = MediaIdentity.stableID(sessionID: base.sessionID, url: watch, variant: format.format_id + "+" + (audio?.format_id ?? ""))
        choice.youtubeFormat = YouTubeFormatSelection(mediaFormatID: format.format_id, audioFormatID: audio?.format_id)
        choice.quality = kind == .video ? "\(format.height ?? 0)p" : "仅音频 · M4A"
        choice.width = kind == .video ? format.width : nil; choice.height = kind == .video ? format.height : nil
        choice.hasAudio = true; choice.audioURL = nil; choice.headers = [:]; choice.plan = nil
        choice.estimatedBytes = format.bytes
        if let audio {
            if let videoBytes = format.bytes, let audioBytes = audio.bytes {
                let total = videoBytes.addingReportingOverflow(audioBytes)
                choice.estimatedBytes = total.overflow ? nil : total.partialValue
            } else { choice.estimatedBytes = nil }
        }
        choice.duration = info.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let thumbnail = info.thumbnail, let url = URL(string: thumbnail), (try? URLSafety.validate(url)) != nil { choice.thumbnailURL = url }
        return choice
    }
}
