import Foundation
import Darwin
import OSLog
import SiftXCore

final class DownloadFolder: @unchecked Sendable {
    let url: URL
    private var scoped: Bool
    private static let logger = Logger(subsystem: "com.siftx.SiftX", category: "Download")

    init(settings: AppSettings) throws {
        if let bookmark = settings.downloadBookmark {
            var stale = false
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch { throw DownloadError.unavailableFolder }
            scoped = url.startAccessingSecurityScopedResource()
        } else if let directory = settings.downloadDirectory, !directory.isEmpty {
            url = URL(fileURLWithPath: directory, isDirectory: true)
            scoped = false
        } else {
            url = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            scoped = false
        }
        do {
            let manager = FileManager.default
            var isDirectory = ObjCBool(false)
            if !manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                try manager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            // The sandbox's Downloads URL can be a symlink to ~/Downloads.
            // fileExists:isDirectory follows that link; resourceValues reports
            // the link itself and is not a suitable directory access check.
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw DownloadError.unavailableFolder }
            let probe = url.appendingPathComponent(".siftx-access-\(UUID().uuidString)")
            let descriptor = probe.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            close(descriptor)
            try manager.removeItem(at: probe)
        } catch {
            let underlying = error as NSError
            Self.logger.error("Download directory access failed: domain=\(underlying.domain, privacy: .private), code=\(underlying.code, privacy: .private)")
            if scoped { url.stopAccessingSecurityScopedResource(); scoped = false }
            if underlying.domain == NSPOSIXErrorDomain, [ENOSPC, EDQUOT].contains(Int32(underlying.code)) {
                throw DownloadError.disk("磁盘空间不足，请释放空间后重试。")
            }
            throw DownloadError.unavailableFolder
        }
    }

    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

/// A history file retains its own access grant even after the default folder
/// changes. Resolving a bookmark also follows files renamed/moved in Finder.
final class DownloadFileLease: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    private let folder: DownloadFolder?

    init(record: DownloadRecord, settings: AppSettings) throws {
        if let bookmark = record.fileBookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                      relativeTo: nil, bookmarkDataIsStale: &stale), resolved.isFileURL {
                url = resolved
                scoped = resolved.startAccessingSecurityScopedResource()
                folder = scoped ? nil : (try? DownloadFolder(settings: settings))
                return
            }
        }
        guard let path = record.filePath, !path.isEmpty else { throw DownloadError.missingFile }
        url = URL(fileURLWithPath: path)
        scoped = false
        folder = try? DownloadFolder(settings: settings)
    }

    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    func deleteIfPresent() throws {
        do {
            guard try url.checkResourceIsReachable() else { return }
            try FileManager.default.removeItem(at: url)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return }
            throw error
        }
    }

    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }

    static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
    }
}

enum DownloadFiles {
    static func stagingDirectory(id: UUID, root: URL? = nil) throws -> URL {
        let base: URL
        if let root { base = root }
        else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            base = support.appendingPathComponent("SiftX/Transfers", isDirectory: true)
        }
        let directory = base.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func discardStaging(id: UUID, root: URL? = nil) {
        if let directory = try? stagingDirectory(id: id, root: root) { try? FileManager.default.removeItem(at: directory) }
    }

    static func outputExtension(candidate: MediaCandidate, plan: MediaPlan? = nil) -> String {
        let suggested = plan?.outputExtension ?? candidate.sourceURL.pathExtension.lowercased()
        let valid = Set(["mp4", "mov", "webm", "mkv", "m4v", "m4a", "aac", "mp3", "wav", "ogg", "flac", "opus", "aiff", "caf"])
        return valid.contains(suggested) ? suggested : (candidate.kind == .audio ? "m4a" : "mp4")
    }

    /// Copy into the destination filesystem before an exclusive atomic rename.
    /// A filename collision can never overwrite another download or user file.
    static func commit(staged: URL, candidate: MediaCandidate, fileExtension: String, folder: URL, collisionPolicy: String) throws -> URL {
        let preferred = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = preferred.isEmpty ? candidate.pageTitle : preferred
        let base = SafeFilename.sanitize(title, fallback: "Media")
        let temporary = folder.appendingPathComponent(".siftx-\(UUID().uuidString).partial")
        do {
            try FileManager.default.copyItem(at: staged, to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            for number in 1...10_000 {
                try Task.checkCancellation()
                let suffix = number == 1 ? "" : " \(number)"
                let target = folder.appendingPathComponent("\(base)\(suffix).\(fileExtension)")
                let result = temporary.path.withCString { source in
                    target.path.withCString { destination in renamex_np(source, destination, UInt32(RENAME_EXCL)) }
                }
                if result == 0 { return target }
                let errorCode = errno
                if errorCode == EEXIST {
                    if collisionPolicy == "skip" { throw DownloadError.fileExists }
                    continue
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode), userInfo: nil)
            }
            throw DownloadError.disk("同名文件过多，请选择其他下载目录。")
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func concatenate(_ chunks: [URL], destination: URL) throws {
        guard !chunks.isEmpty else { throw DownloadError.emptyFile }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw DownloadError.disk("无法创建媒体处理文件。") }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for chunk in chunks {
            try Task.checkCancellation()
            let input = try FileHandle(forReadingFrom: chunk)
            defer { try? input.close() }
            while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: data)
            }
        }
        try output.synchronize()
    }
}
