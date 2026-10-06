import Foundation
import SiftXCore

enum YouTubeDownloadError: LocalizedError, Sendable {
    case unavailable, timedOut, outputLimit, failed(String), formatChanged
    var errorDescription: String? {
        switch self {
        case .unavailable: return "找不到 YouTube 下载组件。请重新安装完整的 SiftX 应用。"
        case .timedOut: return "读取 YouTube 信息超时。请检查网络连接后重试。"
        case .outputLimit: return "YouTube 返回的媒体信息过大。"
        case .formatChanged: return "所选 YouTube 清晰度已变更。请重新读取链接并选择清晰度。"
        case .failed(let diagnostic):
            let text = diagnostic.lowercased()
            if text.contains("private video") || text.contains("members-only") || text.contains("sign in") || text.contains("age-restricted") || text.contains("confirm your age") {
                return "此 YouTube 视频需要登录、年龄验证或会员权限，暂时无法下载。"
            }
            if text.contains("not available in your country") || text.contains("geo") { return "此 YouTube 视频在当前地区不可用。" }
            if text.contains("unavailable") || text.contains("removed") { return "此 YouTube 视频已下架或不可用。" }
            if text.contains("403") { return "YouTube 暂时拒绝下载（403）。请稍后重新读取视频链接。" }
            if text.contains("429") { return "YouTube 暂时限制请求次数，请稍后重试。" }
            if text.contains("timed out") || text.contains("unable to download") || text.contains("network") || text.contains("certificate") {
                return "无法连接 YouTube。请检查网络或代理连接后重试。"
            }
            return "无法解析或下载此 YouTube 视频。请稍后重新读取；若持续失败，请更新 SiftX 的 YouTube 组件。"
        }
    }
}

struct YouTubeDownloader: Sendable {
    private var tools: (extractor: URL, runtime: URL) {
        get throws {
            #if DEBUG
            let root = ProcessInfo.processInfo.environment["SIFTX_YOUTUBE_TOOLS_PATH"].map { URL(fileURLWithPath: $0) }
            #else
            let root: URL? = nil
            #endif
            guard let resource = root ?? Bundle.main.resourceURL?.appendingPathComponent("YouTubeTools", isDirectory: true) else { throw YouTubeDownloadError.unavailable }
            let extractor = resource.appendingPathComponent("yt-dlp")
            let runtime = resource.appendingPathComponent("qjs")
            guard FileManager.default.isExecutableFile(atPath: extractor.path), FileManager.default.isExecutableFile(atPath: runtime.path) else {
                throw YouTubeDownloadError.unavailable
            }
            return (extractor, runtime)
        }
    }

    private func arguments(runtime: URL) -> [String] {
        ["--ignore-config", "--no-plugin-dirs", "--no-cache-dir", "--no-remote-components", "--no-js-runtimes",
         "--js-runtimes", "quickjs:\(runtime.path)", "--no-playlist", "--use-extractors", "youtube",
         "--socket-timeout", "20", "--retries", "2", "--extractor-retries", "2", "--no-colors"]
    }

    func candidates(for base: MediaCandidate) async throws -> [MediaCandidate] {
        guard base.protection == nil else { throw MediaError.protectedMedia }
        guard let watch = YouTubeURL.canonical(base.sourceURL) else { throw MediaError.invalidURL }
        let tools = try tools
        let data = try await YouTubeToolProcess().run(executable: tools.extractor,
            arguments: arguments(runtime: tools.runtime) + ["--dump-single-json", "--skip-download", "--", watch.absoluteString], timeout: 120)
        try Task.checkCancellation()
        return try YouTubeMedia.choices(data: data, base: base)
    }

    func download(candidate: MediaCandidate, directory: URL,
                  progress: @escaping @Sendable (TransferProgress) -> Void,
                  processing: @escaping @Sendable () -> Void) async throws -> DownloadArtifact {
        let choices = try await candidates(for: candidate)
        let selected: MediaCandidate?
        if let selection = candidate.youtubeFormat {
            selected = choices.first { $0.youtubeFormat == selection && $0.kind == candidate.kind }
        } else { selected = choices.first { $0.kind == candidate.kind } }
        guard let choice = selected, let selection = choice.youtubeFormat else { throw YouTubeDownloadError.formatChanged }
        let tools = try tools
        let media = directory.appendingPathComponent(candidate.kind == .audio ? "youtube-audio.m4a" : "youtube-video.mp4")
        // A pinned format identity also owns its partial files across pause/retry.
        let identity = try JSONEncoder().encode(selection)
        let identityFile = directory.appendingPathComponent("youtube-format.json")
        if (try? Data(contentsOf: identityFile)) != identity {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("youtube-") {
                try FileManager.default.removeItem(at: file)
            }
            try identity.write(to: identityFile, options: .atomic)
        }
        let watch = choice.sourceURL
        func fetch(_ id: String, to file: URL, offset: Int64) async throws -> Int64 {
            let args = arguments(runtime: tools.runtime) + ["--format", id, "--output", file.path,
                "--continue", "--no-overwrites", "--fixup", "never", "--hls-prefer-native", "--abort-on-unavailable-fragments",
                "--newline", "--progress", "--progress-delta", "0.25", "--quiet", "--no-warnings",
                "--progress-template", "download:SIFTX:%(progress.downloaded_bytes)d:%(progress.total_bytes,progress.total_bytes_estimate)s",
                "--match-filter", "!is_live & !is_upcoming", "--", watch.absoluteString]
            _ = try await YouTubeToolProcess().run(executable: tools.extractor, arguments: args, directory: directory) { update in
                progress(TransferProgress(bytes: offset + update.bytes, total: choice.estimatedBytes ?? update.total.map { offset + $0 }))
            }
            try Task.checkCancellation()
            let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            guard size > 0 else { throw DownloadError.emptyFile }
            return size
        }
        let mediaBytes = try await fetch(selection.mediaFormatID, to: media, offset: 0)
        var audio: URL?
        var bytes = mediaBytes
        if let audioID = selection.audioFormatID {
            let file = directory.appendingPathComponent("youtube-audio.m4a")
            bytes += try await fetch(audioID, to: file, offset: mediaBytes)
            audio = file
        }
        progress(TransferProgress(bytes: bytes, total: bytes))
        try Task.checkCancellation()
        processing()
        let ext = candidate.kind == .audio ? "m4a" : "mp4"
        let output = directory.appendingPathComponent("processed.\(ext)")
        try await MediaProcessor().run(video: media, audio: audio, output: output, audioOnly: candidate.kind == .audio)
        return DownloadArtifact(file: output, fileExtension: ext)
    }
}

