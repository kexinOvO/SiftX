import Foundation

public struct HLSVariant: Sendable, Equatable {
    public var url: URL
    public var width: Int?
    public var height: Int?
    public var bitrate: Int?
    public var audioGroup: String?
    public var codecs: String?
    public var isAudioOnly: Bool {
        guard width == nil, height == nil, let codecs else { return false }
        let values = codecs.lowercased()
        return !["avc", "hvc", "hev", "vp0", "vp9", "av01", "theora"].contains(where: values.contains)
    }
}
public struct HLSAudioRendition: Sendable, Equatable {
    public var url: URL
    public var group: String
    public var name: String
    public var isDefault: Bool
}
public struct HLSManifest: Sendable {
    public var variants: [HLSVariant]
    public var audio: [HLSAudioRendition]
    public var segments: [MediaSegment]
    public var isLive: Bool
    public var isProtected: Bool
    public var duration: Double
    public var hasAES128Encryption: Bool { segments.contains { $0.encryption != nil } }
}

public enum HLSParser {
    private struct KeyState {
        var url: URL
        var iv: Data?
        var id: String
        func encryption(sequence: UInt64) -> HLSEncryption {
            HLSEncryption(keyURL: url, iv: iv ?? HLSParser.sequenceIV(sequence), keyID: id)
        }
    }
    public static func parse(_ text: String, baseURL: URL) throws -> HLSManifest {
        try URLSafety.validate(baseURL)
        guard text.utf8.count <= 4_194_304 else { throw MediaError.resourceTooLarge }
        let lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard lines.first?.replacingOccurrences(of: "\u{feff}", with: "") == "#EXTM3U" else { throw MediaError.malformedManifest("HLS header missing") }
        var result = HLSManifest(variants: [], audio: [], segments: [], isLive: true, isProtected: false, duration: 0)
        var pendingVariant: [String: String]?
        var pendingRange: String?
        var previousRangeEnd: Int64 = 0
        var previousRangeURL: URL?
        var lastMap: MediaSegment?
        var mediaSegmentCount = 0
        var pendingDuration = false
        var budget = ManifestBudget()
        var activeKey: KeyState?
        var keyOccurrence = 0
        var sequence: UInt64 = 0
        var sequenceWasSet = false
        var sequenceExhausted = false
        var iFramesOnly = false
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-SESSION-KEY:") || line.hasPrefix("#EXT-X-KEY:") {
                let values = attributes(String(line.split(separator: ":", maxSplits: 1).last ?? ""))
                let sessionKey = line.hasPrefix("#EXT-X-SESSION-KEY:")
                guard let method = values["METHOD"]?.uppercased() else { throw MediaError.malformedManifest("encryption method missing") }
                if method == "NONE" {
                    guard !sessionKey, values.count == 1 else { throw MediaError.malformedManifest("invalid METHOD=NONE key") }
                    activeKey = nil
                } else if method == "AES-128", (values["KEYFORMAT"] ?? "identity") == "identity" {
                    guard let uri = values["URI"], !uri.isEmpty else { throw MediaError.malformedManifest("AES-128 key URL missing") }
                    let versions = (values["KEYFORMATVERSIONS"] ?? "1").split(separator: "/")
                    guard versions.contains("1") else { throw MediaError.unsupported("此 HLS 密钥格式版本暂不支持。") }
                    let url = try URLSafety.resolve(uri, against: baseURL)
                    try budget.consume(url)
                    let iv = try values["IV"].map(parseIV)
                    keyOccurrence += 1
                    // SESSION-KEY only preloads a key. The media playlist defines its scope.
                    if !sessionKey {
                        activeKey = KeyState(url: url, iv: iv, id: MediaIdentity.stableID(sessionID: baseURL.absoluteString, url: url, variant: String(keyOccurrence)))
                    }
                } else {
                    result.isProtected = true
                    if !sessionKey { activeKey = nil }
                }
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                guard !sequenceWasSet, mediaSegmentCount == 0,
                      let value = UInt64(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) else { throw MediaError.malformedManifest("invalid media sequence") }
                sequence = value; sequenceWasSet = true
            } else if line == "#EXT-X-I-FRAMES-ONLY" {
                iFramesOnly = true
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingVariant = attributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let values = attributes(String(line.dropFirst("#EXT-X-MEDIA:".count)))
                if values["TYPE"] == "AUDIO", let uri = values["URI"], let group = values["GROUP-ID"] {
                    let url = try URLSafety.resolve(uri, against: baseURL); try budget.consume(url)
                    result.audio.append(HLSAudioRendition(url: url, group: group, name: values["NAME"] ?? "音频", isDefault: values["DEFAULT"] == "YES"))
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let values = attributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                guard let uri = values["URI"] else { throw MediaError.malformedManifest("initialization URL missing") }
                let url = try URLSafety.resolve(uri, against: baseURL)
                let range = try values["BYTERANGE"].map { specification in
                    if !specification.contains("@"), previousRangeURL != url { throw MediaError.malformedManifest("initialization range has no preceding segment") }
                    return try byteRange(specification, implicitOffset: previousRangeEnd).header
                }
                if activeKey != nil, activeKey?.iv == nil { throw MediaError.malformedManifest("AES-128 initialization section requires an explicit IV") }
                let map = MediaSegment(url: url, byteRange: range, encryption: activeKey?.encryption(sequence: sequence))
                if map != lastMap { try budget.consume(url); result.segments.append(map); lastMap = map }
                guard result.segments.count <= SiftXConfiguration.maximumSegments else { throw MediaError.resourceTooLarge }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if line.hasPrefix("#EXTINF:") {
                guard !pendingDuration else { throw MediaError.malformedManifest("segment URL missing") }
                let seconds = line.dropFirst("#EXTINF:".count).split(separator: ",").first.flatMap { Double($0) } ?? 0
                guard seconds.isFinite, seconds >= 0, seconds < 86_400 else { throw MediaError.malformedManifest("invalid segment duration") }
                result.duration += seconds
                pendingDuration = true
            } else if line == "#EXT-X-ENDLIST" {
                result.isLive = false
            } else if line.hasPrefix("#EXT-X-SKIP:") {
                throw MediaError.unsupported("此媒体需要增量直播信息，暂不支持下载。")
            } else if line.hasPrefix("#") {
                continue
            } else if let variant = pendingVariant {
                let resolution = variant["RESOLUTION"]?.lowercased().split(separator: "x").compactMap { Int($0) } ?? []
                let url = try URLSafety.resolve(line, against: baseURL); try budget.consume(url)
                result.variants.append(HLSVariant(url: url, width: resolution.count == 2 ? resolution[0] : nil, height: resolution.count == 2 ? resolution[1] : nil, bitrate: (variant["AVERAGE-BANDWIDTH"] ?? variant["BANDWIDTH"]).flatMap(Int.init), audioGroup: variant["AUDIO"], codecs: variant["CODECS"]))
                pendingVariant = nil
            } else {
                guard pendingDuration else { throw MediaError.malformedManifest("segment duration missing") }
                guard !sequenceExhausted else { throw MediaError.malformedManifest("media sequence overflow") }
                let url = try URLSafety.resolve(line, against: baseURL)
                var header: String?
                if let pendingRange {
                    if !pendingRange.contains("@"), previousRangeURL != url { throw MediaError.malformedManifest("implicit byte range has no preceding segment") }
                    let range = try byteRange(pendingRange, implicitOffset: previousRangeEnd)
                    header = range.header; previousRangeEnd = range.nextOffset; previousRangeURL = url
                } else { previousRangeEnd = 0; previousRangeURL = nil }
                try budget.consume(url)
                result.segments.append(MediaSegment(url: url, byteRange: header, encryption: activeKey?.encryption(sequence: sequence)))
                mediaSegmentCount += 1; pendingDuration = false
                if sequence == UInt64.max { sequenceExhausted = true } else { sequence += 1 }
                pendingRange = nil
                guard result.segments.count <= SiftXConfiguration.maximumSegments else { throw MediaError.resourceTooLarge }
            }
        }
        guard pendingVariant == nil, !pendingDuration, pendingRange == nil else { throw MediaError.malformedManifest("media URL missing") }
        guard result.variants.isEmpty || mediaSegmentCount == 0 else { throw MediaError.malformedManifest("master and media entries are mixed") }
        guard !result.variants.isEmpty || mediaSegmentCount > 0 || result.isProtected else { throw MediaError.malformedManifest("media playlist is empty") }
        guard result.variants.count <= 100, result.audio.count <= 100 else { throw MediaError.resourceTooLarge }
        if iFramesOnly, result.hasAES128Encryption {
            throw MediaError.unsupported("加密的 I-frame 专用播放列表暂不支持下载，请选择完整视频流。")
        }
        return result
    }

