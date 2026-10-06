import AppKit
import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import SiftXCore

struct MediaThumbnailView: View {
    let candidate: MediaCandidate
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(nsColor: .quaternaryLabelColor)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(5)
                .background(.black.opacity(0.60), in: Circle())
        }
        .clipped()
        .accessibilityHidden(true)
        .task(id: candidate.id + (candidate.thumbnailURL?.absoluteString ?? "")) {
            image = await MediaThumbnailLoader.shared.image(for: candidate)
        }
    }
}

@MainActor
final class MediaThumbnailLoader {
    static let shared = MediaThumbnailLoader()
    private let cache = NSCache<NSString, NSImage>()
    private var active = 0

    init() { cache.countLimit = 60; cache.totalCostLimit = 8_388_608 }

    func image(for candidate: MediaCandidate) async -> NSImage? {
        let key = (candidate.id + (candidate.thumbnailURL?.absoluteString ?? "")) as NSString
        if let image = cache.object(forKey: key) { return image }
        // A long menu must not create dozens of concurrent decoders or streams.
        while active >= 2 {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        guard !Task.isCancelled else { return nil }
        if let image = cache.object(forKey: key) { return image }
        active += 1
        defer { active -= 1 }
        var image: NSImage?
        if let url = posterURL(for: candidate) { image = try? await poster(url, headers: candidate.headers) }
        if image == nil, candidate.transport != .youtube, !Task.isCancelled {
            image = try? await frame(candidate)
        }
        guard !Task.isCancelled else { return nil }
        if let image { cache.setObject(image, forKey: key, cost: 160 * 100 * 4) }
        return image
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 6; configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        for (key, value) in URLSafety.requestHeaders(headers) { request.setValue(value, forHTTPHeaderField: key) }
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
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    private func frame(_ candidate: MediaCandidate) async throws -> NSImage? {
        let proxy = MediaPreviewProxy()
        do {
            let url = try await proxy.start(candidate: candidate)
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 1
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true; player.volume = 0
            player.play()
            var result: NSImage?
            do {
                for _ in 0..<60 {
                    try await Task.sleep(for: .milliseconds(100))
                    if item.status == .failed { break }
                    let time = output.itemTime(forHostTime: CACurrentMediaTime())
                    if let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                        let original = CIImage(cvPixelBuffer: buffer)
                        let scale = 160 / max(original.extent.width, original.extent.height)
                        let image = original.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                        if let cg = CIContext().createCGImage(image, from: image.extent) {
                            result = NSImage(cgImage: cg, size: .zero)
                        }
                        break
                    }
                }
            } catch {
                player.pause(); player.replaceCurrentItem(with: nil)
                throw error
            }
            player.pause(); player.replaceCurrentItem(with: nil)
            await proxy.stop()
            return result
        } catch {
            await proxy.stop()
            throw error
        }
    }
}
