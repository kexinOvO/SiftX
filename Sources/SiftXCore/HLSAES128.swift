import Foundation
import CommonCrypto

/// Decrypts full HLS segments using AES-128 CBC with PKCS#7 padding.
/// The caller publishes the destination only after this function succeeds.
public enum HLSAES128 {
    @discardableResult
    public static func decrypt(source: URL, destination: URL, key: Data, iv: Data) throws -> Int64 {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { throw MediaError.invalidEncryptionKey }
        guard source.standardizedFileURL != destination.standardizedFileURL else { throw MediaError.decryptionFailed }
        // Read the current file descriptor rather than cached NSURL resource values after resume/replacement.
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: source.path))
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard size > 0, size % UInt64(kCCBlockSizeAES128) == 0 else { throw MediaError.decryptionFailed }
        try input.seek(toOffset: 0)
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreate(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress, &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { throw MediaError.decryptionFailed }
        defer { CCCryptorRelease(cryptor) }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw MediaError.storage("无法创建解密临时文件。") }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: 0)
        var written: Int64 = 0
        var lastBlock = Data()
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            var buffer = Data(count: data.count + kCCBlockSizeAES128)
            let capacity = buffer.count
            var moved = 0
            let result = data.withUnsafeBytes { inputBytes in
                buffer.withUnsafeMutableBytes { outputBytes in
                    CCCryptorUpdate(cryptor, inputBytes.baseAddress, data.count, outputBytes.baseAddress, capacity, &moved)
                }
            }
            guard result == kCCSuccess else { throw MediaError.decryptionFailed }
            let plaintext = buffer.prefix(moved)
            lastBlock = plaintext.count >= kCCBlockSizeAES128 ? Data(plaintext.suffix(kCCBlockSizeAES128)) : Data((lastBlock + plaintext).suffix(kCCBlockSizeAES128))
            try output.write(contentsOf: plaintext); written += Int64(moved)
        }
        try Task.checkCancellation()
        var tail = Data(count: kCCBlockSizeAES128)
        var moved = 0
        let result = tail.withUnsafeMutableBytes { bytes in
            CCCryptorFinal(cryptor, bytes.baseAddress, kCCBlockSizeAES128, &moved)
        }
        guard result == kCCSuccess else { throw MediaError.decryptionFailed }
        let plaintext = tail.prefix(moved)
        lastBlock = Data((lastBlock + plaintext).suffix(kCCBlockSizeAES128))
        try output.write(contentsOf: plaintext); written += Int64(moved)
        // Validate every PKCS#7 padding byte explicitly before publishing any plaintext.
        guard let padding = lastBlock.last, (1...kCCBlockSizeAES128).contains(Int(padding)),
              lastBlock.suffix(Int(padding)).allSatisfy({ $0 == padding }), written > Int64(padding) else { throw MediaError.decryptionFailed }
        written -= Int64(padding)
        try output.truncate(atOffset: UInt64(written))
        try output.synchronize()
        try output.close()
        completed = true
        return written
    }
}
