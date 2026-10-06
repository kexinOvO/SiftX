import XCTest
import SiftXCore

final class YouTubeTests: XCTestCase {
    private let watch = URL(string: "https://www.youtube.com/watch?v=BaW_jenozKc")!
    private var base: MediaCandidate { MediaCandidate(sessionID: "test", pageURL: watch, sourceURL: watch, transport: .youtube) }
    private func data(_ changes: [String: Any] = [:]) throws -> Data {
        var info: [String: Any] = ["id": "BaW_jenozKc", "title": "学习视频", "duration": 12,
            "formats": [
                ["format_id": "137", "ext": "mp4", "protocol": "https", "vcodec": "avc1.640028", "acodec": "none", "width": 1920, "height": 1080, "fps": 30, "filesize": 1000],
                ["format_id": "399", "ext": "mp4", "protocol": "https", "vcodec": "av01.0", "acodec": "none", "width": 3840, "height": 2160],
                ["format_id": "22", "ext": "mp4", "protocol": "https", "vcodec": "avc1.64001F", "acodec": "mp4a.40.2", "width": 1280, "height": 720],
                ["format_id": "140", "ext": "m4a", "protocol": "https", "vcodec": "none", "acodec": "mp4a.40.2", "abr": 128, "filesize": 200]
            ]]
        info.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: info)
    }

    func testCanonicalLinksStripPlaylistTrackingAndSupportShortsEmbeds() {
        for url in ["https://youtu.be/BaW_jenozKc?si=tracking", "https://m.youtube.com/watch?v=BaW_jenozKc&list=PLAYLIST&t=30",
                    "https://www.youtube.com/shorts/BaW_jenozKc", "https://www.youtube-nocookie.com/embed/BaW_jenozKc",
                    "https://music.youtube.com/watch?v=BaW_jenozKc", "https://www.youtube.com/live/BaW_jenozKc"] {
            XCTAssertEqual(YouTubeURL.canonical(URL(string: url)!), watch, url)
        }
        for url in ["https://youtube.com.evil.test/watch?v=BaW_jenozKc", "https://evil.test/youtube.com/watch?v=BaW_jenozKc",
                    "https://youtube.com/playlist?list=PLAYLIST", "file:///watch?v=BaW_jenozKc", "https://youtube.com/watch?v=wrong",
                    "https://user:password@youtube.com/watch?v=BaW_jenozKc", "https://youtube.com/watch?v=BaW_jenozKc&v=abcdefghijk"] {
            XCTAssertNil(YouTubeURL.canonical(URL(string: url)!), url)
        }
    }

    func testChoicesPairAudioAndPersistStableFormatIDs() throws {
        let choices = try YouTubeMedia.choices(data: data(), base: base)
        XCTAssertEqual(choices.count, 3)
        XCTAssertEqual(choices.map(\.height), [1080, 720, nil])
        XCTAssertEqual(choices.first?.title, "学习视频")
        XCTAssertEqual(choices.first?.estimatedBytes, 1200)
        XCTAssertEqual(choices.first?.youtubeFormat, YouTubeFormatSelection(mediaFormatID: "137", audioFormatID: "140"))
        XCTAssertNil(choices[1].youtubeFormat?.audioFormatID)
        XCTAssertEqual(choices.last?.kind, .audio)
        XCTAssertTrue(choices.allSatisfy { $0.sourceURL == watch && $0.audioURL == nil && $0.plan == nil && $0.hasAudio })
        let restored = try JSONDecoder().decode([MediaCandidate].self, from: JSONEncoder().encode(choices))
        XCTAssertEqual(restored, choices)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        json.removeValue(forKey: "youtubeFormat")
        XCTAssertNil(try JSONDecoder().decode(MediaCandidate.self, from: JSONSerialization.data(withJSONObject: json)).youtubeFormat)
    }

    func testLivePlaylistMismatchedIdentityAndDRMAreRejected() throws {
        for changes: [String: Any] in [["is_live": true], ["live_status": "is_upcoming"], ["live_status": "post_live"],
                                      ["_type": "playlist"], ["id": "abcdefghijk"]] {
            XCTAssertThrowsError(try YouTubeMedia.choices(data: data(changes), base: base))
        }
        let protected = [["format_id": "18", "ext": "mp4", "protocol": "https", "has_drm": true]] as [[String: Any]]
        XCTAssertThrowsError(try YouTubeMedia.choices(data: data(["formats": protected]), base: base)) {
            XCTAssertTrue($0.localizedDescription.contains("DRM"))
        }
    }

    func testUnsupportedCodecsUnpairedVideoAndUnsafeIDsCannotBecomeDownloads() throws {
        for format: [String: Any] in [
            ["format_id": "137", "ext": "mp4", "protocol": "https", "vcodec": "avc1.640028", "acodec": "none", "width": 1920, "height": 1080],
            ["format_id": "18;touch", "ext": "mp4", "protocol": "https", "vcodec": "avc1", "acodec": "mp4a", "width": 640, "height": 360],
            ["format_id": "18", "ext": "mp4", "protocol": "rtmp", "vcodec": "avc1", "acodec": "mp4a", "width": 640, "height": 360]
        ] {
            XCTAssertThrowsError(try YouTubeMedia.choices(data: data(["formats": [format]]), base: base))
        }
    }

    func testSafariChoicesWorkBeforePlaybackAndRespectProtection() {
        let choices = YouTubeURL.pageCandidates(url: watch, title: "Safari 学习视频", sessionID: "page")
        XCTAssertEqual(choices.map(\.kind), [.video, .audio])
        XCTAssertEqual(choices.map(\.transport), [.youtube, .youtube])
        XCTAssertNil(choices.first?.youtubeFormat)
        XCTAssertEqual(choices.first?.thumbnailURL?.host, "i.ytimg.com")
        XCTAssertNil(choices.last?.thumbnailURL)
        XCTAssertEqual(YouTubeURL.pageCandidates(url: watch, title: "", sessionID: "page", protected: true).filter { $0.protection == nil }.count, 0)
    }
}
