import XCTest
import Foundation
import CryptoKit
import SiftXCore

@MainActor
final class EncryptedHLSTests: XCTestCase {
    private let base = URL(string: ProcessInfo.processInfo.environment["SIFTX_FIXTURE_BASE_URL"] ?? "http://127.0.0.1:18765")!
    private var project: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func folder() throws -> URL {
        setenv("SIFTX_FFMPEG_PATH", project.appendingPathComponent("App/Resources/ffmpeg").path, 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SiftXEncryptedTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func candidate(_ path: String) -> MediaCandidate {
        MediaCandidate(title: "AES-128 test", pageURL: base.appendingPathComponent("hls-aes.html"), sourceURL: base.appendingPathComponent(path), transport: .hls, headers: ["Referer": base.appendingPathComponent("hls-aes.html").absoluteString])
    }
    private func stats() async throws -> ([String: Int], [String: String]) {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("fixture-stats"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (object["requests"] as? [String: Int] ?? [:], object["referers"] as? [String: String] ?? [:])
    }

    func testAES128VariantsDecryptToOriginalSegmentsAndProducePlayableMedia() async throws {
        let root = try folder()
        let analyzer = MediaAnalyzer()
        let cases = ["implicit/index.m3u8", "explicit/index.m3u8", "rotation/index.m3u8", "ranges/index.m3u8", "master.m3u8", "fmp4/index.m3u8", "split.m3u8"]
        let validation = project.appendingPathComponent("Build/VerifiedAES128")
        try FileManager.default.createDirectory(at: validation, withIntermediateDirectories: true)
        for (index, path) in cases.enumerated() {
            let source = candidate("aes/" + path)
            let choices = try await analyzer.candidates(for: source)
            let choice = try XCTUnwrap(choices.first)
            XCTAssertNil(choice.protection)
            XCTAssertEqual(choice.encryption, .aes128)
            let plan = try await analyzer.plan(for: choice)
            let destination = root.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let output = try await SegmentedDownloader().download(candidate: choice, plan: plan, directory: destination, progress: { _ in }, processing: {})
            XCTAssertGreaterThan(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1000)
            let reference: MediaPlan
            if path == "split.m3u8" { reference = try await analyzer.plan(for: candidate("hls/split.m3u8")) }
            else if path == "fmp4/index.m3u8" { reference = try await analyzer.plan(for: candidate("hls/fmp4.m3u8")) }
            else { reference = try await analyzer.plan(for: candidate("hls/single.m3u8")) }
            let originals = reference.segments + reference.audioSegments
            XCTAssertEqual(originals.count, plan.segments.count + plan.audioSegments.count)
            for (segmentIndex, segment) in originals.enumerated() {
                let chunk = destination.appendingPathComponent("Segments/" + String(format: "%06d.chunk", segmentIndex))
                let expected = project.appendingPathComponent("Build/Fixtures").appendingPathComponent(segment.url.path)
                XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: chunk)), SHA256.hash(data: try Data(contentsOf: expected)), path + " segment \(segmentIndex)")
            }
            let copy = validation.appendingPathComponent(path.replacingOccurrences(of: "/", with: "-") + ".mp4")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: output, to: copy)
            let names = try FileManager.default.contentsOfDirectory(atPath: destination.path)
            XCTAssertFalse(names.contains { $0.hasSuffix(".key") || $0.hasSuffix(".bin") })
        }
    }

    func testConcurrentSegmentsShareKeyAndRotationRefetchesWithReferer() async throws {
        let before = try await stats().0["/aes/implicit/key0.bin"] ?? 0
        let referer = base.appendingPathComponent("hls-aes.html").absoluteString
        let loader = HLSKeyLoader(headers: ["Referer": referer])
        let url = base.appendingPathComponent("aes/implicit/key0.bin")
        do {
            try await withThrowingTaskGroup(of: Data.self) { group in
                for index in 0..<20 {
                    let encryption = HLSEncryption(keyURL: url, iv: Data(repeating: UInt8(index), count: 16), keyID: "first-occurrence")
                    group.addTask { try await loader.key(for: encryption) }
                }
                for try await key in group { XCTAssertEqual(key, Data(0..<16)) }
            }
            let after = try await stats()
            XCTAssertEqual(after.0["/aes/implicit/key0.bin"], before + 1)
            XCTAssertEqual(after.1["/aes/implicit/key0.bin"], referer)
            _ = try await loader.key(for: HLSEncryption(keyURL: url, iv: Data(repeating: 0, count: 16), keyID: "second-occurrence"))
            let rotated = try await stats()
            XCTAssertEqual(rotated.0["/aes/implicit/key0.bin"], before + 2)
        } catch { await loader.close(); throw error }
        await loader.close()
    }

    func testInvalidOrInaccessibleKeysAndCorruptCiphertextFailClearly() async throws {
        let root = try folder()
        let analyzer = MediaAnalyzer()
        for name in ["short", "long", "forbidden", "html", "corrupt"] {
            let source = candidate("aes/bad-\(name).m3u8")
            let plan = try await analyzer.plan(for: source)
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                _ = try await SegmentedDownloader().download(candidate: source, plan: plan, directory: directory, progress: { _ in }, processing: {})
                XCTFail("Must reject \(name)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("AES-128"), error.localizedDescription)
                if name == "forbidden" { XCTAssertTrue(error.localizedDescription.contains("403")) }
            }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Segments").path)) ?? []
            XCTAssertFalse(files.contains { $0.hasSuffix(".chunk") || $0.hasSuffix(".decrypting") })
        }
    }

    func testPauseResumeKeepsCompletedPlaintextChunksAndSkipsTheirRequests() async throws {
        let root = try folder()
        let source = candidate("aes/slow/index.m3u8")
        let plan = try await MediaAnalyzer().plan(for: source)
        let first = Task {
            try await SegmentedDownloader().download(candidate: source, plan: plan, directory: root, progress: { _ in }, processing: {})
        }
        let segmentsDirectory = root.appendingPathComponent("Segments")
        let deadline = Date().addingTimeInterval(10)
        var completed: [String] = []
        while Date() < deadline {
            completed = ((try? FileManager.default.contentsOfDirectory(atPath: segmentsDirectory.path)) ?? []).filter { $0.hasSuffix(".chunk") }
            if !completed.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError, error.localizedDescription) }
        completed = try FileManager.default.contentsOfDirectory(atPath: segmentsDirectory.path).filter { $0.hasSuffix(".chunk") }
        XCTAssertFalse(completed.isEmpty)
        XCTAssertLessThan(completed.count, plan.segments.count)
        let before = try await stats().0
        let hashes = try Dictionary(uniqueKeysWithValues: completed.map { ($0, Data(SHA256.hash(data: try Data(contentsOf: segmentsDirectory.appendingPathComponent($0))))) })
        let output = try await SegmentedDownloader().download(candidate: source, plan: plan, directory: root, progress: { _ in }, processing: {})
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let after = try await stats().0
        for file in completed {
            let index = try XCTUnwrap(Int(file.prefix(6)))
            let requestPath = plan.segments[index].url.path
            XCTAssertEqual(after[requestPath], before[requestPath], "Completed segment should not be downloaded again")
            XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: segmentsDirectory.appendingPathComponent(file)))), hashes[file])
        }
    }
}
