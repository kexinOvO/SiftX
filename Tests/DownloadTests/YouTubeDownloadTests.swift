import XCTest
import Foundation
import CryptoKit
import SiftXCore

@MainActor
final class YouTubeDownloadTests: XCTestCase {
    private let watch = URL(string: "https://www.youtube.com/watch?v=BaW_jenozKc")!
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    private func setup() async throws -> (DownloadManager, SharedStore, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        setenv("SIFTX_FFMPEG_PATH", root.appendingPathComponent("App/Resources/ffmpeg").path, 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SiftXYouTubeTests-\(UUID().uuidString)")
        let tools = directory.appendingPathComponent("Tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let video = directory.appendingPathComponent("fixture.mp4")
        try FileManager.default.copyItem(at: root.appendingPathComponent("Build/Fixtures/direct.mp4"), to: video)
        let audio = directory.appendingPathComponent("fixture.m4a")
        try await MediaProcessor().run(video: video, audio: nil, output: audio, audioOnly: true)
        let json = """
        {"id":"BaW_jenozKc","title":"YouTube 学习回归","duration":12,"formats":[{"format_id":"137","ext":"mp4","protocol":"https","vcodec":"avc1.640028","acodec":"none","width":426,"height":240},{"format_id":"140","ext":"m4a","protocol":"https","vcodec":"none","acodec":"mp4a.40.2","abr":128}]}
        """
        let script = """
        #!/bin/sh
        output=''
        format=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --dump-single-json) printf '%s\\n' \(quote(json)); exit 0 ;;
            --output) output="$2"; shift ;;
            --format) format="$2"; shift ;;
          esac
          shift
        done
        if [ "$format" = '140' ]; then source=\(quote(audio.path)); else source=\(quote(video.path)); fi
        count=0
        while [ "$count" -lt 15 ]; do
          printf 'SIFTX:%s:15000\\n' "$((count * 1000))"
          /bin/sleep 0.03
          count=$((count + 1))
        done
        /bin/cp "$source" "$output"
        """
        let executable = tools.appendingPathComponent("yt-dlp")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let runtime = tools.appendingPathComponent("qjs")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        let previous = ProcessInfo.processInfo.environment["SIFTX_YOUTUBE_TOOLS_PATH"]
        setenv("SIFTX_YOUTUBE_TOOLS_PATH", tools.path, 1)
        let store = try SharedStore(directory: directory.appendingPathComponent("Store"))
        try store.saveSettings(AppSettings(maxConcurrent: 1, downloadDirectory: directory.appendingPathComponent("Outputs").path,
                                          notifyCompletion: false, notifyFailure: false))
        let manager = DownloadManager(store: store)
        addTeardownBlock { [weak manager] in
            await manager?.shutdown()
            if let previous { setenv("SIFTX_YOUTUBE_TOOLS_PATH", previous, 1) }
            else { unsetenv("SIFTX_YOUTUBE_TOOLS_PATH") }
            try? FileManager.default.removeItem(at: directory)
        }
        return (manager, store, directory)
    }

    private func wait(_ manager: DownloadManager, id: UUID, complete: Bool = true) async throws -> DownloadRecord {
        for _ in 0..<600 {
            if let record = manager.records.first(where: { $0.id == id }), complete ? record.status.isTerminal : record.bytesReceived > 0 { return record }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NSError(domain: "YouTubeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "YouTube 测试等待超时"])
    }

    func testSafariRequestSplitTracksAudioHistoryAndPauseResume() async throws {
        let (manager, store, _) = try await setup()
        let choices = YouTubeURL.pageCandidates(url: watch, title: "学习视频", sessionID: "safari")
        let request = try store.enqueue(candidate: choices[0])
        manager.start()
        _ = try await wait(manager, id: request, complete: false)
        manager.pause(id: request)
        manager.resume(id: request)
        let video = try await wait(manager, id: request)
        XCTAssertEqual(video.status, .completed, video.error ?? "")
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(video.filePath)).pathExtension, "mp4")
        XCTAssertTrue(try store.pendingRequests().isEmpty)
        XCTAssertEqual(manager.records.filter { $0.id == request }.count, 1)
        let audioID = manager.enqueue(candidate: choices[1])
        let audio = try await wait(manager, id: audioID)
        XCTAssertEqual(audio.status, .completed, audio.error ?? "")
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(audio.filePath)).pathExtension, "m4a")
        let validation = URL(fileURLWithPath: "/tmp/SiftXVerifiedMedia")
        try FileManager.default.createDirectory(at: validation, withIntermediateDirectories: true)
        for record in [video, audio] {
            let file = URL(fileURLWithPath: try XCTUnwrap(record.filePath))
            try FileManager.default.copyItem(at: file, to: validation.appendingPathComponent("youtube-" + record.id.uuidString + "." + file.pathExtension))
        }
        XCTAssertEqual(try store.loadDownloads().filter { $0.status == .completed }.count, 2)
    }

    func testCancellationRetryAndMissingFormatReleaseQueue() async throws {
        let (manager, _, _) = try await setup()
        manager.start()
        let base = YouTubeURL.pageCandidates(url: watch, title: "学习视频", sessionID: "safari")[0]
        let id = manager.enqueue(candidate: base)
        _ = try await wait(manager, id: id, complete: false)
        manager.cancel(id: id)
        manager.retry(id: id)
        let retried = try await wait(manager, id: id)
        XCTAssertEqual(retried.status, .completed, retried.error ?? "")
        var obsolete = base
        obsolete.youtubeFormat = YouTubeFormatSelection(mediaFormatID: "999")
        let failedID = manager.enqueue(candidate: obsolete)
        let next = manager.enqueue(candidate: base)
        let failed = try await wait(manager, id: failedID)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.error?.contains("清晰度") == true)
        let good = try await wait(manager, id: next)
        XCTAssertEqual(good.status, .completed, good.error ?? "")
    }

    func testToolTimeoutAndOutputLimit() async throws {
        do {
            _ = try await YouTubeToolProcess().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        do {
            _ = try await YouTubeToolProcess().run(executable: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "9000000", "/dev/zero"])
            XCTFail("Expected bounded output")
        } catch { XCTAssertTrue(error.localizedDescription.contains("过大")) }
    }
}
