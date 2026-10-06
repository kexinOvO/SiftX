import Foundation
import AppKit
import XCTest
@testable import SiftXCore

final class CoreTests: XCTestCase, @unchecked Sendable {
    private let base = URL(string: "https://example.test/media/master.m3u8?token=abc")!
    private func candidate(_ suffix: String = "video.mp4") -> MediaCandidate {
        MediaCandidate(sessionID: "page-A", title: "示例视频", pageTitle: "网页", pageURL: URL(string: "https://example.test/watch")!, sourceURL: URL(string: "https://example.test/\(suffix)")!)
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("siftx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testMediaClassification() throws {
        let cases: [(String, MediaKind, MediaTransport)] = [
            ("MOVIE.MP4?token=x", .video, .direct), ("file.mov", .video, .direct), ("file.webm", .video, .direct),
            ("song.mp3", .audio, .direct), ("song.m4a", .audio, .direct), ("song.aac", .audio, .direct), ("song.wav", .audio, .direct),
            ("master.m3u8", .video, .hls), ("video.mpd", .video, .dash)
        ]
        for (path, kind, transport) in cases {
            let result = URLSafety.classify(URL(string: "https://example.test/\(path)")!)
            XCTAssertEqual(result?.0, kind); XCTAssertEqual(result?.1, transport)
        }
        XCTAssertEqual(URLSafety.classify(URL(string: "https://example.test/opaque")!, mimeType: "application/dash+xml; charset=utf-8")?.1, .dash)
        XCTAssertNil(URLSafety.classify(URL(string: "https://example.test/chunk.ts")!, mimeType: "video/mp2t"))
        XCTAssertNil(URLSafety.classify(URL(string: "https://example.test/chunk.m4s")!, mimeType: "video/mp4"))
    }
    func testUntrustedURLsAndHeaders() throws {
        for text in ["file:///etc/passwd", "javascript:alert(1)", "blob:https://example.test/123", "https://user:password@example.test/a", "https://example.test/" + String(repeating: "a", count: 20_000)] {
            XCTAssertThrowsError(try URLSafety.validate(URL(string: text)!))
        }
        XCTAssertEqual(try URLSafety.resolve("../audio/a.m3u8", against: base).absoluteString, "https://example.test/audio/a.m3u8")
        XCTAssertThrowsError(try URLSafety.resolve("file:///secret", against: base))
        XCTAssertEqual(URLSafety.requestHeaders(["Referer": "https://example.test", "Host": "evil", "Cookie": "a=1\r\nHost: evil"]), ["Referer": "https://example.test"])
    }
    func testSafeFilenameAndCollisions() throws {
        XCTAssertEqual(SafeFilename.sanitize(" ../你好/视频:\n test?* "), "你好 视频 test")
        XCTAssertEqual(SafeFilename.sanitize("..."), "Media")
        let name = SafeFilename.sanitize(String(repeating: "猫🐈", count: 500), maxBytes: 80)
        XCTAssertLessThanOrEqual(name.utf8.count, 80)
        let directory = try temporaryDirectory()
        let first = SafeFilename.availableURL(directory: directory, baseName: "A/B", extension: "mp4")
        try Data([0]).write(to: first)
        let second = SafeFilename.availableURL(directory: directory, baseName: "A/B", extension: "mp4")
        XCTAssertEqual(first.lastPathComponent, "A B.mp4")
        XCTAssertEqual(second.lastPathComponent, "A B 2.mp4")
    }
    func testStableIdentityAndDeduplication() {
        let original = candidate()
        var duplicate = original; duplicate.id = "different"
        XCTAssertEqual(MediaIdentity.deduplicated([original, duplicate]).count, 1)
        XCTAssertNotEqual(MediaIdentity.stableID(sessionID: "A", url: base), MediaIdentity.stableID(sessionID: "B", url: base))
        XCTAssertEqual(MediaIdentity.stableID(sessionID: "A", url: base), MediaIdentity.stableID(sessionID: "A", url: base))
        var quality = original; quality.quality = "720p"
        XCTAssertEqual(MediaIdentity.deduplicated([original, quality]).count, 2)
    }
    func testHLSMasterAttributesAndRelativeAudio() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="English, stereo",DEFAULT=YES,URI="audio/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,AVERAGE-BANDWIDTH=3500000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",AUDIO="main"
        high/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,AUDIO="main"
        low.m3u8
        """
        let result = try HLSParser.parse(text, baseURL: base)
        XCTAssertEqual(result.variants.count, 2); XCTAssertEqual(result.audio.count, 1)
        XCTAssertEqual(result.audio.first?.name, "English, stereo")
        XCTAssertEqual(result.audio.first?.url.absoluteString, "https://example.test/media/audio/en.m3u8")
        XCTAssertEqual(result.variants.first?.height, 1080); XCTAssertEqual(result.variants.first?.bitrate, 3_500_000)
        XCTAssertFalse(result.variants.first!.isAudioOnly)
    }
    func testHLSSinglePlaylistByteRangesAndInitialization() throws {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="movie.mp4",BYTERANGE="100@0"
        #EXTINF:2.5,
        #EXT-X-BYTERANGE:200@100
        movie.mp4
        #EXTINF:2.5,
        #EXT-X-BYTERANGE:300
        movie.mp4
        #EXT-X-ENDLIST
        """
        let result = try HLSParser.parse(text, baseURL: base)
        XCTAssertFalse(result.isLive); XCTAssertEqual(result.duration, 5)
        XCTAssertEqual(result.segments.map(\.byteRange), ["bytes=0-99", "bytes=100-299", "bytes=300-599"])
    }
    func testHLSDRMAndUnboundedInputRejection() throws {
        for method in ["SAMPLE-AES", "SAMPLE-AES-CTR"] {
            let result = try HLSParser.parse("#EXTM3U\n#EXT-X-KEY:METHOD=\(method),URI=\"key\"\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST", baseURL: base)
            XCTAssertTrue(result.isProtected)
        }
        XCTAssertTrue(try HLSParser.parse("#EXTM3U\n#EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI=\"skd://fairplay\"", baseURL: base).isProtected)
        XCTAssertFalse(try HLSParser.parse("#EXTM3U\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST", baseURL: base).isProtected)
        XCTAssertThrowsError(try HLSParser.parse("not a playlist", baseURL: base))
        XCTAssertThrowsError(try HLSParser.parse("#EXTM3U\n#EXT-X-BYTERANGE:20\na.mp4", baseURL: base))
        XCTAssertThrowsError(try HLSParser.parse("#EXTM3U\n#EXTINF:2,\nfile:///private", baseURL: base))
        XCTAssertThrowsError(try HLSParser.parse("#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-ENDLIST", baseURL: base))
        XCTAssertThrowsError(try HLSParser.parse("#EXTM3U\n#EXTINF:2,\n#EXT-X-ENDLIST", baseURL: base))
        XCTAssertThrowsError(try HLSParser.parse("#EXTM3U\n#EXT-X-MAP:URI=\"all.mp4\",BYTERANGE=\"100\"\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST", baseURL: base))
        XCTAssertThrowsError(try HLSParser.parse("#EXTM3U\n" + String(repeating: "x", count: 4_200_000), baseURL: base))
    }
    func testDASHTemplateInheritanceAndSeparateTracks() throws {
        let result = try DASHParser.parse(Self.templateMPD, baseURL: URL(string: "https://example.test/root/movie.mpd")!)
        XCTAssertEqual(result.representations.count, 3); XCTAssertEqual(result.duration, 6)
        let video = result.representations.first!
        XCTAssertEqual(video.kind, .video); XCTAssertEqual(video.height, 1080)
        XCTAssertEqual(video.segments.count, 4)
        XCTAssertEqual(video.initializationSegment, video.segments.first)
        XCTAssertEqual(video.segmentDurations, [2, 2, 2])
        XCTAssertEqual(video.segments[0].url.absoluteString, "https://example.test/root/media/v1080/init.mp4")
        XCTAssertEqual(video.segments[1].url.absoluteString, "https://example.test/root/media/v1080/00005.m4s")
        XCTAssertEqual(result.representations.last?.kind, .audio)
    }
    func testDASHTimelineAndNegativeRepeats() throws {
        let text = """
        <MPD mediaPresentationDuration="PT8S"><Period><AdaptationSet mimeType="video/mp4"><Representation id="1" bandwidth="1000">
        <SegmentTemplate timescale="10" media="$Time$.m4s" initialization="init.mp4"><SegmentTimeline><S t="20" d="20" r="1"/><S t="60" d="20" r="-1"/></SegmentTimeline></SegmentTemplate>
        </Representation></AdaptationSet></Period></MPD>
        """
        let result = try DASHParser.parse(text, baseURL: base)
        XCTAssertEqual(result.representations[0].segments.map { $0.url.lastPathComponent }, ["init.mp4", "20.m4s", "40.m4s", "60.m4s"])
        XCTAssertEqual(result.representations[0].segmentDurations, [2, 2, 2])
    }
    func testDASHSegmentListRanges() throws {
        let text = """
        <MPD><Period><AdaptationSet mimeType="audio/mp4"><Representation id="audio"><BaseURL>all.mp4</BaseURL><SegmentList><Initialization range="0-99"/><SegmentURL media="all.mp4" mediaRange="100-999"/></SegmentList></Representation></AdaptationSet></Period></MPD>
        """
        let result = try DASHParser.parse(text, baseURL: base)
        XCTAssertEqual(result.representations[0].segments.map(\.byteRange), ["bytes=0-99", "bytes=100-999"])
        XCTAssertEqual(result.representations[0].segments[0].url.lastPathComponent, "all.mp4")
    }
    func testDASHDirectoryOnlyBaseURLIsRejectedBeforeDownload() throws {
        let directory = "<MPD><BaseURL>media/</BaseURL><Period><AdaptationSet mimeType=\"video/mp4\"><Representation id=\"video\"/></AdaptationSet></Period></MPD>"
        XCTAssertThrowsError(try DASHParser.parse(directory, baseURL: base)) { error in
            guard case MediaError.unsupported = error else { return XCTFail("must explain unsupported addressing") }
            XCTAssertTrue(error.localizedDescription.contains("目录地址"))
        }
        let file = "<MPD><Period><AdaptationSet mimeType=\"video/mp4\"><Representation id=\"video\"><BaseURL>movie.mp4</BaseURL><SegmentBase indexRange=\"100-200\"/></Representation></AdaptationSet></Period></MPD>"
        let result = try DASHParser.parse(file, baseURL: base)
        XCTAssertEqual(result.representations[0].segments, [MediaSegment(url: URL(string: "https://example.test/media/movie.mp4")!)])
    }
    func testDASHProtectedLiveAndEntityLimits() throws {
        let drm = "<MPD><Period><AdaptationSet><ContentProtection schemeIdUri=\"urn:mpeg:dash:mp4protection:2011\"/></AdaptationSet></Period></MPD>"
        XCTAssertTrue(try DASHParser.parse(drm, baseURL: base).isProtected)
        XCTAssertTrue(try DASHParser.parse("<MPD type=\"dynamic\"/>", baseURL: base).isLive)
        XCTAssertThrowsError(try DASHParser.parse("<!DOCTYPE MPD [<!ENTITY x SYSTEM 'file:///private'>]><MPD>&x;</MPD>", baseURL: base))
        XCTAssertThrowsError(try DASHParser.parse("<MPD><Period/><Period/></MPD>", baseURL: base))
        let explosive = "<MPD mediaPresentationDuration=\"PT20S\"><Period><AdaptationSet mimeType=\"video/mp4\"><Representation><SegmentTemplate media=\"$Time$.m4s\"><SegmentTimeline><S d=\"1\" r=\"999999999\"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>"
        XCTAssertThrowsError(try DASHParser.parse(explosive, baseURL: base))
        XCTAssertThrowsError(try DASHParser.parse("<MPD><Period><AdaptationSet mimeType=\"audio/mp4\"><Representation><SegmentList><Initialization sourceURL=\"init.mp4\"/></SegmentList></Representation></AdaptationSet></Period></MPD>", baseURL: base))
        let overflow = "<MPD mediaPresentationDuration=\"PT9223372036854775808S\"><Period><AdaptationSet mimeType=\"video/mp4\"><Representation><SegmentTemplate media=\"$Time$.m4s\"><SegmentTimeline><S d=\"1\" r=\"-1\"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>"
        XCTAssertThrowsError(try DASHParser.parse(overflow, baseURL: base))
    }
    func testDownloadStatusRecovery() {
        XCTAssertEqual(DownloadStatus.downloading.recoveredAfterInterruption, .paused)
        XCTAssertEqual(DownloadStatus.processing.recoveredAfterInterruption, .paused)
        for status in [DownloadStatus.completed, .failed, .cancelled, .queued, .paused] { XCTAssertEqual(status.recoveredAfterInterruption, status) }
    }
    func testStoreSharedConnectionsRequestsHistoryAndSettings() throws {
        let directory = try temporaryDirectory()
        let a = try SharedStore(directory: directory), b = try SharedStore(directory: directory)
        let original = candidate()
        let request = try a.enqueue(candidate: original)
        XCTAssertEqual(try b.pendingRequests().first?.id, request)
        let record = DownloadRecord(id: request, candidate: original, status: .downloading, bytesReceived: 1024, fileBookmark: Data([1, 2, 3]))
        try b.saveDownload(record)
        try b.ackRequest(id: request)
        XCTAssertTrue(try a.pendingRequests().isEmpty)
        XCTAssertEqual(try a.loadDownloads().first?.bytesReceived, 1024)
        XCTAssertEqual(try a.loadDownloads().first?.fileBookmark, Data([1, 2, 3]))
        try a.saveSettings(AppSettings(maxConcurrent: 100, onboardingComplete: true))
        XCTAssertEqual(try b.loadSettings().maxConcurrent, 8)
        XCTAssertTrue(try b.loadSettings().onboardingComplete)
        try b.deleteDownload(id: request)
        XCTAssertTrue(try a.loadDownloads().isEmpty)
    }

