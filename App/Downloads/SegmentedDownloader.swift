import Foundation
import CryptoKit
import SiftXCore

private actor SegmentProgress {
    private var bytes: [Int: Int64]
    private let expected: Int64?
    private let report: @Sendable (TransferProgress) -> Void

    init(existing: [Int: Int64], expected: Int64?, report: @escaping @Sendable (TransferProgress) -> Void) {
        bytes = existing
        self.expected = expected
        self.report = report
    }

    func update(index: Int, received: Int64) {
        bytes[index] = received
        report(TransferProgress(bytes: bytes.values.reduce(0, +), total: expected))
    }

    func complete() -> TransferProgress {
        let total = bytes.values.reduce(0, +)
        let result = TransferProgress(bytes: total, total: total)
        report(result)
        return result
    }
}

struct SegmentedDownloader: Sendable {
    private struct Item: Sendable {
        var index: Int
        var segment: MediaSegment
        var file: URL
    }

    func download(candidate: MediaCandidate, plan: MediaPlan, directory: URL,
                  progress: @escaping @Sendable (TransferProgress) -> Void,
                  processing: @escaping @Sendable () -> Void) async throws -> URL {
        guard !plan.isLive else { throw DownloadError.liveStream }
        guard candidate.protection == nil else { throw DownloadError.protectedMedia }
        guard !plan.segments.isEmpty, plan.segments.count + plan.audioSegments.count <= 30_000 else { throw DownloadError.invalidResponse }
        let segmentsDirectory = directory.appendingPathComponent("Segments", isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let identity = try encoder.encode(plan)
        let fingerprint = Data(SHA256.hash(data: identity))
        let identityURL = directory.appendingPathComponent("plan.sha256")
        if (try? Data(contentsOf: identityURL)) != fingerprint {
            try? FileManager.default.removeItem(at: segmentsDirectory)
        }
        try FileManager.default.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
        try fingerprint.write(to: identityURL, options: .atomic)
        let allSegments = plan.segments + plan.audioSegments
        let items = allSegments.enumerated().map { index, segment in
            Item(index: index, segment: segment, file: segmentsDirectory.appendingPathComponent(String(format: "%06d.chunk", index)))
        }
        var existing: [Int: Int64] = [:]
        for item in items {
            if let size = try? item.file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 { existing[item.index] = Int64(size) }
        }
        let tracker = SegmentProgress(existing: existing, expected: candidate.estimatedBytes, report: progress)
        let pending = items.filter { existing[$0.index] == nil }
        let keys = HLSKeyLoader(headers: candidate.headers)
        do {
            try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
                var next = 0
                func schedule(_ item: Item) {
                    group.addTask {
                        let key: Data?
                        if let encryption = item.segment.encryption { key = try await keys.key(for: encryption) }
                        else { key = nil }
                        let partial = item.file.appendingPathExtension("part")
                        let result = try await TransferRetry.download(url: item.segment.url, headers: candidate.headers,
                                                                    destination: partial, range: item.segment.byteRange) { update in
                            Task { await tracker.update(index: item.index, received: update.bytes) }
                        }
                        try Task.checkCancellation()
                        if let encryption = item.segment.encryption, let key {
                            let decrypted = item.file.appendingPathExtension("decrypting")
                            defer { try? FileManager.default.removeItem(at: decrypted) }
                            do {
                                try HLSAES128.decrypt(source: partial, destination: decrypted, key: key, iv: encryption.iv)
                            } catch {
                                // A complete but corrupt ciphertext must be fetched again on retry.
                                if !(error is CancellationError) {
                                    try? FileManager.default.removeItem(at: partial)
                                    try? FileManager.default.removeItem(at: partial.appendingPathExtension("http.json"))
                                }
                                throw error
                            }
                            try Task.checkCancellation()
                            try FileManager.default.moveItem(at: decrypted, to: item.file)
                            try? FileManager.default.removeItem(at: partial)
                        } else {
                            try FileManager.default.moveItem(at: partial, to: item.file)
                        }
                        try? FileManager.default.removeItem(at: partial.appendingPathExtension("http.json"))
                        return (item.index, result.bytes)
                    }
                }
                while next < min(4, pending.count) { schedule(pending[next]); next += 1 }
                while let (index, bytes) = try await group.next() {
                    await tracker.update(index: index, received: bytes)
                    if next < pending.count { schedule(pending[next]); next += 1 }
                }
            }
        } catch { await keys.close(); throw error }
        await keys.close()
        _ = await tracker.complete()
        try Task.checkCancellation()
        processing()
        let video = directory.appendingPathComponent("video.input")
        let videoFiles = Array(items.prefix(plan.segments.count)).map(\.file)
        try DownloadFiles.concatenate(videoFiles, destination: video)
        var audio: URL?
        if !plan.audioSegments.isEmpty {
            let destination = directory.appendingPathComponent("audio.input")
            try DownloadFiles.concatenate(Array(items.suffix(plan.audioSegments.count)).map(\.file), destination: destination)
            audio = destination
        }
        let output = directory.appendingPathComponent("processed").appendingPathExtension(DownloadFiles.outputExtension(candidate: candidate, plan: plan))
        try await MediaProcessor().run(video: video, audio: audio, output: output, audioOnly: candidate.kind == .audio)
        return output
    }
}

struct DownloadArtifact: Sendable {
    var file: URL
    var fileExtension: String
}

actor DownloadEngine {
    private let analyzer = MediaAnalyzer()
    private let stagingRoot: URL?

    init(stagingRoot: URL? = nil) { self.stagingRoot = stagingRoot }

    func run(candidate: MediaCandidate, id: UUID,
             progress: @escaping @Sendable (TransferProgress) -> Void,
             processing: @escaping @Sendable () -> Void) async throws -> DownloadArtifact {
        guard candidate.protection == nil else { throw DownloadError.protectedMedia }
        try URLSafety.validate(candidate.sourceURL)
        let directory = try DownloadFiles.stagingDirectory(id: id, root: stagingRoot)
        if candidate.transport == .youtube || candidate.transport == .bilibili {
            return try await SiteMediaDownloader(transport: candidate.transport).download(candidate: candidate, directory: directory, progress: progress, processing: processing)
        }
        if candidate.transport != .direct {
            let plan = try await analyzer.plan(for: candidate)
            let file = try await SegmentedDownloader().download(candidate: candidate, plan: plan, directory: directory,
                                                                progress: progress, processing: processing)
            return DownloadArtifact(file: file, fileExtension: DownloadFiles.outputExtension(candidate: candidate, plan: plan))
        }
        let video = directory.appendingPathComponent("direct.partial")
        let result = try await TransferRetry.download(url: candidate.sourceURL, headers: candidate.headers, destination: video, progress: progress)
        var fileExtension = DownloadFiles.outputExtension(candidate: candidate)
        guard let audioURL = candidate.audioURL, candidate.kind == .video else { return DownloadArtifact(file: video, fileExtension: fileExtension) }
        let audio = directory.appendingPathComponent("direct-audio.partial")
        let videoBytes = result.bytes
        _ = try await TransferRetry.download(url: audioURL, headers: candidate.headers, destination: audio) { update in
            progress(TransferProgress(bytes: videoBytes + update.bytes, total: update.total.map { videoBytes + $0 }))
        }
        try Task.checkCancellation()
        processing()
        fileExtension = "mp4"
        let output = directory.appendingPathComponent("processed.mp4")
        try await MediaProcessor().run(video: video, audio: audio, output: output, audioOnly: false)
        return DownloadArtifact(file: output, fileExtension: fileExtension)
    }
}
