import XCTest
import SiftXCore

final class BilibiliTests: XCTestCase {
    private let video = URL(string: "https://www.bilibili.com/video/BV1QuYX6XEZ4/")!
    private var base: MediaCandidate { MediaCandidate(sessionID: "test", pageURL: video, sourceURL: video, transport: .bilibili) }

    private func data(_ changes: [String: Any] = [:]) throws -> Data {
        var info: [String: Any] = ["id": "BV1QuYX6XEZ4", "extractor_key": "BiliBili", "webpage_url": video.absoluteString,
            "title": "B站回归视频", "duration": 664.555,
            "formats": [
                ["format_id": "100026", "ext": "mp4", "protocol": "https", "vcodec": "avc1.640028", "acodec": "none", "width": 1920, "height": 1080, "filesize": 1000],
                ["format_id": "100046", "ext": "mp4", "protocol": "https", "vcodec": "hev1.1.6.L120", "acodec": "none", "width": 1920, "height": 1080],
                ["format_id": "100023", "ext": "mp4", "protocol": "https", "vcodec": "avc1.64001F", "acodec": "none", "width": 1280, "height": 720, "filesize": 500],
                ["format_id": "30216", "ext": "m4a", "protocol": "https", "vcodec": "none", "acodec": "mp4a.40.2", "abr": 64, "filesize": 100],
                ["format_id": "30280", "ext": "m4a", "protocol": "https", "vcodec": "none", "acodec": "mp4a.40.2", "abr": 192, "filesize": 200]
            ]]
        info.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: info)
    }

    func testCanonicalLinksRemoveTrackingAndKeepSelectedPart() {
        XCTAssertEqual(BilibiliURL.canonical(URL(string: "https://bilibili.com/video/BV1QuYX6XEZ4?spm_id_from=333.1007&vd_source=tracking#reply")!), video)
        XCTAssertEqual(BilibiliURL.canonical(URL(string: "https://m.bilibili.com/video/BV1QuYX6XEZ4/?p=002&trackid=tracking")!)?.absoluteString,
                       video.absoluteString + "?p=2")
        XCTAssertEqual(BilibiliURL.canonical(URL(string: video.absoluteString + "?p=1")!), video)
        XCTAssertEqual(BilibiliURL.canonical(URL(string: "https://www.bilibili.com/video/av170001/?p=3")!)?.absoluteString,
                       "https://www.bilibili.com/video/av170001/?p=3")
        for value in ["https://bilibili.com.evil.test/video/BV1QuYX6XEZ4/", "https://evil.test/video/BV1QuYX6XEZ4/",
                      "https://user:pass@www.bilibili.com/video/BV1QuYX6XEZ4/", "https://www.bilibili.com:9999/video/BV1QuYX6XEZ4/",
                      "https://www.bilibili.com/video/BVwrong/", "https://www.bilibili.com/video/av0/", "https://www.bilibili.com/bangumi/play/ep1/",
                      video.absoluteString + "?p=0", video.absoluteString + "?p=-2", video.absoluteString + "?p=2&p=3",
                      video.absoluteString + "?p", video.absoluteString + "?p=2%3Btouch"] {
            XCTAssertNil(BilibiliURL.canonical(URL(string: value)!), value)
        }
    }

    func testSafariChoicesRecognizeVideoBeforePlaybackAndKeepPartIdentity() {
        let choices = BilibiliURL.pageCandidates(url: video, title: "网页视频", sessionID: "page")
        XCTAssertEqual(choices.map(\.kind), [.video, .audio])
        XCTAssertTrue(choices.allSatisfy { $0.transport == .bilibili && $0.sourceURL == video && $0.bilibiliFormat == nil && $0.protection == nil })
        let second = BilibiliURL.pageCandidates(url: URL(string: video.absoluteString + "?p=2")!, title: "网页视频", sessionID: "page")
        XCTAssertNotEqual(choices[0].id, second[0].id)
        XCTAssertNotEqual(choices[0].id, BilibiliURL.pageCandidates(url: video, title: "网页视频", sessionID: "other-tab")[0].id)
        XCTAssertTrue(BilibiliURL.pageCandidates(url: video, title: "", sessionID: "page", protected: true).allSatisfy { $0.protection != nil })
        XCTAssertTrue(BilibiliURL.pageCandidates(url: URL(string: "https://www.bilibili.com/")!, title: "", sessionID: "page").isEmpty)
        XCTAssertTrue(BilibiliURL.previewURL(second[0].sourceURL)?.absoluteString.contains("page=2") == true)
    }

    func testExtractedChoicesPairAACAndPersistFormatIdentityInsteadOfCDNURLs() throws {
        let choices = try BilibiliMedia.choices(data: data(), base: base)
        XCTAssertEqual(choices.map(\.height), [1080, 720, nil])
        XCTAssertEqual(choices.first?.bilibiliFormat, SiteFormatSelection(mediaFormatID: "100026", audioFormatID: "30280"))
        XCTAssertEqual(choices.first?.estimatedBytes, 1200)
        XCTAssertEqual(choices.first?.duration, 664.555)
        XCTAssertEqual(choices.last?.kind, .audio)
        XCTAssertTrue(choices.allSatisfy { $0.youtubeFormat == nil && $0.sourceURL == video && $0.audioURL == nil && $0.plan == nil && $0.hasAudio })
        XCTAssertEqual(try JSONDecoder().decode([MediaCandidate].self, from: JSONEncoder().encode(choices)), choices)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        legacy.removeValue(forKey: "bilibiliFormat")
        XCTAssertNil(try JSONDecoder().decode(MediaCandidate.self, from: JSONSerialization.data(withJSONObject: legacy)).bilibiliFormat)
    }

    func testPartMismatchOtherSitesPlaylistLiveAndDRMCannotBecomeDownloads() throws {
        for changes: [String: Any] in [["webpage_url": video.absoluteString + "?p=2"], ["webpage_url": "https://www.bilibili.com/video/BV1xx411c7mD/"],
                                      ["extractor_key": "Generic"], ["_type": "playlist"], ["is_live": true], ["live_status": "is_upcoming"]] {
            XCTAssertThrowsError(try BilibiliMedia.choices(data: data(changes), base: base))
        }
        let protected: [[String: Any]] = [["format_id": "100026", "ext": "mp4", "protocol": "https", "has_drm": true]]
        XCTAssertThrowsError(try BilibiliMedia.choices(data: data(["formats": protected]), base: base)) {
            XCTAssertTrue($0.localizedDescription.contains("DRM"))
        }
    }

    func testUnpairedVideoAndUnsupportedCodecAreNotAdvertisedAsPlayableFiles() throws {
        for format: [String: Any] in [
            ["format_id": "100026", "ext": "mp4", "protocol": "https", "vcodec": "avc1.640028", "acodec": "none", "width": 1920, "height": 1080],
            ["format_id": "100026;touch", "ext": "mp4", "protocol": "https", "vcodec": "avc1.640028", "acodec": "mp4a.40.2", "width": 1920, "height": 1080],
            ["format_id": "100046", "ext": "mp4", "protocol": "https", "vcodec": "hev1.1.6.L120", "acodec": "mp4a.40.2", "width": 1920, "height": 1080]
        ] {
            XCTAssertThrowsError(try BilibiliMedia.choices(data: data(["formats": [format]]), base: base))
        }
    }
}
