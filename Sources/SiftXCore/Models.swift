import Foundation
import CryptoKit

public enum SiftXConfiguration {
    public static let appBundleID = "com.siftx.SiftX"
    public static let nativeExtensionID = "com.siftx.SiftX.SafariExtension"
    public static let probeExtensionID = "com.siftx.SiftX.MediaProbe"
    public static let appGroupID = Bundle.main.object(forInfoDictionaryKey: "SiftXAppGroupIdentifier") as? String ?? "P57SZ9Z7G2.com.siftx.shared"
    public static let maximumCandidatesPerPage = 100
    public static let maximumSegments = 20_000
}

public enum MediaKind: String, Codable, Sendable { case video, audio }
public enum MediaTransport: String, Codable, Sendable {
    case direct, hls, dash, youtube, bilibili
    public var usesWebPlayer: Bool { self == .youtube || self == .bilibili }
}
public enum MediaEncryption: String, Codable, Sendable { case aes128 = "AES-128" }

/// Describes standard HLS AES-128 encryption; never contains the key bytes.
public struct HLSEncryption: Codable, Hashable, Sendable {
    public var keyURL: URL
    public var iv: Data
    /// Scoped to a playlist and EXT-X-KEY occurrence, including rotations at the same URL.
    public var keyID: String
    public init(keyURL: URL, iv: Data, keyID: String) {
        self.keyURL = keyURL; self.iv = iv; self.keyID = keyID
    }
}

public struct MediaSegment: Codable, Hashable, Sendable {
    public var url: URL
    /// An HTTP Range value, e.g. bytes=1024-2047. Nil requests the whole resource.
    public var byteRange: String?
    public var encryption: HLSEncryption?
    public init(url: URL, byteRange: String? = nil, encryption: HLSEncryption? = nil) {
        self.url = url; self.byteRange = byteRange; self.encryption = encryption
    }
}

public struct MediaPlan: Codable, Hashable, Sendable {
    public var segments: [MediaSegment]
    public var audioSegments: [MediaSegment]
    public var outputExtension: String
    public var isLive: Bool
    public init(segments: [MediaSegment], audioSegments: [MediaSegment] = [], outputExtension: String = "mp4", isLive: Bool = false) {
        self.segments = segments; self.audioSegments = audioSegments
        self.outputExtension = outputExtension; self.isLive = isLive
    }
}

public struct MediaCandidate: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sessionID: String
    public var title: String
    public var pageTitle: String
    public var pageURL: URL
    public var sourceURL: URL
    public var kind: MediaKind
    public var transport: MediaTransport
    public var quality: String?
    public var width: Int?
    public var height: Int?
    public var bitrate: Int?
    public var estimatedBytes: Int64?
    public var duration: Double?
    public var encryption: MediaEncryption?
    public var hasAudio: Bool
    public var protection: String?
    public var audioURL: URL?
    public var headers: [String: String]
    public var thumbnailURL: URL?
    public var plan: MediaPlan?
    public var youtubeFormat: YouTubeFormatSelection?
    public var bilibiliFormat: SiteFormatSelection?

    public init(id: String = UUID().uuidString, sessionID: String = "", title: String = "", pageTitle: String = "", pageURL: URL, sourceURL: URL, kind: MediaKind = .video, transport: MediaTransport = .direct, quality: String? = nil, width: Int? = nil, height: Int? = nil, bitrate: Int? = nil, estimatedBytes: Int64? = nil, duration: Double? = nil, encryption: MediaEncryption? = nil, hasAudio: Bool = true, protection: String? = nil, audioURL: URL? = nil, headers: [String: String] = [:], thumbnailURL: URL? = nil, plan: MediaPlan? = nil, youtubeFormat: YouTubeFormatSelection? = nil, bilibiliFormat: SiteFormatSelection? = nil) {
        self.id = id; self.sessionID = sessionID; self.title = title; self.pageTitle = pageTitle
        self.pageURL = pageURL; self.sourceURL = sourceURL; self.kind = kind; self.transport = transport
        self.quality = quality; self.width = width; self.height = height; self.bitrate = bitrate
        self.estimatedBytes = estimatedBytes; self.hasAudio = hasAudio; self.protection = protection
        self.duration = duration; self.encryption = encryption
        self.audioURL = audioURL; self.headers = headers; self.thumbnailURL = thumbnailURL; self.plan = plan
        self.youtubeFormat = youtubeFormat
        self.bilibiliFormat = bilibiliFormat
    }
    public var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        if !pageTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return pageTitle }
        return kind == .audio ? "音频" : "视频"
    }
    public var formatName: String {
        switch transport {
        case .hls: return "HLS"
        case .dash: return "DASH"
        case .youtube: return "网页媒体"
        case .bilibili: return "网页媒体"
        case .direct: return sourceURL.pathExtension.uppercased().isEmpty ? "媒体" : sourceURL.pathExtension.uppercased()
        }
    }
    public var durationLabel: String? {
        guard let duration, duration.isFinite, duration > 0, duration < Double(Int.max) else { return nil }
        let seconds = Int(duration.rounded())
        if seconds >= 3600 { return "\(seconds / 3600):" + String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60) }
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

public struct PageSession: Codable, Identifiable, Sendable {
    public var id: String
    public var pageURL: URL
    public var title: String
    public var updatedAt: Date
    public var candidates: [MediaCandidate]
    public init(id: String, pageURL: URL, title: String, updatedAt: Date = Date(), candidates: [MediaCandidate] = []) {
        self.id = id; self.pageURL = pageURL; self.title = title; self.updatedAt = updatedAt; self.candidates = candidates
    }
}

