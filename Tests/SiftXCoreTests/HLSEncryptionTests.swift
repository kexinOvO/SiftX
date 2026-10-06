import Foundation
import XCTest
import CommonCrypto
@testable import SiftXCore

final class HLSEncryptionTests: XCTestCase {
    private let base = URL(string: "https://media.example.test/folder/index.m3u8")!
    private func manifest(_ body: String) throws -> HLSManifest {
        try HLSParser.parse("#EXTM3U\n" + body + "\n#EXT-X-ENDLIST", baseURL: base)
    }

    func testSequenceIVKeyRotationExplicitIVAndClearSegments() throws {
        let body = """
        #EXT-X-MEDIA-SEQUENCE:42
        #EXT-X-KEY:METHOD=AES-128,URI="first.key"
        #EXTINF:2,
        first.ts
        #EXTINF:2,
        second.ts
        #EXT-X-KEY:METHOD=AES-128,URI="second.key",IV=0xF
        #EXTINF:2,
        third.ts
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:2,
        clear.ts
        """
        let parsed = try manifest(body)
        XCTAssertFalse(parsed.isProtected)
        XCTAssertTrue(parsed.hasAES128Encryption)
        XCTAssertEqual(parsed.segments[0].encryption?.iv, Data(repeating: 0, count: 15) + Data([42]))
        XCTAssertEqual(parsed.segments[1].encryption?.iv.last, 43)
        XCTAssertEqual(parsed.segments[2].encryption?.iv, Data(repeating: 0, count: 15) + Data([15]))
        XCTAssertEqual(parsed.segments[0].encryption?.keyURL.absoluteString, "https://media.example.test/folder/first.key")
        XCTAssertEqual(parsed.segments[0].encryption?.keyID, parsed.segments[1].encryption?.keyID)
        XCTAssertNotEqual(parsed.segments[0].encryption?.keyID, parsed.segments[2].encryption?.keyID)
        XCTAssertNil(parsed.segments[3].encryption)
        XCTAssertEqual(parsed.segments, try manifest(body).segments)
    }

    func testRotationAtSameURLUsesDistinctCacheIdentity() throws {
        let parsed = try manifest("#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:2,\na.ts\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:2,\nb.ts")
        XCTAssertEqual(parsed.segments[0].encryption?.keyURL, parsed.segments[1].encryption?.keyURL)
        XCTAssertNotEqual(parsed.segments[0].encryption?.keyID, parsed.segments[1].encryption?.keyID)
    }

    func testInitializationRequiresExplicitIVAndDoesNotAdvanceSequence() throws {
        XCTAssertThrowsError(try manifest("#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2,\na.m4s"))
        let parsed = try manifest("#EXT-X-MEDIA-SEQUENCE:9\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\",IV=0x1\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:2,\na.m4s")
        XCTAssertEqual(parsed.segments.count, 2)
        XCTAssertEqual(parsed.segments[0].encryption?.iv.last, 1)
        XCTAssertEqual(parsed.segments[1].encryption?.iv.last, 9)
    }

    func testSessionKeyDoesNotEncryptUnmarkedSegments() throws {
        let parsed = try manifest("#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:2,\na.ts")
        XCTAssertFalse(parsed.isProtected)
        XCTAssertNil(parsed.segments[0].encryption)
    }

    func testMalformedKeysIVsAndSequenceAreRejected() throws {
        for tag in ["METHOD=AES-128", "METHOD=AES-128,URI=\"\"", "METHOD=AES-128,URI=\"file:///tmp/key\"", "METHOD=AES-128,URI=\"key\",IV=12", "METHOD=AES-128,URI=\"key\",IV=0xZZ", "METHOD=AES-128,URI=\"key\",IV=0x" + String(repeating: "F", count: 33)] {
            XCTAssertThrowsError(try manifest("#EXT-X-KEY:\(tag)\n#EXTINF:2,\na.ts"), tag)
        }
        for sequence in ["-1", "18446744073709551616", "garbage"] {
            XCTAssertThrowsError(try manifest("#EXT-X-MEDIA-SEQUENCE:\(sequence)\n#EXTINF:2,\na.ts"))
        }
        let maximum = "#EXT-X-MEDIA-SEQUENCE:18446744073709551615\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:2,\na.ts"
        XCTAssertEqual(try manifest(maximum).segments[0].encryption?.iv.suffix(8), Data(repeating: 255, count: 8))
        XCTAssertThrowsError(try manifest(maximum + "\n#EXTINF:2,\nb.ts"))
    }

