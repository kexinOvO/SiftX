import Foundation

public enum MediaError: Error, LocalizedError, Sendable {
    case invalidURL
    case protectedMedia
    case invalidEncryptionKey
    case decryptionFailed
    case unsupported(String)
    case malformedManifest(String)
    case httpStatus(Int)
    case resourceTooLarge
    case storage(String)
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "媒体链接无效，或使用了不支持的协议。"
        case .protectedMedia: return "此媒体使用 DRM 或暂不支持的加密方式，无法下载。"
        case .invalidEncryptionKey: return "AES-128 密钥无效：需要服务器返回 16 字节的二进制密钥。请在 Safari 中重新播放后再试。"
        case .decryptionFailed: return "AES-128 分片解密失败，密钥或媒体可能已更新。请在 Safari 中重新播放并重新添加下载。"
        case .unsupported(let reason): return reason
        case .malformedManifest(let reason): return "无法解析媒体信息：\(reason)"
        case .httpStatus(let code):
            switch code {
            case 401, 403: return "无法访问媒体（HTTP \(code)）。请在 Safari 中重新播放后再试。"
            case 404, 410: return "媒体链接已失效（HTTP \(code)）。请刷新网页后重试。"
            case 429: return "网站暂时限制了请求次数，请稍后重试。"
            default: return "媒体服务器返回错误（HTTP \(code)）。"
            }
        case .resourceTooLarge: return "媒体信息超过安全大小限制。"
        case .storage(let reason): return "无法保存本地数据：\(reason)"
        }
    }
}

/// Includes expanded relative URLs, which can be much larger than the small manifest that describes them.
struct ManifestBudget {
    private var bytes = 0
    private var count = 0
    mutating func consume(_ url: URL) throws {
        bytes += url.absoluteString.utf8.count; count += 1
        guard bytes <= 33_554_432, count <= 50_000 else { throw MediaError.resourceTooLarge }
    }
}

public enum URLSafety {
    public static let maximumURLBytes = 16_384
    public static func validate(_ url: URL) throws {
        guard url.absoluteString.utf8.count <= maximumURLBytes,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              !url.absoluteString.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw MediaError.invalidURL }
    }
    public static func classify(_ url: URL, mimeType: String? = nil) -> (MediaKind, MediaTransport)? {
        guard (try? validate(url)) != nil else { return nil }
        let ext = url.pathExtension.lowercased()
        // These are transport chunks, not independent choices for the user.
        if ["ts", "m4s", "cmfv", "cmfa", "vtt", "key"].contains(ext) { return nil }
        switch ext {
        case "m3u8", "m3u": return (.video, .hls)
        case "mpd": return (.video, .dash)
        case "mp4", "mov", "webm", "mkv", "m4v", "ogv": return (.video, .direct)
        case "m4a", "aac", "mp3", "wav", "flac", "ogg", "oga", "aiff", "opus": return (.audio, .direct)
        default: break
        }
        let mime = mimeType?.lowercased().split(separator: ";").first.map(String.init) ?? ""
        if ["application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl"].contains(mime) { return (.video, .hls) }
        if mime == "application/dash+xml" { return (.video, .dash) }
        if mime.hasPrefix("video/"), mime != "video/mp2t" { return (.video, .direct) }
        if mime.hasPrefix("audio/") { return (.audio, .direct) }
        return nil
    }
    public static func resolve(_ reference: String, against base: URL) throws -> URL {
        guard let url = URL(string: reference.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)?.absoluteURL else { throw MediaError.invalidURL }
        try validate(url)
        return url
    }
    public static func requestHeaders(_ headers: [String: String]) -> [String: String] {
        let allowed = Set(["accept", "accept-language", "authorization", "cookie", "origin", "referer", "user-agent"])
        return headers.filter { key, value in
            allowed.contains(key.lowercased()) && value.utf8.count <= 16_384 && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        }
    }
}

public enum SafeFilename {
    public static func sanitize(_ name: String, fallback: String = "Media", maxBytes: Int = 180) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var cleaned = name.precomposedStringWithCanonicalMapping.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        cleaned = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if cleaned.isEmpty { cleaned = fallback }
        var result = ""
        for character in cleaned {
            if (result + String(character)).utf8.count > max(16, maxBytes) { break }
            result.append(character)
        }
        return result.isEmpty ? "Media" : result
    }
    public static func availableURL(directory: URL, baseName: String, extension fileExtension: String) -> URL {
        let name = sanitize(baseName)
        let ext = fileExtension.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(12)
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let manager = FileManager.default
        var index = 1
        while true {
            let numbered = index == 1 ? name : "\(name) \(index)"
            let candidate = directory.appendingPathComponent(numbered + suffix, isDirectory: false)
            if !manager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
