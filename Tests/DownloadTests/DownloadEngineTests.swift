import XCTest
import Foundation
import CryptoKit
import SiftXCore

@MainActor
final class DownloadEngineTests: XCTestCase {
    private let base = URL(string: ProcessInfo.processInfo.environment["SIFTX_FIXTURE_BASE_URL"] ?? "http://127.0.0.1:18765")!

    private func context(concurrent: Int = 2) throws -> (DownloadManager, SharedStore, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("SIFTX_FFMPEG_PATH", root.appendingPathComponent("App/Resources/ffmpeg").path, 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SiftXDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SharedStore(directory: directory.appendingPathComponent("Store"))
        try store.saveSettings(AppSettings(maxConcurrent: concurrent, downloadDirectory: directory.appendingPathComponent("Outputs").path,
                                          notifyCompletion: false, notifyFailure: false))
        let manager = DownloadManager(store: store)
        addTeardownBlock { [weak manager] in
            await manager?.shutdown()
            // Run after the test releases its manager and store; never unlink an open WAL database.
            try? FileManager.default.removeItem(at: directory)
        }
        return (manager, store, directory)
    }

    private func candidate(_ path: String, title: String = "测试媒体", kind: MediaKind = .video, transport: MediaTransport = .direct) -> MediaCandidate {
        MediaCandidate(title: title, pageTitle: "SiftX 测试网页", pageURL: base.appendingPathComponent("test.html"),
                       sourceURL: base.appendingPathComponent(path), kind: kind, transport: transport)
    }

    private func wait(_ manager: DownloadManager, id: UUID, timeout: TimeInterval = 30,
                      condition: (DownloadRecord) -> Bool = { $0.status.isTerminal }) async throws -> DownloadRecord {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let record = manager.records.first(where: { $0.id == id }), condition(record) { return record }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "SiftXDownloadTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "下载等待超时：\(manager.records.first(where: { $0.id == id })?.error ?? "")"])
    }

    private func cleanup(_ manager: DownloadManager, directory: URL) async {
        await manager.shutdown()
    }

    func testDirectAudioQueueCollisionAndDurableHistory() async throws {
        let (manager, store, directory) = try context(concurrent: 1)
        manager.start()
        let one = manager.enqueue(candidate: candidate("direct.mp4", title: "危险/名称:*?"))
        let two = manager.enqueue(candidate: candidate("direct.mp4", title: "危险/名称:*?"))
        let audio = manager.enqueue(candidate: candidate("audio.mp3", title: "音频", kind: .audio))
        XCTAssertLessThanOrEqual(manager.activeCount, 1)
        let first = try await wait(manager, id: one)
        let second = try await wait(manager, id: two)
        let third = try await wait(manager, id: audio)
        XCTAssertEqual(first.status, .completed, first.error ?? "")
        XCTAssertEqual(second.status, .completed, second.error ?? "")
        XCTAssertEqual(third.status, .completed, third.error ?? "")
        XCTAssertNotEqual(first.filePath, second.filePath)
        XCTAssertFalse(URL(fileURLWithPath: try XCTUnwrap(first.filePath)).lastPathComponent.contains(":"))
        XCTAssertEqual(try store.loadDownloads().filter { $0.status == .completed }.count, 3)
        XCTAssertEqual(first.bytesReceived, first.totalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(third.filePath)))
        await cleanup(manager, directory: directory)
    }

