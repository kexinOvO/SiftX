import Foundation

/// FFmpeg sees only assembled local files; it cannot fetch a URL or a manifest.
final class MediaProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var diagnostic = Data()

    static var executableURL: URL? {
        let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil)
            ?? Bundle.main.resourceURL?.appendingPathComponent("Tools/ffmpeg")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        #if DEBUG
        for path in [ProcessInfo.processInfo.environment["SIFTX_FFMPEG_PATH"], "/usr/local/bin/ffmpeg", "/opt/homebrew/bin/ffmpeg"].compactMap({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        #endif
        return nil
    }

    func run(video: URL, audio: URL?, output: URL, audioOnly: Bool) async throws {
        guard let executable = Self.executableURL else { throw DownloadError.processorUnavailable }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = executable
                var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-protocol_whitelist", "file,pipe", "-i", video.path]
                if let audio {
                    arguments += ["-protocol_whitelist", "file,pipe", "-i", audio.path, "-map", "0:v:0", "-map", "1:a:0"]
                } else if audioOnly { arguments += ["-map", "0:a:0"] }
                else { arguments += ["-map", "0:v:0?", "-map", "0:a:0?"] }
                arguments += ["-c", "copy"]
                if ["mp4", "m4a", "mov"].contains(output.pathExtension) { arguments += ["-movflags", "+faststart"] }
                arguments.append(output.path)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                let errors = Pipe()
                process.standardError = errors
                errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    self?.appendDiagnostic(data)
                }
                process.terminationHandler = { [weak self] process in
                    errors.fileHandleForReading.readabilityHandler = nil
                    self?.appendDiagnostic(errors.fileHandleForReading.readDataToEndOfFile())
                    guard let self else { continuation.resume(throwing: CancellationError()); return }
                    self.lock.lock()
                    let cancelled = self.cancelled
                    let diagnostic = String(data: self.diagnostic, encoding: .utf8) ?? "处理组件无法读取媒体。"
                    self.process = nil
                    self.lock.unlock()
                    if cancelled { continuation.resume(throwing: CancellationError()) }
                    else if process.terminationStatus == 0 { continuation.resume() }
                    else {
                        // Bound diagnostics and omit paths that expose a user's folder.
                        let cleaned = diagnostic.replacingOccurrences(of: video.deletingLastPathComponent().path, with: "临时目录")
                        continuation.resume(throwing: DownloadError.processingFailed(String(cleaned.suffix(800))))
                    }
                }
                lock.lock()
                if cancelled {
                    lock.unlock()
                    errors.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.process = process
                do {
                    try process.run()
                    lock.unlock()
                } catch {
                    self.process = nil
                    lock.unlock()
                    errors.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { self.cancel() }
        let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0 else { throw DownloadError.emptyFile }
    }

    private func appendDiagnostic(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if diagnostic.count < 32_768 { diagnostic.append(data.prefix(32_768 - diagnostic.count)) }
        lock.unlock()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
}
