import Foundation
import XCTest
@testable import SiftXCore

final class AnalyzerTests: XCTestCase, @unchecked Sendable {
    private func analyzer() -> MediaAnalyzer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        return MediaAnalyzer(session: URLSession(configuration: configuration))
    }
    private func candidate(path: String, transport: MediaTransport = .hls) -> MediaCandidate {
        MediaCandidate(sessionID: "test-session", title: "Fixture", pageTitle: "Page", pageURL: URL(string: "https://fixture.invalid/page")!, sourceURL: URL(string: "https://fixture.invalid/\(path)")!, transport: transport)
    }
    func testHLSMasterChoicesAndSplitAudioDownloadPlan() async throws {
        let analyzer = analyzer()
        let choices = try await analyzer.candidates(for: candidate(path: "master.m3u8"))
        XCTAssertEqual(choices.count, 3)
        XCTAssertEqual(choices[0].quality, "1080p")
        XCTAssertEqual(choices[1].quality, "720p")
        XCTAssertEqual(choices[2].kind, .audio)
        XCTAssertTrue(choices[0].hasAudio)
        XCTAssertEqual(choices[0].audioURL?.lastPathComponent, "audio.m3u8")
        let plan = try await analyzer.plan(for: choices[0])
        XCTAssertEqual(plan.segments.map { $0.url.lastPathComponent }, ["init.mp4", "video1.m4s", "video2.m4s"])
        XCTAssertEqual(plan.audioSegments.map { $0.url.lastPathComponent }, ["audio1.aac", "audio2.aac"])
    }
    func testHLSMasterInheritedProtectionAndLiveAreDisabled() async throws {
        let analyzer = analyzer()
        let choices = try await analyzer.candidates(for: candidate(path: "protected-master.m3u8"))
        XCTAssertEqual(choices.count, 1)
        XCTAssertNotNil(choices[0].protection)
        let live = try await analyzer.candidates(for: candidate(path: "live.m3u8"))
        XCTAssertTrue(live[0].protection?.contains("直播") == true)
        do { _ = try await analyzer.plan(for: candidate(path: "live.m3u8")); XCTFail("live must not be downloaded as a truncated file") }
        catch { XCTAssertTrue(error.localizedDescription.contains("直播")) }
    }
    func testAES128IsDownloadableAndManifestLengthIsNotMediaSize() async throws {
        let analyzer = analyzer()
        var source = candidate(path: "encrypted.m3u8")
        source.estimatedBytes = 54_300
        let choices = try await analyzer.candidates(for: source)
        let choice = try XCTUnwrap(choices.first)
        XCTAssertNil(choice.protection)
        XCTAssertNil(choice.estimatedBytes)
        XCTAssertEqual(choice.encryption, .aes128)
        XCTAssertEqual(choice.duration, 2)
        let plan = try await analyzer.plan(for: choice)
        XCTAssertEqual(plan.segments.first?.encryption?.keyURL.absoluteString, "https://fixture.invalid/key")
    }
    func testEncryptedMasterAndIndependentAudioRetainEncryption() async throws {
        let analyzer = analyzer()
        let choices = try await analyzer.candidates(for: candidate(path: "encrypted-master.m3u8"))
        XCTAssertEqual(choices.count, 2)
        XCTAssertTrue(choices.allSatisfy { $0.protection == nil && $0.encryption == .aes128 })
        XCTAssertEqual(choices[0].estimatedBytes, 250_000)
        let plan = try await analyzer.plan(for: choices[0])
        XCTAssertNotNil(plan.segments[0].encryption)
        XCTAssertNotNil(plan.audioSegments[0].encryption)
    }
    func testHLSNestedCycleTerminates() async throws {
        let analyzer = analyzer()
        let choices = try await analyzer.candidates(for: candidate(path: "cycle.m3u8"))
        XCTAssertNotNil(choices[0].protection)
        do { _ = try await analyzer.plan(for: candidate(path: "cycle.m3u8")); XCTFail("cycle must be rejected") }
        catch { XCTAssertTrue(error is MediaError) }
    }
    func testDASHChoicesRemainDistinctAndSurvivePlanScrubbing() async throws {
        let analyzer = analyzer()
        let choices = try await analyzer.candidates(for: candidate(path: "movie.mpd", transport: .dash))
        XCTAssertEqual(choices.count, 3)
        XCTAssertEqual(MediaIdentity.deduplicated(choices).count, 3)
        XCTAssertEqual(choices[0].quality, "1080p")
        XCTAssertTrue(choices[0].hasAudio)
        var scrubbed = choices[1]; scrubbed.plan = nil
        let restored = try await analyzer.plan(for: scrubbed)
        XCTAssertEqual(restored, choices[1].plan)
        XCTAssertEqual(restored.audioSegments.count, 4)
    }
    func testManifestHTTPErrorIsActionable() async throws {
        do { _ = try await analyzer().candidates(for: candidate(path: "missing.m3u8")); XCTFail("HTTP 404 must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("失效")) }
    }
}

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures: [String: String] = [
        "/master.m3u8": """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Stereo",DEFAULT=YES,URI="audio.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,CODECS="avc1.640028",AUDIO="audio"
        high.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.640028",AUDIO="audio"
        low.m3u8
        """,
        "/high.m3u8": "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2,\nvideo1.m4s\n#EXTINF:2,\nvideo2.m4s\n#EXT-X-ENDLIST",
        "/low.m3u8": "#EXTM3U\n#EXTINF:2,\nlow1.ts\n#EXT-X-ENDLIST",
        "/audio.m3u8": "#EXTM3U\n#EXTINF:2,\naudio1.aac\n#EXTINF:2,\naudio2.aac\n#EXT-X-ENDLIST",
        "/protected-master.m3u8": "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080\ndrm.m3u8",
        "/drm.m3u8": "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT=\"com.apple.streamingkeydelivery\",URI=\"skd://fairplay\"\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST",
        "/encrypted.m3u8": "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST",
        "/encrypted-master.m3u8": "#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key\"\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Stereo\",DEFAULT=YES,URI=\"encrypted.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,AUDIO=\"audio\"\nencrypted.m3u8",
        "/live.m3u8": "#EXTM3U\n#EXTINF:2,\nlive.ts",
        "/cycle.m3u8": "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080\ncycle.m3u8\n#EXT-X-ENDLIST",
        "/movie.mpd": CoreTests.templateMPD
    ]
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let fixture = Self.fixtures[url.path]
        let data = Data((fixture ?? "Not found").utf8)
        let response = HTTPURLResponse(url: url, statusCode: fixture == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