/// Executes bundled tools directly with bounded output and cancellation; no shell or user configuration.
final class YouTubeToolProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var timeoutWork: DispatchWorkItem?
    private var cancelled = false
    private var expired = false
    private var overflow = false
    private var output = Data()
    private var diagnostic = Data()
    private var lineBuffer = Data()

    func run(executable: URL, arguments: [String], directory: URL? = nil, timeout: TimeInterval? = nil,
             progress: (@Sendable (TransferProgress) -> Void)? = nil) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let process = Process()
                process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
                process.standardInput = FileHandle.nullDevice
                // Do not inherit user Python/plugin/proxy environment into the bundled tool.
                process.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": FileManager.default.temporaryDirectory.path,
                                       "LANG": "en_US.UTF-8", "PYTHONNOUSERSITE": "1"]
                let stdout = Pipe(); let stderr = Pipe()
                process.standardOutput = stdout; process.standardError = stderr
                stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.consume(handle.availableData, error: false, progress: progress) }
                stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.consume(handle.availableData, error: true, progress: progress) }
                let timer = DispatchWorkItem { [weak self] in self?.expire() }
                process.terminationHandler = { [weak self] process in
                    self?.cancelTimer()
                    stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil
                    self?.consume(stdout.fileHandleForReading.readDataToEndOfFile(), error: false, progress: progress)
                    self?.consume(stderr.fileHandleForReading.readDataToEndOfFile(), error: true, progress: progress)
                    guard let self else { continuation.resume(throwing: CancellationError()); return }
                    self.lock.lock()
                    let cancelled = self.cancelled; let expired = self.expired; let overflow = self.overflow
                    let data = self.output; let details = String(decoding: self.diagnostic, as: UTF8.self)
                    self.process = nil
                    self.lock.unlock()
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                    else if expired { continuation.resume(throwing: YouTubeDownloadError.timedOut) }
                    else if overflow { continuation.resume(throwing: YouTubeDownloadError.outputLimit) }
                    else if process.terminationStatus != 0 { continuation.resume(throwing: YouTubeDownloadError.failed(details)) }
                    else { continuation.resume(returning: data) }
                }
                lock.lock()
                if cancelled {
                    lock.unlock()
                    stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: CancellationError()); return
                }
                self.process = process
                self.timeoutWork = timer
                do {
                    try process.run()
                    lock.unlock()
                    if let timeout { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer) }
                } catch {
                    self.process = nil; lock.unlock()
                    stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { self.cancel() }
    }

    private func consume(_ data: Data, error: Bool, progress: (@Sendable (TransferProgress) -> Void)?) {
        guard !data.isEmpty else { return }
        lock.lock()
        if error { diagnostic.append(data.prefix(max(0, 65_536 - diagnostic.count))) }
        else if progress == nil {
            if output.count + data.count > 8_388_608 { overflow = true }
            else { output.append(data) }
        }
        var updates: [TransferProgress] = []
        if let _ = progress, !error {
            lineBuffer.append(data)
            while let index = lineBuffer.firstIndex(of: 10) {
                let line = String(decoding: lineBuffer.prefix(upTo: index), as: UTF8.self)
                lineBuffer.removeSubrange(...index)
                let fields = line.split(separator: ":")
                if fields.count == 3, fields[0] == "SIFTX", let bytes = Int64(fields[1]), bytes >= 0 {
                    let total = Int64(fields[2]).flatMap { $0 > 0 ? $0 : nil }
                    updates.append(TransferProgress(bytes: bytes, total: total))
                }
            }
            if lineBuffer.count > 65_536 { lineBuffer.removeAll() }
        }
        let terminate = overflow ? process : nil
        lock.unlock()
        updates.forEach { progress?($0) }
        if terminate?.isRunning == true { terminate?.terminate() }
    }

    private func cancel() {
        lock.lock(); cancelled = true; let process = process; lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
    private func cancelTimer() {
        lock.lock(); let timer = timeoutWork; timeoutWork = nil; lock.unlock()
        timer?.cancel()
    }
    private func expire() {
        lock.lock(); expired = true; let process = process; lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
}
