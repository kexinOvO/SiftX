import AVFoundation
import Foundation
import XCTest
import SiftXCore
@testable import MediaPreviewNetworking

@MainActor
final class MediaPreviewTests: XCTestCase {
    private var base: URL {
        URL(string: ProcessInfo.processInfo.environment["SIFTX_PREVIEW_FIXTURE_BASE_URL"] ?? "http://127.0.0.1:18765")!
    }

    private func fixture(_ path: String, transport: MediaTransport = .direct, kind: MediaKind = .video) async throws -> MediaCandidate {
        guard ProcessInfo.processInfo.environment["SIFTX_PREVIEW_FIXTURE_BASE_URL"] != nil else {
            throw XCTSkip("Set SIFTX_PREVIEW_FIXTURE_BASE_URL after starting Scripts/fixture_server.py to run preview integration tests.")
        }
        let url = base.appendingPathComponent(path)
        var request = URLRequest(url: base.appendingPathComponent("direct.mp4")); request.httpMethod = "HEAD"; request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        } catch { throw XCTSkip("Start Scripts/fixture_server.py to run media preview integration tests.") }
        return MediaCandidate(pageURL: base.appendingPathComponent("preview.html"), sourceURL: url, kind: kind, transport: transport,
                              headers: ["Referer": base.appendingPathComponent("preview.html").absoluteString])
    }

    func testDirectRangeAndRefererArePreservedAndUnknownPathsRejected() async throws {
        let candidate = try await fixture("direct.mp4")
        let proxy = MediaPreviewProxy()
        do {
            let url = try await proxy.start(candidate: candidate)
            XCTAssertEqual(url.host, "127.0.0.1")
            var request = URLRequest(url: url); request.setValue("bytes=0-255", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
            XCTAssertEqual(data.count, 256)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-255/"), true)
            let (stats, _) = try await URLSession.shared.data(from: base.appendingPathComponent("fixture-stats"))
            let object = try JSONSerialization.jsonObject(with: stats) as! [String: Any]
            XCTAssertEqual((object["referers"] as? [String: String])?["/direct.mp4"], candidate.pageURL.absoluteString)
            let (_, unknown) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("unknown.mp4"))
            XCTAssertEqual((unknown as? HTTPURLResponse)?.statusCode, 404)
            await proxy.stop()
            do {
                var closed = URLRequest(url: url); closed.timeoutInterval = 2
                _ = try await URLSession.shared.data(for: closed)
                XCTFail("A closed preview must stop listening.")
            } catch {}
        } catch { await proxy.stop(); throw error }
    }

    func testSelectedHLSVariantIncludesAudioAndRewritesEncryptionKeys() async throws {
        var candidate = try await fixture("aes/video/index.m3u8", transport: .hls)
        candidate.audioURL = base.appendingPathComponent("aes/audio/index.m3u8")
        candidate.width = 426; candidate.height = 240
        let proxy = MediaPreviewProxy()
        do {
            let url = try await proxy.start(candidate: candidate)
            let (root, _) = try await URLSession.shared.data(from: url)
            let master = String(decoding: root, as: UTF8.self)
            XCTAssertTrue(master.contains("TYPE=AUDIO")); XCTAssertTrue(master.contains("RESOLUTION=426x240"))
            XCTAssertEqual(master.components(separatedBy: "#EXT-X-STREAM-INF:").count, 2)
            let videoURL = try XCTUnwrap(master.components(separatedBy: .newlines).last(where: { $0.hasPrefix("http://") }).flatMap(URL.init(string:)))
            let (leaf, _) = try await URLSession.shared.data(from: videoURL)
            let playlist = String(decoding: leaf, as: UTF8.self)
            XCTAssertTrue(playlist.contains("METHOD=AES-128"))
            XCTAssertFalse(playlist.contains("URI=\"key"))
            XCTAssertTrue(playlist.contains("URI=\"http://127.0.0.1:"))
            XCTAssertFalse(playlist.contains(base.absoluteString))
            await proxy.stop()
        } catch { await proxy.stop(); throw error }
    }

    func testNativePlayerDecodesDirectHLSSplitEncryptedAndDASHWithAudio() async throws {
        for (path, transport) in [("direct.mp4", MediaTransport.direct), ("hls/split.m3u8", .hls), ("aes/split.m3u8", .hls), ("dash/manifest.mpd", .dash)] {
            let baseCandidate = try await fixture(path, transport: transport)
            let choices = transport == .direct ? [baseCandidate] : try await MediaAnalyzer().candidates(for: baseCandidate)
            let candidate = try XCTUnwrap(choices.first(where: { $0.kind == .video && $0.protection == nil }))
            let proxy = MediaPreviewProxy()
            do {
                let url = try await proxy.start(candidate: candidate)
                let item = AVPlayerItem(url: url)
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(output)
                let player = AVPlayer(playerItem: item); player.isMuted = true; player.play()
                var frame = false
                for _ in 0..<200 {
                    try await Task.sleep(for: .milliseconds(100))
                    if item.status == .failed { break }
                    if output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil { frame = true; break }
                }
                XCTAssertTrue(frame, "\(path): \(item.error?.localizedDescription ?? "No decoded video frame")")
                try await Task.sleep(for: .milliseconds(500))
                let audio = try await item.asset.loadTracks(withMediaType: .audio)
                let group = try await item.asset.loadMediaSelectionGroup(for: .audible)
                XCTAssertTrue(!audio.isEmpty || group?.options.isEmpty == false, "\(path) must include its audio track")
                if let group { XCTAssertNotNil(item.currentMediaSelection.selectedMediaOption(in: group), "\(path) must select an audible track") }
                if frame {
                    let seeked = await player.seek(to: CMTime(seconds: 6, preferredTimescale: 600))
                    XCTAssertTrue(seeked, "\(path) should allow seeking")
                    player.pause()
                    XCTAssertEqual(player.rate, 0)
                }
                player.pause(); player.replaceCurrentItem(with: nil)
                await proxy.stop()
            } catch { await proxy.stop(); throw error }
        }
    }

    func testReusedHLSKeyURLGetsIndependentPreviewScopes() async throws {
        let candidate = try await fixture("aes/preview-scoped.m3u8", transport: .hls)
        let proxy = MediaPreviewProxy()
        do {
            let root = try await proxy.start(candidate: candidate)
            let (data, _) = try await URLSession.shared.data(from: root)
            let leaf = try XCTUnwrap(String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).last(where: { $0.hasPrefix("http://") }).flatMap(URL.init(string:)))
            let (playlist, _) = try await URLSession.shared.data(from: leaf)
            let keys = String(decoding: playlist, as: UTF8.self).components(separatedBy: .newlines).filter { $0.hasPrefix("#EXT-X-KEY:") }.compactMap { line in
                line.components(separatedBy: "URI=\"").last?.components(separatedBy: "\"").first.flatMap(URL.init(string:))
            }
            XCTAssertEqual(keys.count, 2)
            XCTAssertEqual(Set(keys).count, 2, "Each EXT-X-KEY scope must bypass a previous key cached at the same source URL.")
            for key in keys {
                let (data, response) = try await URLSession.shared.data(from: key)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertEqual(data.count, 16)
            }
            await proxy.stop()
        } catch { await proxy.stop(); throw error }
    }

    func testAudioPreviewHasAudioWithoutVideo() async throws {
        let candidate = try await fixture("audio.mp3", kind: .audio)
        let proxy = MediaPreviewProxy()
        do {
            let url = try await proxy.start(candidate: candidate)
            let asset = AVURLAsset(url: url)
            let playable = try await asset.load(.isPlayable)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let video = try await asset.loadTracks(withMediaType: .video)
            XCTAssertTrue(playable); XCTAssertFalse(audio.isEmpty); XCTAssertTrue(video.isEmpty)
            await proxy.stop()
        } catch { await proxy.stop(); throw error }
    }
}