    func testDRMAndSampleEncryptionRemainProtected() throws {
        for tag in ["METHOD=SAMPLE-AES,URI=\"skd://fairplay\"", "METHOD=AES-128,KEYFORMAT=\"com.apple.streamingkeydelivery\",URI=\"skd://fairplay\"", "METHOD=SAMPLE-AES-CTR,URI=\"key\""] {
            XCTAssertTrue(try manifest("#EXT-X-KEY:\(tag)\n#EXTINF:2,\na.ts").isProtected)
        }
    }

    func testEncryptedIFramePlaylistIsExplicitlyUnsupported() throws {
        XCTAssertThrowsError(try manifest("#EXT-X-I-FRAMES-ONLY\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:2,\na.ts"))
    }

    func testOldModelsDecodeAndNewMetadataRoundTrips() throws {
        let segment = try JSONDecoder().decode(MediaSegment.self, from: Data("{\"url\":\"https://media.example.test/a.ts\"}".utf8))
        XCTAssertNil(segment.encryption)
        var candidate = MediaCandidate(pageURL: base, sourceURL: base, transport: .hls)
        let old = try JSONEncoder().encode(candidate)
        let decoded = try JSONDecoder().decode(MediaCandidate.self, from: old)
        XCTAssertNil(decoded.duration); XCTAssertNil(decoded.encryption)
        candidate.duration = 2463; candidate.encryption = .aes128
        XCTAssertEqual(candidate.durationLabel, "41:03")
        XCTAssertEqual(try JSONDecoder().decode(MediaCandidate.self, from: JSONEncoder().encode(candidate)), candidate)
        candidate.duration = 3661
        XCTAssertEqual(candidate.durationLabel, "1:01:01")
    }

    func testStreamingDecryptionMatchesWholeBufferEncryptionAndRejectsCorruption() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SiftXAESTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = Data(0..<16), iv = Data(16..<32)
        let plaintext = Data(repeating: 0x47, count: 2_097_163)
        var ciphertext = Data(count: plaintext.count + 16)
        let capacity = ciphertext.count
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                plaintext.withUnsafeBytes { plainBytes in
                    ciphertext.withUnsafeMutableBytes { cipherBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, 16, ivBytes.baseAddress, plainBytes.baseAddress, plaintext.count, cipherBytes.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        ciphertext = ciphertext.prefix(moved)
        let source = folder.appendingPathComponent("ciphertext"), output = folder.appendingPathComponent("plaintext")
        try ciphertext.write(to: source)
        XCTAssertEqual(try HLSAES128.decrypt(source: source, destination: output, key: key, iv: iv), Int64(plaintext.count))
        XCTAssertEqual(try Data(contentsOf: output), plaintext)
        try FileManager.default.removeItem(at: output)
        try ciphertext.dropLast().write(to: source, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: source).count, ciphertext.count - 1)
        XCTAssertThrowsError(try HLSAES128.decrypt(source: source, destination: output, key: key, iv: iv))
        // CBC is not authenticated; corrupt known padding rather than assuming every wrong key fails padding.
        ciphertext[ciphertext.count - 17] ^= 0xff
        try ciphertext.write(to: source, options: .atomic)
        XCTAssertThrowsError(try HLSAES128.decrypt(source: source, destination: output, key: key, iv: iv))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertThrowsError(try HLSAES128.decrypt(source: source, destination: output, key: Data(), iv: iv))
    }
}
