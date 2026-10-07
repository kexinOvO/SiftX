import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import SiftXCore

struct DownloadRow: View {
    let record: DownloadRecord
    let speed: Double
    let settings: AppSettings
    private var working: Bool { [.downloading, .queued, .processing, .paused].contains(record.status) }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if record.candidate.kind == .video {
                DownloadRowThumbnail(record: record, settings: settings)
                    .padding(.top, 4)
            } else {
                Image(systemName: "waveform")
                    .font(.title2).foregroundStyle(.secondary).frame(width: 30).padding(.top, 4)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(record.candidate.title).font(.headline).lineLimit(2)
                Text([record.candidate.quality, record.candidate.sourceURL.host].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if working {
                    if let total = record.totalBytes, total > 0 {
                        ProgressView(value: min(Double(record.bytesReceived) / Double(total), 1))
                    } else if record.status == .downloading || record.status == .processing {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack {
                    Label(record.status.label, systemImage: record.status == .failed ? "exclamationmark.circle" : (record.status == .completed ? "checkmark.circle" : "arrow.down"))
                        .foregroundStyle(record.status == .failed ? Color.red : Color.secondary)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: record.bytesReceived, countStyle: .file))
                    if speed > 0, record.status == .downloading {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/秒")
                    }
                }.font(.caption).monospacedDigit()
            }
        }.padding(.vertical, 8)
    }
}

private struct DownloadRowThumbnail: View {
    let record: DownloadRecord
    let settings: AppSettings
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .quaternaryLabelColor)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.75), radius: 2)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: identity) {
            image = nil
            let loaded = await DownloadRowThumbnailLoader.shared.image(for: record, settings: settings)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }

    private var identity: Identity {
        Identity(
            id: record.id,
            candidateID: record.candidate.id,
            status: record.status.rawValue,
            filePath: record.filePath,
            fileBookmark: record.fileBookmark,
            sourceURL: record.candidate.sourceURL.absoluteString,
            thumbnailURL: record.candidate.thumbnailURL?.absoluteString,
            folderBookmark: settings.downloadBookmark,
            folder: settings.downloadDirectory
        )
    }

    private struct Identity: Equatable {
        let id: UUID
        let candidateID: String
        let status: String
        let filePath: String?
        let fileBookmark: Data?
        let sourceURL: String
        let thumbnailURL: String?
        let folderBookmark: Data?
        let folder: String?
    }
}

@MainActor
private final class DownloadRowThumbnailLoader {
    static let shared = DownloadRowThumbnailLoader()
    private let cache = NSCache<NSString, NSImage>()
    private var active = 0

    private init() {
        cache.countLimit = 100
        cache.totalCostLimit = 6_291_456
    }

    func image(for record: DownloadRecord, settings: AppSettings) async -> NSImage? {
        guard record.candidate.kind == .video else { return nil }
        let key = cacheKey(for: record)
        if let cached = cache.object(forKey: key) { return cached }

        // List rows load lazily, and this cap keeps fast scrolling from starting
        // many simultaneous decoders or poster requests.
        while active >= 2 {
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return nil }
            guard !Task.isCancelled else { return nil }
        }
        guard !Task.isCancelled else { return nil }
        if let cached = cache.object(forKey: key) { return cached }

        active += 1
        defer { active -= 1 }

        var image: NSImage?
        if record.status == .completed {
            image = await localFrame(for: record, settings: settings)
        }
        if image == nil, !Task.isCancelled, let url = posterURL(for: record.candidate) {
            image = try? await poster(url, headers: record.candidate.headers)
        }
        guard !Task.isCancelled else { return nil }
        if let image { cache.setObject(image, forKey: key, cost: 160 * 90 * 4) }
        return image
    }

    private func cacheKey(for record: DownloadRecord) -> NSString {
        [
            record.id.uuidString,
            record.candidate.id,
            record.filePath ?? "",
            record.completedAt?.timeIntervalSince1970.description ?? "",
            record.candidate.sourceURL.absoluteString,
            record.candidate.thumbnailURL?.absoluteString ?? ""
        ].joined(separator: "|") as NSString
    }

    private func localFrame(for record: DownloadRecord, settings: AppSettings) async -> NSImage? {
        guard let lease = try? DownloadFileLease(record: record, settings: settings), lease.exists,
              !Task.isCancelled else { return nil }
        defer { withExtendedLifetime(lease) {} }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: lease.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        let seconds: Double
        if let duration = record.candidate.duration, duration.isFinite, duration > 0 {
            seconds = min(max(duration * 0.08, 0.5), 2.5)
        } else {
            seconds = 1
        }
        do {
            let (frame, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            guard !Task.isCancelled else { return nil }
            return NSImage(cgImage: frame, size: .zero)
        } catch {
            return nil
        }
    }

    private func posterURL(for candidate: MediaCandidate) -> URL? {
        if let url = candidate.thumbnailURL, (try? URLSafety.validate(url)) != nil { return url }
        if let canonical = YouTubeURL.canonical(candidate.sourceURL),
           let id = URLComponents(url: canonical, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value {
            return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        }
        return nil
    }

    private func poster(_ url: URL, headers: [String: String]) async throws -> NSImage? {
        guard (try? URLSafety.validate(url)) != nil else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        for (key, value) in URLSafety.requestHeaders(headers) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return nil }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2_097_152 else { return nil }
            data.append(byte)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let frame = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: frame, size: .zero)
    }
}
