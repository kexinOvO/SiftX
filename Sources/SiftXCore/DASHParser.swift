import Foundation

public struct DASHRepresentation: Sendable {
    public var id: String
    public var kind: MediaKind
    public var width: Int?
    public var height: Int?
    public var bitrate: Int?
    public var segments: [MediaSegment]
    /// Timing and initialization metadata for native streaming previews.
    public var initializationSegment: MediaSegment?
    public var segmentDurations: [Double] = []
}
public struct DASHManifest: Sendable {
    public var representations: [DASHRepresentation]
    public var isProtected: Bool
    public var isLive: Bool
    public var duration: Double?
}

/// Supports static DASH, inherited templates, explicit segment lists and finite timelines.
public enum DASHParser {
    public static func parse(_ text: String, baseURL: URL) throws -> DASHManifest {
        try URLSafety.validate(baseURL)
        guard text.utf8.count <= 4_194_304 else { throw MediaError.resourceTooLarge }
        guard !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw MediaError.malformedManifest("XML entities are not permitted") }
        let delegate = XMLTreeBuilder()
        let parser = XMLParser(data: Data(text.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root, root.name == "MPD", !delegate.exceededLimit else { throw MediaError.malformedManifest("invalid DASH document") }
        let protected = root.descendantsContain("ContentProtection") || root.descendantsContain("pssh")
        let isLive = root.attributes["type"] == "dynamic"
        let presentationDuration = root.attributes["mediaPresentationDuration"].flatMap(duration)
        if protected || isLive { return DASHManifest(representations: [], isProtected: protected, isLive: isLive, duration: presentationDuration) }
        let periods = root.children.filter { $0.name == "Period" }
        guard periods.count == 1, let period = periods.first else { throw MediaError.unsupported("此 DASH 媒体包含多个播放阶段，暂不支持下载。") }
        let seconds = period.attributes["duration"].flatMap(duration) ?? presentationDuration
        var result: [DASHRepresentation] = []
        var budget = ManifestBudget()
        let rootBase = try inheritedBase(root, parent: baseURL)
        let periodBase = try inheritedBase(period, parent: rootBase)
        for adaptation in period.children where adaptation.name == "AdaptationSet" {
            let adaptationBase = try inheritedBase(adaptation, parent: periodBase)
            let reps = adaptation.children.filter { $0.name == "Representation" }
            for (index, rep) in (reps.isEmpty ? [adaptation] : reps).enumerated() {
                let chain = rep === adaptation ? [root, period, adaptation] : [root, period, adaptation, rep]
                let repBase = rep === adaptation ? adaptationBase : try inheritedBase(rep, parent: adaptationBase)
                let attrs = chain.reduce(into: [String: String]()) { $0.merge($1.attributes, uniquingKeysWith: { _, new in new }) }
                let mime = attrs["mimeType"] ?? ""
                let content = attrs["contentType"] ?? ""
                let kind: MediaKind
                if content == "audio" || mime.hasPrefix("audio/") || attrs["audioSamplingRate"] != nil { kind = .audio }
                else if content == "video" || mime.hasPrefix("video/") || attrs["width"] != nil || attrs["height"] != nil { kind = .video }
                else { continue }
                let id = rep.attributes["id"] ?? "\(kind.rawValue)-\(result.count)-\(index)"
                let bitrate = attrs["bandwidth"].flatMap(Int.init)
                let sequence = try makeSegments(chain: chain, baseURL: repBase, id: id, bitrate: bitrate, seconds: seconds, budget: &budget)
                guard !sequence.segments.isEmpty else { continue }
                result.append(DASHRepresentation(id: id, kind: kind, width: attrs["width"].flatMap(Int.init), height: attrs["height"].flatMap(Int.init), bitrate: bitrate, segments: sequence.segments, initializationSegment: sequence.initialization, segmentDurations: sequence.durations))
                guard result.count <= 100 else { throw MediaError.resourceTooLarge }
            }
        }
        guard !result.isEmpty else { throw MediaError.unsupported("此 DASH 媒体的分片格式暂不支持。") }
        return DASHManifest(representations: result, isProtected: false, isLive: false, duration: seconds)
    }

    private struct SegmentSequence {
        var segments: [MediaSegment]
        var initialization: MediaSegment?
        var durations: [Double]
    }

    private static func makeSegments(chain: [XMLNode], baseURL: URL, id: String, bitrate: Int?, seconds: Double?, budget: inout ManifestBudget) throws -> SegmentSequence {
        let lists = chain.compactMap { $0.children.first(where: { $0.name == "SegmentList" }) }
        let templates = chain.compactMap { $0.children.first(where: { $0.name == "SegmentTemplate" }) }
        if let list = lists.last {
            var result: [MediaSegment] = []
            let initialization = lists.reversed().compactMap { $0.children.first(where: { $0.name == "Initialization" }) }.first
            if let initialization {
                let url = try initialization.attributes["sourceURL"].map { try URLSafety.resolve($0, against: baseURL) } ?? baseURL
                try budget.consume(url)
                result.append(MediaSegment(url: url, byteRange: try initialization.attributes["range"].map(httpRange)))
            }
            let segmentList = lists.reversed().first(where: { $0.children.contains(where: { $0.name == "SegmentURL" }) }) ?? list
            let mediaSegments = segmentList.children.filter { $0.name == "SegmentURL" }
            guard !mediaSegments.isEmpty else { throw MediaError.malformedManifest("DASH media segments missing") }
            for segment in mediaSegments {
                guard let media = segment.attributes["media"] else { throw MediaError.malformedManifest("DASH segment URL missing") }
                let url = try URLSafety.resolve(media, against: baseURL); try budget.consume(url)
                result.append(MediaSegment(url: url, byteRange: try segment.attributes["mediaRange"].map(httpRange)))
                guard result.count <= SiftXConfiguration.maximumSegments else { throw MediaError.resourceTooLarge }
            }
            let attrs = lists.reduce(into: [String: String]()) { $0.merge($1.attributes, uniquingKeysWith: { _, new in new }) }
            let scale = Double(attrs["timescale"] ?? "1") ?? 0
            let d = attrs["duration"].flatMap(Double.init)
            let durations = scale > 0 && d.map({ $0.isFinite && $0 > 0 }) == true
                ? Array(repeating: d! / scale, count: mediaSegments.count) : []
            return SegmentSequence(segments: result, initialization: initialization == nil ? nil : result.first, durations: durations)
        }
        if !templates.isEmpty {
            let attrs = templates.reduce(into: [String: String]()) { $0.merge($1.attributes, uniquingKeysWith: { _, new in new }) }
            guard let media = attrs["media"] else { throw MediaError.malformedManifest("DASH media template missing") }
            let scale = Int64(attrs["timescale"] ?? "1") ?? 0
            let first = Int64(attrs["startNumber"] ?? "1") ?? 0
            let offset = Int64(attrs["presentationTimeOffset"] ?? "0") ?? 0
            guard scale > 0, scale <= 1_000_000_000, first >= 0, offset >= 0 else { throw MediaError.malformedManifest("invalid DASH timeline scale") }
            var result: [MediaSegment] = []
            if let initialization = attrs["initialization"] {
                let url = try templateURL(initialization, id: id, bitrate: bitrate, number: first, time: offset, baseURL: baseURL); try budget.consume(url)
                result.append(MediaSegment(url: url))
            }
            let timeline = templates.reversed().compactMap { $0.children.first(where: { $0.name == "SegmentTimeline" }) }.first
            var times: [Int64] = []
            var durations: [Double] = []
            if let timeline {
                let points = timeline.children.filter { $0.name == "S" }
                var current: Int64 = 0
                for (index, point) in points.enumerated() {
                    if let t = point.attributes["t"] {
                        guard let start = Int64(t), start >= 0 else { throw MediaError.malformedManifest("invalid DASH start time") }
                        current = start
                    }
                    guard let d = point.attributes["d"].flatMap(Int64.init), d > 0 else { throw MediaError.malformedManifest("DASH duration missing") }
                    let repetitions = Int64(point.attributes["r"] ?? "0") ?? Int64.min
                    var count: Int64
                    if repetitions == -1 {
                        let next = index + 1 < points.count ? points[index + 1].attributes["t"].flatMap(Int64.init) : nil
                        let finiteEnd: Int64?
                        if let next { finiteEnd = next }
                        else if let seconds, seconds.isFinite, seconds * Double(scale) < Double(Int64.max - offset) {
                            finiteEnd = Int64(ceil(seconds * Double(scale))) + offset
                        } else { finiteEnd = nil }
                        guard let end = finiteEnd, end > current else { throw MediaError.unsupported("此 DASH 时间线没有确定的结束位置。") }
                        count = ((end - current - 1) / d) + 1
                    } else {
                        guard repetitions >= 0, repetitions < Int64(SiftXConfiguration.maximumSegments) else { throw MediaError.malformedManifest("invalid DASH repeat count") }
                        count = repetitions + 1
                    }
                    guard count <= Int64(SiftXConfiguration.maximumSegments - times.count), d <= (Int64.max - current) / max(1, count) else { throw MediaError.resourceTooLarge }
                    for _ in 0..<count { times.append(current); durations.append(Double(d) / Double(scale)); current += d }
                }
            } else {
                guard let d = attrs["duration"].flatMap(Int64.init), d > 0, let seconds, seconds.isFinite, seconds > 0 else { throw MediaError.unsupported("此 DASH 媒体缺少可用的分片时间信息。") }
                let count = ceil(seconds * Double(scale) / Double(d))
                guard count > 0, count < Double(SiftXConfiguration.maximumSegments), d <= (Int64.max - offset) / Int64(count) else { throw MediaError.resourceTooLarge }
                times = (0..<Int64(count)).map { offset + $0 * d }
                durations = (0..<Int64(count)).map { index in min(Double(d) / Double(scale), seconds - Double(index * d) / Double(scale)) }
            }
            guard !times.isEmpty else { throw MediaError.malformedManifest("DASH timeline is empty") }
            guard times.count + result.count <= SiftXConfiguration.maximumSegments, first <= Int64.max - Int64(times.count) else { throw MediaError.resourceTooLarge }
            for (index, time) in times.enumerated() {
                let url = try templateURL(media, id: id, bitrate: bitrate, number: first + Int64(index), time: time, baseURL: baseURL); try budget.consume(url)
                result.append(MediaSegment(url: url))
            }
            return SegmentSequence(segments: result, initialization: attrs["initialization"] == nil ? nil : result.first, durations: durations)
        }
        // SegmentBase is an indexed portion of an otherwise complete media file; download the complete file.
        if chain.contains(where: { $0.children.contains(where: { $0.name == "BaseURL" }) }) {
            guard !baseURL.hasDirectoryPath, !baseURL.path.isEmpty else {
                throw MediaError.unsupported("此 DASH 媒体只提供了目录地址，缺少可下载的文件或分片信息。")
            }
            try budget.consume(baseURL)
            return SegmentSequence(segments: [MediaSegment(url: baseURL)], initialization: nil, durations: [])
        }
        throw MediaError.unsupported("此 DASH 媒体的分片寻址方式暂不支持。")
    }

    private static func inheritedBase(_ node: XMLNode, parent: URL) throws -> URL {
        guard let value = node.children.first(where: { $0.name == "BaseURL" })?.text.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return parent }
        return try URLSafety.resolve(value, against: parent)
    }
    private static func httpRange(_ text: String) throws -> String {
        let values = text.split(separator: "-", omittingEmptySubsequences: false)
        guard values.count == 2, let low = Int64(values[0]), let high = Int64(values[1]), low >= 0, high >= low else { throw MediaError.malformedManifest("invalid DASH byte range") }
        return "bytes=\(low)-\(high)"
    }
    private static func templateURL(_ template: String, id: String, bitrate: Int?, number: Int64, time: Int64, baseURL: URL) throws -> URL {
        var value = template.replacingOccurrences(of: "$$", with: "\u{1f}")
        value = value.replacingOccurrences(of: "$RepresentationID$", with: id)
        if let bitrate { value = value.replacingOccurrences(of: "$Bandwidth$", with: String(bitrate)) }
        let expression = try NSRegularExpression(pattern: "\\$(Number|Time)(%0([0-9]{1,2})d)?\\$")
        for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let full = Range(match.range, in: value), let name = Range(match.range(at: 1), in: value) else { continue }
            let integer = value[name] == "Number" ? number : time
            var replacement = String(integer)
            if let pad = Range(match.range(at: 3), in: value), let width = Int(value[pad]) {
                guard width <= 12 else { throw MediaError.malformedManifest("invalid DASH number format") }
                replacement = String(repeating: "0", count: max(0, width - replacement.count)) + replacement
            }
            value.replaceSubrange(full, with: replacement)
        }
        guard !value.contains("$") else { throw MediaError.unsupported("此 DASH 媒体使用了不支持的动态模板。") }
        value = value.replacingOccurrences(of: "\u{1f}", with: "$")
        return try URLSafety.resolve(value, against: baseURL)
    }
    private static func duration(_ text: String) -> Double? {
        let expression = try? NSRegularExpression(pattern: "^P(?:(\\d+(?:\\.\\d+)?)D)?(?:T(?:(\\d+(?:\\.\\d+)?)H)?(?:(\\d+(?:\\.\\d+)?)M)?(?:(\\d+(?:\\.\\d+)?)S)?)?$")
        guard let match = expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let multipliers = [86_400.0, 3_600, 60, 1]
        var seconds = 0.0
        for index in 1...4 {
            if let range = Range(match.range(at: index), in: text), let value = Double(text[range]) { seconds += value * multipliers[index - 1] }
        }
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}

private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var children: [XMLNode] = []
    var text = ""
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
    func descendantsContain(_ name: String) -> Bool { self.name == name || children.contains { $0.descendantsContain(name) } }
}
private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var stack: [XMLNode] = []
    var count = 0
    var exceededLimit = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        count += 1
        guard count < 50_000, stack.count < 32 else { exceededLimit = true; parser.abortParsing(); return }
        let node = XMLNode(name: elementName.split(separator: ":").last.map(String.init) ?? elementName, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text.append(string) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if !stack.isEmpty { stack.removeLast() } }
}