    private static func parseIV(_ text: String) throws -> Data {
        guard text.lowercased().hasPrefix("0x") else { throw MediaError.malformedManifest("invalid AES-128 IV") }
        let digits = String(text.dropFirst(2))
        guard !digits.isEmpty, digits.count <= 32, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw MediaError.malformedManifest("invalid AES-128 IV") }
        let padded = String(repeating: "0", count: 32 - digits.count) + digits
        var bytes = Data()
        var position = padded.startIndex
        while position < padded.endIndex {
            let next = padded.index(position, offsetBy: 2)
            guard let byte = UInt8(padded[position..<next], radix: 16) else { throw MediaError.malformedManifest("invalid AES-128 IV") }
            bytes.append(byte); position = next
        }
        return bytes
    }

    private static func sequenceIV(_ sequence: UInt64) -> Data {
        var value = sequence.bigEndian
        return Data(repeating: 0, count: 8) + withUnsafeBytes(of: &value) { Data($0) }
    }

    public static func attributes(_ text: String) -> [String: String] {
        var fields: [String] = []; var field = ""; var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle(); field.append(character) }
            else if character == ",", !quoted { fields.append(field); field = "" }
            else { field.append(character) }
        }
        fields.append(field)
        var result: [String: String] = [:]
        for field in fields {
            let components = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if components.count == 2 {
                let key = components[0].trimmingCharacters(in: .whitespaces).uppercased()
                var value = components[1].trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                result[key] = value
            }
        }
        return result
    }
    private static func byteRange(_ text: String, implicitOffset: Int64) throws -> (header: String, nextOffset: Int64) {
        let pieces = text.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let length = pieces.first.flatMap({ Int64($0) }), length > 0 else { throw MediaError.malformedManifest("invalid byte range") }
        let offset = pieces.count == 2 ? Int64(pieces[1]) : implicitOffset
        guard let offset, offset >= 0, length <= Int64.max - offset else { throw MediaError.malformedManifest("byte range overflow") }
        return ("bytes=\(offset)-\(offset + length - 1)", offset + length)
    }
}
