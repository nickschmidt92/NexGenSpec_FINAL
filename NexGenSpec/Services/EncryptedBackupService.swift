import Foundation
import CryptoKit
import CommonCrypto

enum EncryptedBackupService {

    // MARK: - Config (B-0047)

    /// Current backup format. v3 streams one encrypted file at a time (header +
    /// per-file frames) so peak memory is bounded by the largest single file,
    /// not the whole store (T-01438). v1 (un-iterated SHA-256) and v2 (one-shot
    /// JSON envelope) are no longer restorable (rejected with a clear error).
    static let currentSchemaVersion = 3
    /// Minimum passphrase length. Enforced at BOTH create and restore, and
    /// referenced by the UI gates (no literals) so they cannot drift.
    static let minPassphraseLength = 12
    /// PBKDF2-HMAC-SHA256 work factor (OWASP-2023 floor for this PRF).
    static let pbkdf2Iterations = 210_000
    static let kdfAlgorithmID = "PBKDF2-HMAC-SHA256"
    static let derivedKeyByteCount = 32
    static let minAcceptableIterations = 200_000
    static let maxAcceptableIterations = 5_000_000

    enum BackupError: LocalizedError {
        case unsupportedSchema(found: Int, supported: Int)
        case passphraseTooShort(min: Int)
        case keyDerivationFailed(status: Int32)
        case unknownKDF(String)
        case weakKDF(iterations: Int)
        case unsafePath(String)
        case corruptBackup

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let found, let supported):
                if found > supported {
                    return "This backup was made by a newer version of NexGenSpec. Update the app to restore it."
                }
                return "This backup was made by an older version of NexGenSpec (format v\(found)) and can no longer be restored. The supported format is v\(supported). Create a new encrypted backup."
            case .passphraseTooShort(let min):
                return "Passphrase must be at least \(min) characters."
            case .keyDerivationFailed(let status):
                return "Could not derive the encryption key (error \(status))."
            case .unknownKDF(let name):
                return "This backup uses an unsupported key-derivation method (\(name)) and cannot be restored."
            case .weakKDF(let iterations):
                return "This backup's key-derivation strength (\(iterations) iterations) is outside the accepted range and cannot be restored."
            case .unsafePath(let path):
                return "This backup contains an unsafe file path (\(path)) and cannot be restored."
            case .corruptBackup:
                return "This backup file is incomplete or corrupted and cannot be restored."
            }
        }
    }

    /// JSON header at the front of a v3 backup, length-prefixed by a UInt32.
    /// Carries the KDF parameters (the per-file ciphertext follows as binary
    /// frames). No file data lives here — that is the whole point (T-01438).
    struct BackupHeader: Codable {
        var schemaVersion: Int
        var createdAt: Date
        var salt: Data
        var kdfAlgorithm: String
        var kdfIterations: Int
    }

    static func createEncryptedBackup(passphrase: String, destinationURL: URL) throws {
        guard passphrase.count >= minPassphraseLength else {
            throw BackupError.passphraseTooShort(min: minPassphraseLength)
        }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: pbkdf2Iterations)

        // Write the length-prefixed header first (creating the file with file
        // protection), then append one encrypted file at a time so peak memory
        // is bounded by the largest single file, not the whole store (T-01438).
        let header = BackupHeader(schemaVersion: currentSchemaVersion, createdAt: Date(),
                                  salt: salt, kdfAlgorithm: kdfAlgorithmID, kdfIterations: pbkdf2Iterations)
        let headerData = try JSONEncoder().encode(header)
        var prefix = Data()
        prefix.appendUInt32BE(UInt32(headerData.count))
        prefix.append(headerData)
        try FileSecurity.writeProtected(prefix, to: destinationURL)

        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var fileCount = 0
        let root = FilePaths.appRoot
        if FileManager.default.fileExists(atPath: root.path) {
            for relative in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
                let absolute = root.appendingPathComponent(relative)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: absolute.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                if relative.hasSuffix(".backup.enc") { continue }
                let fileData = try Data(contentsOf: absolute)           // one file in RAM
                let sealed = try AES.GCM.seal(fileData, using: key)
                try handle.write(contentsOf: frame(relativePath: relative, sealed: sealed))
                fileCount += 1
            }
        }
        AuditLog.log(event: "Encrypted backup created (schema v\(currentSchemaVersion), PBKDF2 \(pbkdf2Iterations), \(fileCount) files, streamed)")
    }

    static func restoreEncryptedBackup(passphrase: String, sourceURL: URL) throws {
        guard passphrase.count >= minPassphraseLength else {
            throw BackupError.passphraseTooShort(min: minPassphraseLength)
        }

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        // A v3 stream begins with a 4-byte header length; a legacy v1/v2 backup
        // is a single JSON object starting with '{'. Reject the latter clearly.
        let firstByte = try readExact(1, from: handle)
        if firstByte.first == UInt8(ascii: "{") {
            throw BackupError.unsupportedSchema(found: 2, supported: currentSchemaVersion)
        }
        let headerLen = Int((firstByte + (try readExact(3, from: handle))).toUInt32BE())
        guard headerLen > 0, headerLen < 1_000_000 else { throw BackupError.corruptBackup }
        let header = try JSONDecoder().decode(BackupHeader.self, from: readExact(headerLen, from: handle))

        guard header.schemaVersion == currentSchemaVersion else {
            throw BackupError.unsupportedSchema(found: header.schemaVersion, supported: currentSchemaVersion)
        }
        guard header.kdfAlgorithm == kdfAlgorithmID else { throw BackupError.unknownKDF(header.kdfAlgorithm) }
        guard header.kdfIterations >= minAcceptableIterations,
              header.kdfIterations <= maxAcceptableIterations else {
            throw BackupError.weakKDF(iterations: header.kdfIterations)
        }
        let key = try deriveKey(passphrase: passphrase, salt: header.salt, iterations: header.kdfIterations)

        // Stream each per-file frame: only one ciphertext is in RAM at a time.
        var fileCount = 0
        while let pathLen = try readFrameLength(from: handle) {
            guard pathLen > 0, pathLen < 4096 else { throw BackupError.corruptBackup }
            let pathData = try readExact(Int(pathLen), from: handle)
            guard let relative = String(data: pathData, encoding: .utf8) else { throw BackupError.corruptBackup }
            let nonceData = try readExact(12, from: handle)
            let ctLen = (try readExact(8, from: handle)).toUInt64BE()
            guard ctLen < 2_000_000_000 else { throw BackupError.corruptBackup }
            let ciphertext = try readExact(Int(ctLen), from: handle)
            let tag = try readExact(16, from: handle)

            // Validate the path (T-01437) before opening/writing.
            guard let target = safeRestoreTarget(forRelativePath: relative) else {
                throw BackupError.unsafePath(relative)
            }
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonceData),
                                            ciphertext: ciphertext, tag: tag)
            let clear = try AES.GCM.open(box, using: key)
            try FileSecurity.writeProtected(clear, to: target)
            fileCount += 1
        }
        AuditLog.log(event: "Encrypted backup restored (schema v\(currentSchemaVersion), PBKDF2 \(header.kdfIterations), \(fileCount) files, streamed)")
    }

    /// Validates a backup's stored relative path before restore (T-01437):
    /// rejects empty, absolute, NUL-bearing, or `..`-traversing paths, and
    /// requires the resolved target to stay inside `appRoot`. Returns the safe
    /// destination URL, or nil if the path is unsafe.
    static func safeRestoreTarget(forRelativePath relative: String) -> URL? {
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              !relative.contains("\0"),
              !relative.split(separator: "/").contains("..") else { return nil }
        let appRoot = FilePaths.appRoot
        let target = appRoot.appendingPathComponent(relative).standardizedFileURL
        let appRootPath = appRoot.standardizedFileURL.path
        guard target.path == appRootPath || target.path.hasPrefix(appRootPath + "/") else { return nil }
        return target
    }

    // MARK: - Binary framing (v3 streaming)

    /// Builds one per-file frame:
    /// `[pathLen u32][path][nonce 12][ctLen u64][ciphertext][tag 16]`.
    private static func frame(relativePath: String, sealed: AES.GCM.SealedBox) -> Data {
        let pathData = Data(relativePath.utf8)
        var out = Data()
        out.appendUInt32BE(UInt32(pathData.count))
        out.append(pathData)
        out.append(sealed.nonce.data)                        // 12 bytes
        out.appendUInt64BE(UInt64(sealed.ciphertext.count))
        out.append(sealed.ciphertext)
        out.append(sealed.tag)                               // 16 bytes
        return out
    }

    /// Reads the next frame's path-length prefix. Returns nil at a clean EOF
    /// (frame boundary), throws `corruptBackup` on a partial read.
    private static func readFrameLength(from handle: FileHandle) throws -> UInt32? {
        var data = Data()
        while data.count < 4 {
            guard let chunk = try handle.read(upToCount: 4 - data.count), !chunk.isEmpty else {
                if data.isEmpty { return nil }
                throw BackupError.corruptBackup
            }
            data.append(chunk)
        }
        return data.toUInt32BE()
    }

    /// Reads exactly `count` bytes or throws `corruptBackup` on a short/EOF read.
    private static func readExact(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count >= 0 else { throw BackupError.corruptBackup }
        if count == 0 { return Data() }
        var data = Data()
        data.reserveCapacity(count)
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw BackupError.corruptBackup
            }
            data.append(chunk)
        }
        return data
    }

    /// Derives the AES key from the passphrase using PBKDF2-HMAC-SHA256 (real
    /// work factor), replacing the previous un-iterated SHA-256 (B-0047).
    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        // Throwing guard (NOT precondition): a hostile/corrupt envelope must not
        // crash the app.
        guard !salt.isEmpty else { throw BackupError.keyDerivationFailed(status: -1) }
        let passwordData = Data(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: derivedKeyByteCount)
        let status: Int32 = salt.withUnsafeBytes { saltBytes in
            passwordData.withUnsafeBytes { passBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passBytes.baseAddress!.assumingMemoryBound(to: CChar.self),
                    passwordData.count,
                    saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived,
                    derivedKeyByteCount
                )
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw BackupError.keyDerivationFailed(status: status)
        }
        let key = SymmetricKey(data: Data(derived))
        // Wipe the scratch buffer holding the raw key bytes.
        derived.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress {
                _ = memset_s(base, ptr.count, 0, ptr.count)
            }
        }
        return key
    }
}

private extension AES.GCM.Nonce {
    var data: Data { withUnsafeBytes { Data($0) } }
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(contentsOf: [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
    mutating func appendUInt64BE(_ value: UInt64) {
        var bytes = [UInt8]()
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
        append(contentsOf: bytes)
    }
    func toUInt32BE() -> UInt32 {
        let b = [UInt8](self)
        guard b.count == 4 else { return 0 }
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }
    func toUInt64BE() -> UInt64 {
        let b = [UInt8](self)
        guard b.count == 8 else { return 0 }
        var v: UInt64 = 0
        for byte in b { v = (v << 8) | UInt64(byte) }
        return v
    }
}