public enum DownloadStatus: String, Codable, CaseIterable, Sendable {
    case queued, downloading, paused, processing, completed, failed, cancelled
    public var recoveredAfterInterruption: DownloadStatus {
        switch self { case .downloading, .processing: return .paused; default: return self }
    }
    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

public struct DownloadRecord: Codable, Identifiable, Sendable {
    public var id: UUID
    public var candidate: MediaCandidate
    public var status: DownloadStatus
    public var createdAt: Date
    public var completedAt: Date?
    public var bytesReceived: Int64
    public var totalBytes: Int64?
    public var filePath: String?
    public var fileBookmark: Data?
    public var error: String?
    public init(id: UUID = UUID(), candidate: MediaCandidate, status: DownloadStatus = .queued, createdAt: Date = Date(), completedAt: Date? = nil, bytesReceived: Int64 = 0, totalBytes: Int64? = nil, filePath: String? = nil, fileBookmark: Data? = nil, error: String? = nil) {
        self.id = id; self.candidate = candidate; self.status = status; self.createdAt = createdAt
        self.completedAt = completedAt; self.bytesReceived = bytesReceived; self.totalBytes = totalBytes
        self.filePath = filePath; self.fileBookmark = fileBookmark; self.error = error
    }
}

public struct DownloadRequest: Codable, Identifiable, Sendable {
    public var id: UUID
    public var candidate: MediaCandidate
    public var createdAt: Date
    public init(id: UUID = UUID(), candidate: MediaCandidate, createdAt: Date = Date()) {
        self.id = id; self.candidate = candidate; self.createdAt = createdAt
    }
}

public enum PluginIcon: String, CaseIterable, Sendable {
    case currentPNG = "png"
    case arrowDown = "arrow.down"
    case arrowshapeDownFill = "arrowshape.down.fill"
    case arrowshapeDownCircle = "arrowshape.down.circle"
    case chevronDownCircle = "chevron.down.circle"
    case arrowDownCircle = "arrow.down.circle"
    case arrowtriangleDownCircle = "arrowtriangle.down.circle"

    public var title: String { self == .currentPNG ? "当前 PNG" : rawValue }
    public var systemImageName: String? { self == .currentPNG ? nil : rawValue }
}

public enum AppExitBehavior: String, Codable, CaseIterable, Sendable {
    case closeApp
    case menuBar
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var appearance: String?
    public var exitBehaviorRawValue: String?
    public var exitBehavior: AppExitBehavior {
        get { AppExitBehavior(rawValue: exitBehaviorRawValue ?? "") ?? .closeApp }
        set { exitBehaviorRawValue = newValue.rawValue }
    }
    // Optional raw value keeps existing settings and future unknown icons readable.
    public var pluginIcon: String?
    public var selectedPluginIcon: PluginIcon {
        get { pluginIcon.flatMap(PluginIcon.init(rawValue:)) ?? .currentPNG }
        set { pluginIcon = newValue.rawValue }
    }
    // Missing values preserve the visible badge for existing installations.
    public var toolbarBadgeVisibleFlag: Bool?
    public var showsToolbarBadge: Bool {
        get { toolbarBadgeVisibleFlag ?? true }
        set { toolbarBadgeVisibleFlag = newValue }
    }
    public var maxConcurrent: Int
    public var downloadBookmark: Data?
    public var downloadDirectory: String?
    public var notifyCompletion: Bool
    public var notifyFailure: Bool
    public var onboardingComplete: Bool
    public var openWhenFinished: Bool
    public var collisionPolicy: String
    // Optional flags keep existing settings payloads decodable (see pluginIcon note).
    public var dockIconHiddenFlag: Bool?
    public var menuBarIconHiddenFlag: Bool?
    public var dockIconHidden: Bool {
        get { dockIconHiddenFlag ?? false }
        set { dockIconHiddenFlag = newValue }
    }
    public var menuBarIconHidden: Bool {
        get { menuBarIconHiddenFlag ?? false }
        set { menuBarIconHiddenFlag = newValue }
    }
    public init(maxConcurrent: Int = 2, downloadBookmark: Data? = nil, downloadDirectory: String? = nil, notifyCompletion: Bool = true, notifyFailure: Bool = true, onboardingComplete: Bool = false, openWhenFinished: Bool = false, collisionPolicy: String = "rename", appearance: String? = nil, pluginIcon: String? = nil, exitBehavior: AppExitBehavior? = nil) {
        self.appearance = appearance
        self.exitBehaviorRawValue = exitBehavior?.rawValue
        self.pluginIcon = pluginIcon
        self.maxConcurrent = max(1, min(8, maxConcurrent)); self.downloadBookmark = downloadBookmark
        self.downloadDirectory = downloadDirectory; self.notifyCompletion = notifyCompletion
        self.notifyFailure = notifyFailure; self.onboardingComplete = onboardingComplete
        self.openWhenFinished = openWhenFinished; self.collisionPolicy = collisionPolicy
    }
}

public enum MediaIdentity {
    public static func stableID(sessionID: String, url: URL, variant: String = "") -> String {
        let text = sessionID + "\n" + url.absoluteString + "\n" + variant
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Only retains final media choices. Media chunks are never promoted into candidates.
    public static func deduplicated(_ candidates: [MediaCandidate]) -> [MediaCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            var key = candidate.sourceURL.absoluteString + "|" + (candidate.audioURL?.absoluteString ?? "") + "|" + (candidate.quality ?? "")
            // DASH variants share one MPD URL; the stable representation identity distinguishes them.
            if candidate.transport == .dash { key += "|" + candidate.id }
            return seen.insert(key).inserted
        }.prefix(SiftXConfiguration.maximumCandidatesPerPage).map { $0 }
    }
}
