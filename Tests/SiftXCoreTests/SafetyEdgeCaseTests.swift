import Foundation
import XCTest
@testable import SiftXCore

/// Regression coverage for untrusted URLs, filenames and bounded manifest expansion.
final class SafetyEdgeCaseTests: XCTestCase {
    func testURLByteBoundary() throws {
        let prefix = "https://example.test/"
        let allowed = URL(string: prefix + String(repeating: "a", count: URLSafety.maximumURLBytes - prefix.utf8.count))!
        let rejected = URL(string: prefix + String(repeating: "a", count: URLSafety.maximumURLBytes - prefix.utf8.count + 1))!
        XCTAssertEqual(allowed.absoluteString.utf8.count, URLSafety.maximumURLBytes)
        XCTAssertNoThrow(try URLSafety.validate(allowed))
        XCTAssertThrowsError(try URLSafety.validate(rejected))
    }

    func testUnsafeURLsAndCredentialsAreRejected() {
        for value in [
            "file:///private/tmp/film.mp4",
            "data:video/mp4;base64,AA==",
            "blob:https://example.test/uuid",
            "https://user:password@example.test/film.mp4",
            "ftp://example.test/film.mp4"
        ] {
            guard let url = URL(string: value) else {
                return XCTFail("Test URL failed to parse: " + value)
            }
            XCTAssertThrowsError(try URLSafety.validate(url), value)
        }
        XCTAssertNoThrow(try URLSafety.validate(URL(string: "https://example.test/video.mp4?token=123")!))
    }

    func testRelativeManifestReferencesCannotEscapeToUnsafeSchemes() throws {
        let base = URL(string: "https://cdn.example.test/hls/master.m3u8")!
        let resolved = try URLSafety.resolve("../media/video.mp4?token=123", against: base)
        XCTAssertEqual(resolved.absoluteString, "https://cdn.example.test/media/video.mp4?token=123")
        XCTAssertThrowsError(try URLSafety.resolve("file:///etc/passwd", against: base))
        XCTAssertThrowsError(try URLSafety.resolve("https://u:p@cdn.example.test/secret", against: base))
    }

    func testTransportFragmentsNeverBecomeIndependentMedia() {
        for filename in ["seg.ts", "init.m4s", "captions.vtt", "encryption.key", "part.cmfv"] {
            let url = URL(string: "https://cdn.example.test/" + filename)!
            XCTAssertNil(URLSafety.classify(url, mimeType: "video/mp4"), filename)
        }
        let opaque = URL(string: "https://cdn.example.test/stream?id=1")!
        XCTAssertEqual(URLSafety.classify(opaque, mimeType: "audio/mpeg; charset=utf-8")?.0, .audio)
        XCTAssertEqual(URLSafety.classify(opaque, mimeType: "application/dash+xml")?.1, .dash)
    }

    func testHeaderAllowlistRejectsInjectionAndOversizedValues() {
        let limit = URLSafety.maximumURLBytes
        let accepted = String(repeating: "a", count: limit)
        let headers = URLSafety.requestHeaders([
            "Accept": "video/*",
            "AUTHORIZATION": "Bearer abc",
            "Referer": "https://example.test/watch",
            "User-Agent": accepted,
            "Origin": String(repeating: "b", count: limit + 1),
            "Cookie": "session=ok\r\nHost: evil.test",
            "Host": "evil.test",
            "X-Forwarded-For": "127.0.0.1"
        ])
        XCTAssertEqual(headers["Accept"], "video/*")
        XCTAssertEqual(headers["AUTHORIZATION"], "Bearer abc")
        XCTAssertEqual(headers["User-Agent"], accepted)
        XCTAssertNil(headers["Origin"])
        XCTAssertNil(headers["Cookie"])
        XCTAssertNil(headers["Host"])
        XCTAssertNil(headers["X-Forwarded-For"])
    }

    func testManifestBudgetRejectsExcessiveSegmentCount() throws {
        var budget = ManifestBudget()
        let segment = URL(string: "https://cdn.example.test/segment.ts")!
        for _ in 0..<50_000 { try budget.consume(segment) }
        XCTAssertThrowsError(try budget.consume(segment))
    }

    func testFilenameCollisionSequenceNeverOverwritesExistingFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = SafeFilename.availableURL(directory: folder, baseName: "clip/final", extension: "MP4")
        XCTAssertEqual(first.lastPathComponent, "clip final.mp4")
        try Data([1]).write(to: first)
        let second = SafeFilename.availableURL(directory: folder, baseName: "clip/final", extension: "mp4")
        XCTAssertEqual(second.lastPathComponent, "clip final 2.mp4")
        try Data([2]).write(to: second)
        let third = SafeFilename.availableURL(directory: folder, baseName: "clip/final", extension: "mP4")
        XCTAssertEqual(third.lastPathComponent, "clip final 3.mp4")
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertEqual(try Data(contentsOf: second), Data([2]))
    }
}