    func testPluginIconReadsExistingSettingsAndFallsBackForUnknownChoice() throws {
        var original = AppSettings(maxConcurrent: 4, downloadDirectory: "/saved/downloads", notifyCompletion: false, appearance: "dark")
        original.downloadBookmark = Data([1, 2, 3])
        // A settings payload written before the icon option existed has no pluginIcon key.
        let legacyData = try JSONEncoder().encode(original)
        let legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        XCTAssertNil(legacyObject["pluginIcon"])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.selectedPluginIcon, .currentPNG)

        original.pluginIcon = "future.icon"
        let unknown = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(unknown.selectedPluginIcon, .currentPNG)
        XCTAssertEqual(unknown.downloadBookmark, original.downloadBookmark)
        XCTAssertEqual(unknown.appearance, "dark")
    }

    func testToolbarBadgeDefaultsToVisibleForLegacySettings() throws {
        let original = AppSettings(maxConcurrent: 4, notifyCompletion: false, appearance: "dark")
        let data = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["toolbarBadgeVisibleFlag"])
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.showsToolbarBadge)
        XCTAssertEqual(decoded, original)
    }

    func testToolbarBadgeChoicePersistsAcrossStoreConnections() throws {
        let directory = try temporaryDirectory()
        let app = try SharedStore(directory: directory)
        for enabled in [false, true, false] {
            var settings = AppSettings(maxConcurrent: 4, notifyCompletion: false, appearance: "dark")
            settings.selectedPluginIcon = .currentPNG
            settings.showsToolbarBadge = enabled
            try app.saveSettings(settings)
            let restored = try SharedStore(directory: directory).loadSettings()
            XCTAssertEqual(restored.showsToolbarBadge, enabled)
            XCTAssertEqual(restored, settings)
        }
    }

    func testPluginIconPersistsAcrossStoreConnectionsAndSymbolsExist() throws {
        let directory = try temporaryDirectory()
        let app = try SharedStore(directory: directory), extensionStore = try SharedStore(directory: directory)
        for icon in PluginIcon.allCases {
            var settings = AppSettings(maxConcurrent: 3)
            settings.selectedPluginIcon = icon
            try app.saveSettings(settings)
            XCTAssertEqual(try extensionStore.loadSettings().selectedPluginIcon, icon)
            XCTAssertEqual(try extensionStore.loadSettings().maxConcurrent, 3)
            if let symbol = icon.systemImageName {
                XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
            }
        }
    }
    func testPageIdentityPruningAndNoDurableSegments() throws {
        let store = try SharedStore(directory: temporaryDirectory())
        var original = candidate()
        original.plan = MediaPlan(segments: [MediaSegment(url: base)])
        try store.savePage(PageSession(id: "A", pageURL: original.pageURL, title: "First tab", candidates: [original]))
        try store.savePage(PageSession(id: "B", pageURL: original.pageURL, title: "Second tab", candidates: [original]))
        XCTAssertEqual(try store.pages().count, 2)
        XCTAssertNil(try store.page(id: "A")?.candidates[0].plan)
        try store.savePage(PageSession(id: "old", pageURL: original.pageURL, title: "Old", updatedAt: Date().addingTimeInterval(-8_000), candidates: []))
        XCTAssertNil(try store.page(id: "old"))
        try store.removePage(id: "A")
        XCTAssertNil(try store.page(id: "A")); XCTAssertNotNil(try store.page(id: "B"))
        let record = DownloadRecord(candidate: original)
        try store.saveDownload(record)
        XCTAssertNil(try store.loadDownloads().first?.candidate.plan)
    }
    func testStoreConcurrentAtomicPageMerge() throws {
        let directory = try temporaryDirectory()
        let stores = [try SharedStore(directory: directory), try SharedStore(directory: directory)]
        let errors = LockedErrors()
        DispatchQueue.concurrentPerform(iterations: 30) { index in
            let media = self.candidate("\(index).mp4")
            do { try stores[index % 2].mergePage(PageSession(id: "A", pageURL: media.pageURL, title: "Same tab", candidates: [media])) }
            catch { errors.append(error) }
        }
        XCTAssertEqual(errors.count, 0)
        XCTAssertEqual(try stores[0].page(id: "A")?.candidates.count, 30)
    }
    func testAnalyzerDirectAndProtectedPlans() async throws {
        let analyzer = MediaAnalyzer()
        let original = candidate()
        let plan = try await analyzer.plan(for: original)
        XCTAssertEqual(plan.outputExtension, "mp4"); XCTAssertEqual(plan.segments.count, 1)
        var protected = original; protected.protection = "DRM"
        do { _ = try await analyzer.plan(for: protected); XCTFail("must reject protected media") }
        catch { XCTAssertTrue(error is MediaError) }
    }

    static let templateMPD = """
    <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT6S">
      <BaseURL>media/</BaseURL><Period>
        <AdaptationSet mimeType="video/mp4"><SegmentTemplate timescale="1" duration="2" startNumber="5" initialization="$RepresentationID$/init.mp4" media="$RepresentationID$/$Number%05d$.m4s"/>
          <Representation id="v1080" width="1920" height="1080" bandwidth="4000000"/>
          <Representation id="v720" width="1280" height="720" bandwidth="2000000"/>
        </AdaptationSet>
        <AdaptationSet mimeType="audio/mp4"><Representation id="audio" bandwidth="128000"><SegmentTemplate timescale="1" duration="2" initialization="audio/init.mp4" media="audio/$Number$.m4s"/></Representation></AdaptationSet>
      </Period>
    </MPD>
    """
}
private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    func append(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
}