    func testPauseImmediateResumeProducesIdenticalFile() async throws {
        let (manager, _, directory) = try context()
        manager.start()
        let id = manager.enqueue(candidate: candidate("slow.mp4"))
        _ = try await wait(manager, id: id, condition: { $0.status == .downloading && $0.bytesReceived > 0 })
        manager.pause(id: id)
        XCTAssertEqual(manager.records.first(where: { $0.id == id })?.status, .paused)
        manager.resume(id: id)
        let record = try await wait(manager, id: id)
        XCTAssertEqual(record.status, .completed, record.error ?? "")
        let saved = try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(record.filePath)))
        let (expected, _) = try await URLSession.shared.data(from: base.appendingPathComponent("slow.mp4"))
        XCTAssertEqual(SHA256.hash(data: saved), SHA256.hash(data: expected))
        await cleanup(manager, directory: directory)
    }

    func testCancellationRetryAndFailureDoNotBlockQueue() async throws {
        let (manager, _, directory) = try context(concurrent: 1)
        manager.start()
        let id = manager.enqueue(candidate: candidate("slow.mp4"))
        _ = try await wait(manager, id: id, condition: { $0.bytesReceived > 0 })
        manager.cancel(id: id)
        XCTAssertEqual(manager.records.first(where: { $0.id == id })?.status, .cancelled)
        // Retrying immediately also exercises cancellation cleanup ordering.
        manager.retry(id: id)
        let retried = try await wait(manager, id: id)
        XCTAssertEqual(retried.status, .completed, retried.error ?? "")
        let failedID = manager.enqueue(candidate: candidate("status/403"))
        let goodID = manager.enqueue(candidate: candidate("direct.mp4"))
        let failed = try await wait(manager, id: failedID)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.error?.contains("403") == true)
        let queued = try await wait(manager, id: goodID)
        XCTAssertEqual(queued.status, .completed, queued.error ?? "")
        await cleanup(manager, directory: directory)
    }

    func testServerIgnoringRangeResetsPartialInsteadOfAppending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SiftXRangeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = base.appendingPathComponent("no-range.mp4")
        let destination = directory.appendingPathComponent("download.partial")
        try Data(repeating: 0x7f, count: 1024).write(to: destination)
        let metadata: [String: Any] = ["url": source.absoluteString, "validator": "\"fixture\"", "total": 2048]
        try JSONSerialization.data(withJSONObject: metadata).write(to: destination.appendingPathExtension("http.json"))
        _ = try await HTTPTransfer(url: source, headers: [:], destination: destination, progress: { _ in }).run()
        let (expected, _) = try await URLSession.shared.data(from: source)
        XCTAssertEqual(try Data(contentsOf: destination), expected)
    }

    func testInterruptedConnectionRetriesAndMalformedRangeRestartsSafely() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SiftXRetryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let expectedURL = base.appendingPathComponent("direct.mp4")
        let (expected, _) = try await URLSession.shared.data(from: expectedURL)
        let truncated = directory.appendingPathComponent("truncated.partial")
        _ = try await TransferRetry.download(url: base.appendingPathComponent("truncated.mp4"), headers: [:], destination: truncated, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: truncated), expected)

        let source = base.appendingPathComponent("range-bad.mp4")
        let malformed = directory.appendingPathComponent("bad-range.partial")
        try expected.prefix(1024).write(to: malformed)
        let metadata: [String: Any] = ["url": source.absoluteString, "validator": "\"siftx-fixture-v1\"", "total": expected.count]
        try JSONSerialization.data(withJSONObject: metadata).write(to: malformed.appendingPathExtension("http.json"))
        _ = try await TransferRetry.download(url: source, headers: [:], destination: malformed, progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: malformed), expected)
    }

    func testExclusiveFileCommitNeverOverwritesExistingMedia() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SiftXCommitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("source.partial")
        let original = directory.appendingPathComponent("同名文件.mp4")
        try Data("original".utf8).write(to: original)
        try Data("new file".utf8).write(to: staged)
        let item = candidate("direct.mp4", title: "同名文件")
        XCTAssertThrowsError(try DownloadFiles.commit(staged: staged, candidate: item, fileExtension: "mp4", folder: directory, collisionPolicy: "skip"))
        let renamed = try DownloadFiles.commit(staged: staged, candidate: item, fileExtension: "mp4", folder: directory, collisionPolicy: "rename")
        XCTAssertEqual(renamed.lastPathComponent, "同名文件 2.mp4")
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: renamed), Data("new file".utf8))
    }

    func testDownloadFolderFollowsSandboxStyleDownloadsSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SiftXSymlinkTests-\(UUID().uuidString)")
        let realDownloads = directory.appendingPathComponent("Downloads", isDirectory: true)
        let sandboxData = directory.appendingPathComponent("App/Data", isDirectory: true)
        try FileManager.default.createDirectory(at: realDownloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sandboxData, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let linkedDownloads = sandboxData.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: linkedDownloads.path, withDestinationPath: "../../Downloads")
        let lease = try DownloadFolder(settings: AppSettings(downloadDirectory: linkedDownloads.path))
        let staged = directory.appendingPathComponent("input.partial")
        try Data("verified media".utf8).write(to: staged)
        let output = try DownloadFiles.commit(staged: staged, candidate: candidate("direct.mp4", title: "符号链接下载"),
                                             fileExtension: "mp4", folder: lease.url, collisionPolicy: "rename")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: realDownloads.appendingPathComponent("符号链接下载.mp4")), Data("verified media".utf8))
    }

    func testInterruptedStatusRecoveryAndDurableSafariRequest() async throws {
        let (unused, store, directory) = try context()
        await unused.shutdown()
        let interrupted = DownloadRecord(candidate: candidate("direct.mp4"), status: .downloading, bytesReceived: 400)
        try store.saveDownload(interrupted)
        let manager = DownloadManager(store: store)
        XCTAssertEqual(manager.records.first?.status, .paused)
        XCTAssertEqual(try store.loadDownloads().first?.status, .paused)
        let request = try store.enqueue(candidate: candidate("audio.mp3", kind: .audio))
        manager.start()
        let completed = try await wait(manager, id: request)
        XCTAssertEqual(completed.status, .completed, completed.error ?? "")
        XCTAssertTrue(try store.pendingRequests().isEmpty)
        XCTAssertEqual(manager.records.filter { $0.id == request }.count, 1)
        await cleanup(manager, directory: directory)
    }

    func testHLSMasterSingleSplitAudioAndDASHGenerateMediaFiles() async throws {
        let (manager, _, directory) = try context()
        manager.start()
        let paths: [(String, MediaTransport)] = [("hls/master.m3u8", .hls), ("hls/single.m3u8", .hls), ("hls/split.m3u8", .hls), ("dash/manifest.mpd", .dash)]
        let ids = paths.map { manager.enqueue(candidate: candidate($0.0, title: $0.0, transport: $0.1)) }
        for id in ids {
            let record = try await wait(manager, id: id, timeout: 60)
            XCTAssertEqual(record.status, .completed, record.error ?? "")
            if let path = record.filePath {
                let size = try URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                XCTAssertGreaterThan(size, 1000)
            }
        }
        // Keep a validation copy so the external ffprobe verification checks the
        // actual downloaded outputs rather than only source fixtures.
        let validation = URL(fileURLWithPath: "/tmp/SiftXVerifiedMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: validation, withIntermediateDirectories: true)
        for record in manager.records where record.status == .completed {
            guard let path = record.filePath else { continue }
            let destination = validation.appendingPathComponent(record.id.uuidString + ".mp4")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
        }
        await cleanup(manager, directory: directory)
    }

    func testProtectedMediaFailsWithClearExplanation() async throws {
        let (manager, _, directory) = try context()
        manager.start()
        let id = manager.enqueue(candidate: candidate("protected.m3u8", transport: .hls))
        let failed = try await wait(manager, id: id)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.error?.contains("DRM") == true, failed.error ?? "")
        await cleanup(manager, directory: directory)
    }

    func testHistoryFileAccessSurvivesFolderChangeAndMissingFileRemoval() async throws {
        let (manager, store, directory) = try context()
        manager.start()
        let originalID = manager.enqueue(candidate: candidate("direct.mp4", title: "保留历史访问"))
        let original = try await wait(manager, id: originalID)
        XCTAssertEqual(original.status, .completed, original.error ?? "")
        XCTAssertNotNil(original.fileBookmark)
        XCTAssertNotNil(try store.loadDownloads().first(where: { $0.id == originalID })?.fileBookmark)
        var settings = try store.loadSettings()
        settings.downloadDirectory = directory.appendingPathComponent("ChangedFolder").path
        try store.saveSettings(settings)
        manager.refreshSettings()
        let lease = try DownloadFileLease(record: original, settings: settings)
        XCTAssertTrue(lease.exists)
        manager.remove(id: originalID, deleteFile: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(original.filePath)))
        XCTAssertFalse(manager.records.contains { $0.id == originalID })

        let missingID = manager.enqueue(candidate: candidate("direct.mp4", title: "文件已删除"))
        let missing = try await wait(manager, id: missingID)
        XCTAssertEqual(missing.status, .completed, missing.error ?? "")
        try FileManager.default.removeItem(atPath: XCTUnwrap(missing.filePath))
        manager.remove(id: missingID, deleteFile: true)
        XCTAssertFalse(manager.records.contains { $0.id == missingID })
        XCTAssertNil(manager.lastError)
        await cleanup(manager, directory: directory)
    }

    func testHTTP200LoginHTMLAndJSONAreRejectedInsteadOfSavedAsMedia() async throws {
        let (manager, _, directory) = try context()
        manager.start()
        for path in ["html-error.mp4", "json-error.mp4"] {
            let id = manager.enqueue(candidate: candidate(path, title: "过期媒体链接"))
            let failed = try await wait(manager, id: id)
            XCTAssertEqual(failed.status, .failed, failed.error ?? "")
            XCTAssertTrue(failed.error?.contains("登录") == true, failed.error ?? "")
            XCTAssertNil(failed.filePath)
            XCTAssertEqual(failed.bytesReceived, 0)
        }
        XCTAssertTrue(manager.records.allSatisfy { $0.status != .completed })
        let outputs = directory.appendingPathComponent("Outputs")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outputs.path).isEmpty)
        await cleanup(manager, directory: directory)
    }
}
