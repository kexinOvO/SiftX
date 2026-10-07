import XCTest
import AVFoundation
import SiftXCore

@MainActor
final class BilibiliDownloadTests: XCTestCase {
    private let video = URL(string: "https://www.bilibili.com/video/BV1QuYX6XEZ4/?p=2")!
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    private func setup() async throws -> (DownloadManager, SharedStore, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ffmpeg = root.appendingPathComponent("App/Resources/ffmpeg")
        setenv("SIFTX_FFMPEG_PATH", ffmpeg.path, 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SiftXBilibiliTests-\(UUID().uuidString)")
        let tools = directory.appendingPathComponent("Tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let fixture = root.appendingPathComponent("Build/Fixtures/direct.mp4")
        let silent = directory.appendingPathComponent("video-only.mp4")
        _ = try await YouTubeToolProcess().run(executable: ffmpeg,
            arguments: ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-protocol_whitelist", "file,pipe",
                        "-i", fixture.path, "-map", "0:v:0", "-c", "copy", silent.path], timeout: 10)
        let audio = directory.appendingPathComponent("audio-only.m4a")
        try await MediaProcessor().run(video: fixture, audio: nil, output: audio, audioOnly: true)
        let originalAudio = try await AVURLAsset(url: silent).loadTracks(withMediaType: .audio)
        XCTAssertTrue(originalAudio.isEmpty)
        let json = """
        {"id":"BV1QuYX6XEZ4","extractor_key":"BiliBili","webpage_url":"\(video.absoluteString)","title":"B站回归视频","duration":12,"formats":[{"format_id":"100026","ext":"mp4","protocol":"https","vcodec":"avc1.640028","acodec":"none","width":426,"height":240},{"format_id":"30280","ext":"m4a","protocol":"https","vcodec":"none","acodec":"mp4a.40.2","abr":192}]}
        """
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" >> \(quote(directory.appendingPathComponent("arguments.log").path))
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
        if [ "$format" = '30280' ]; then source=\(quote(audio.path)); else source=\(quote(silent.path)); fi
        count=0
        while [ "$count" -lt 12 ]; do
          printf 'SIFTX:%s:12000\\n' "$((count * 1000))"
          /bin/sleep 0.025
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
        throw NSError(domain: "BilibiliTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "B站下载测试等待超时"])
    }

    func testSafariRequestPairsSilentVideoWithAudioAndPersistsSelectedPart() async throws {
        let (manager, store, directory) = try await setup()
        let choices = BilibiliURL.pageCandidates(url: video, title: "B站视频", sessionID: "safari")
        let request = try store.enqueue(candidate: choices[0])
        manager.start()
        let downloaded = try await wait(manager, id: request)
        XCTAssertEqual(downloaded.status, .completed, downloaded.error ?? "")
        let file = URL(fileURLWithPath: try XCTUnwrap(downloaded.filePath))
        XCTAssertEqual(file.pathExtension, "mp4")
        let asset = AVURLAsset(url: file)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(downloaded.candidate.sourceURL, video)
        XCTAssertTrue(try store.pendingRequests().isEmpty)
        XCTAssertEqual(manager.records.filter { $0.id == request }.count, 1)
        let args = try String(contentsOf: directory.appendingPathComponent("arguments.log"), encoding: .utf8)
        XCTAssertTrue(args.contains("--use-extractors\nbilibili\n"))
        XCTAssertTrue(args.contains(video.absoluteString))
        XCTAssertTrue(args.contains("--format\n100026\n"))
        XCTAssertTrue(args.contains("--format\n30280\n"))
        XCTAssertFalse(args.contains("--cookies"))
        let audioID = manager.enqueue(candidate: choices[1])
        let audioRecord = try await wait(manager, id: audioID)
        XCTAssertEqual(audioRecord.status, .completed, audioRecord.error ?? "")
        let audioFile = URL(fileURLWithPath: try XCTUnwrap(audioRecord.filePath))
        let audioOnlyTracks = try await AVURLAsset(url: audioFile).loadTracks(withMediaType: .video)
        XCTAssertEqual(audioFile.pathExtension, "m4a")
        XCTAssertTrue(audioOnlyTracks.isEmpty)
        XCTAssertEqual(try store.loadDownloads().filter { $0.status == .completed }.count, 2)
    }

    func testPauseResumeMissingFormatAndNextDownloadReleaseQueue() async throws {
        let (manager, _, _) = try await setup()
        manager.start()
        let base = BilibiliURL.pageCandidates(url: video, title: "B站视频", sessionID: "safari")[0]
        let id = manager.enqueue(candidate: base)
        _ = try await wait(manager, id: id, complete: false)
        manager.pause(id: id)
        manager.resume(id: id)
        let resumed = try await wait(manager, id: id)
        XCTAssertEqual(resumed.status, .completed, resumed.error ?? "")
        var obsolete = base
        obsolete.bilibiliFormat = SiteFormatSelection(mediaFormatID: "999")
        let failedID = manager.enqueue(candidate: obsolete)
        let nextID = manager.enqueue(candidate: base)
        let failed = try await wait(manager, id: failedID)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(failed.error?.contains("B站清晰度") == true)
        let next = try await wait(manager, id: nextID)
        XCTAssertEqual(next.status, .completed, next.error ?? "")
    }
}
