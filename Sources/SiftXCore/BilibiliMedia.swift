import Foundation

public enum BilibiliURL {
    public static func isBilibiliHost(_ url: URL) -> Bool {
        ["bilibili.com", "www.bilibili.com", "m.bilibili.com"].contains(url.host?.lowercased() ?? "")
    }

    /// Keep the selected part while removing tracking and expiring media addresses.
    public static func canonical(_ url: URL) -> URL? {
        guard (try? URLSafety.validate(url)) != nil, isBilibiliHost(url),
              url.port == nil || [80, 443].contains(url.port!) else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        guard path.count == 2, path[0] == "video" else { return nil }
        let id = path[1]
        let asciiID = id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let validBV = id.hasPrefix("BV") && id.utf8.count == 12 && asciiID
        let validAV = id.hasPrefix("av") && (3...22).contains(id.count)
            && id.dropFirst(2).allSatisfy { $0.isASCII && $0.isNumber }
            && id.dropFirst(2).contains(where: { $0 != "0" })
        guard validBV || validAV else { return nil }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "p" } ?? []
        guard parts.count <= 1 else { return nil }
        var part = 1
        if let value = parts.first?.value {
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(value), (1...10_000).contains(number) else { return nil }
            part = number
        } else if !parts.isEmpty { return nil }
        return URL(string: "https://www.bilibili.com/video/\(id)/" + (part == 1 ? "" : "?p=\(part)"))
    }

    public static func pageCandidates(url: URL, title: String, sessionID: String, protected: Bool = false) -> [MediaCandidate] {
        guard let video = canonical(url) else { return [] }
        return [MediaKind.video, .audio].map { kind in
            MediaCandidate(id: MediaIdentity.stableID(sessionID: sessionID, url: video, variant: "bilibili-\(kind.rawValue)"),
                           sessionID: sessionID, title: title, pageTitle: title, pageURL: url, sourceURL: video,
                           kind: kind, transport: .bilibili, quality: kind == .video ? "自动清晰度" : "仅音频",
                           protection: protected ? MediaError.protectedMedia.localizedDescription : nil)
        }
    }

    public static func previewURL(_ url: URL) -> URL? {
        guard let video = canonical(url) else { return nil }
        let id = video.path.split(separator: "/").last!
        let key = id.hasPrefix("BV") ? "bvid" : "aid"
        let value = id.hasPrefix("BV") ? String(id) : String(id.dropFirst(2))
        let part = URLComponents(url: video, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? "1"
        return URL(string: "https://player.bilibili.com/player.html?\(key)=\(value)&page=\(part)&autoplay=1")
    }
}

public enum BilibiliMedia {
    public static func choices(data: Data, base: MediaCandidate) throws -> [MediaCandidate] {
        try ExtractedMedia.choices(data: data, base: base, transport: .bilibili)
    }
}
