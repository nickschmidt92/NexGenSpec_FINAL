import Foundation
import CryptoKit
import CommonCrypto

enum EncryptedBackupService {

    // MARK: - Config (B-0047)

    /// Current backup format. v4 streams one encrypted file at a time (header +
    /// per-file frames) so peak memory is bounded by the largest single file,
    /// not the whole store (T-01438). v4 adds STREAM-COMPLETENESS authentication
    /// over v3: the header carries the total `fileCount`, and every frame is
    /// sealed with the header bytes + its own relative path as AES-GCM additional
    /// authenticated data (AAD). Restore therefore (a) rejects any frame whose
    /// path or header was altered, and (b) requires the number of decrypted
    /// frames to equal `fileCount` — so a truncated / frame-dropped backup fails
    /// loudly instead of restoring a silent subset and reporting success
    /// (B-0047 stream-truncation hardening). v1/v2/v3 are no longer restorable;
    /// per the disposable-tester-data decision they are rejected with a clear
    /// "create a new backup" error (no migration path).
    static let currentSchemaVersion = 4
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

    /// JSON header at the front of a v4 backup, length-prefixed by a UInt32.
    /// Carries the KDF parameters and the total `fileCount` (the per-file
    /// ciphertext follows as binary frames). The exact header bytes are bound
    /// into every frame as AES-GCM AAD, so `fileCount` (and the KDF params)
    /// cannot be tampered without failing decryption. No file data lives here —
    /// that is the whole point (T-01438).
    struct BackupHeader: Codable {
        var schemaVersion: Int
        var createdAt: Date
        var salt: Data
        var kdfAlgorithm: String
        var kdfIterations: Int
        var fileCount: Int
    }

    static func createEncryptedBackup(passphrase: String, destinationURL: URL) throws {
        guard passphrase.count >= minPassphraseLength else {
            throw BackupError.passphraseTooShort(min: minPassphraseLength)
        }
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: pbkdf2Iterations)

        // Enumerate the file set FIRST so the total count can be committed in the
        // header (which is written before any frame). Restore compares it to the
        // number of frames actually decrypted and rejects a truncated stream
        // (B-0047). Only relative paths are held here — not file bytes — so peak
        // memory is still bounded by the largest single file (T-01438).
        let root = FilePaths.appRoot
        var relativePaths: [String] = []
        if FileManager.default.fileExists(atPath: root.path) {
            for relative in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
                let absolute = root.appendingPathComponent(relative)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: absolute.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                if relative.hasSuffix(".backup.enc") { continue }
                relativePaths.append(relative)
            }
        }

        // Write the length-prefixed header first (creating the file with file
        // protection), then append one encrypted file at a time so peak memory
        // is bounded by the largest single file, not the whole store (T-01438).
        let header = BackupHeader(schemaVersion: currentSchemaVersion, createdAt: Date(),
                                  salt: salt, kdfAlgorithm: kdfAlgorithmID,
                                  kdfIterations: pbkdf2Iterations, fileCount: relativePaths.count)
        let headerData = try JSONEncoder().encode(header)
        var prefix = Data()
        prefix.appendUInt32BE(UInt32(headerData.count))
        prefix.append(headerData)
        try FileSecurity.writeProtected(prefix, to: destinationURL)

        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        for relative in relativePaths {
            let absolute = root.appendingPathComponent(relative)
            let fileData = try Data(contentsOf: absolute)           // one file in RAM
            // Bind the header bytes + this file's relative path as AAD so a
            // tampered count/path or a substituted frame fails AES-GCM open.
            let frameAAD = aad(headerData: headerData, relativePath: relative)
            let sealed = try AES.GCM.seal(fileData, using: key, authenticating: frameAAD)
            try handle.write(contentsOf: frame(relativePath: relative, sealed: sealed))
        }
        AuditLog.log(event: "Encrypted backup created (schema v\(currentSchemaVersion), PBKDF2 \(pbkdf2Iterations), \(relativePaths.count) files, streamed)")
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
        let headerData = try readExact(headerLen, from: handle)
        let header = try JSONDecoder().decode(BackupHeader.self, from: headerData)

        guard header.schemaVersion == currentSchemaVersion else {
            throw BackupError.unsupportedSchema(found: header.schemaVersion, supported: currentSchemaVersion)
        }
        guard header.kdfAlgorithm == kdfAlgorithmID else { throw BackupError.unknownKDF(header.kdfAlgorithm) }
        guard header.kdfIterations >= minAcceptableIterations,
              header.kdfIterations <= maxAcceptableIterations else {
            throw BackupError.weakKDF(iterations: header.kdfIterations)
        }
        let key = try deriveKey(passphrase: passphrase, salt: header.salt, iterations: header.kdfIterations)

        // Atomic restore (B-0062): decrypt + write EVERY frame into a throwaway
        // STAGING directory first; only if all frames succeed do we swap staging
        // into the live store. A mid-stream failure (disk-full, a decrypt throw on
        // a later frame, a FileHandle error, or a process kill) therefore touches
        // only staging — the live store is never left half-old / half-new, which
        // is exactly the data-loss this restore is meant to prevent. The common
        // wrong-passphrase case still fails fast: the FIRST frame's AES.GCM.open
        // throws before staging is ever swapped in, so live data is untouched.
        let fm = FileManager.default
        let appRoot = FilePaths.appRoot
        // Sibling temp dirs in the same parent (Application Support) so the final
        // moves stay on one volume and are real renames, not cross-device copies.
        let parent = appRoot.deletingLastPathComponent()
        let unique = UUID().uuidString
        let staging = parent.appendingPathComponent("NexGenSpec.staging-\(unique)", isDirectory: true)
        let snapshot = parent.appendingPathComponent("NexGenSpec.rollback-\(unique)", isDirectory: true)
        // Always tear down both temp trees, however we leave.
        defer {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: snapshot)
        }
        try? fm.removeItem(at: staging)
        try FileSecurity.ensureProtectedDirectory(staging)

        // Phase 1 — decrypt + write all files into staging (off the live store).
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

            // Validate the path (T-01437) against the LIVE appRoot — same checks
            // as a direct restore — then redirect the write into the matching
            // location under staging (which mirrors the appRoot layout).
            guard safeRestoreTarget(forRelativePath: relative) != nil else {
                throw BackupError.unsafePath(relative)
            }
            let stagedTarget = staging.appendingPathComponent(relative)
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonceData),
                                            ciphertext: ciphertext, tag: tag)
            // Re-bind the same AAD (header bytes + this frame's path). A frame
            // whose path was altered, or that came from a header with a tampered
            // fileCount/KDF, fails this open() — it never reaches staging.
            let clear = try AES.GCM.open(box, using: key,
                                         authenticating: aad(headerData: headerData, relativePath: relative))
            // Same file-protection attributes as a direct restore (writeProtected).
            try FileSecurity.writeProtected(clear, to: stagedTarget)
            fileCount += 1
        }

        // Stream-completeness check (B-0047): the number of frames actually
        // decrypted must equal the count the (authenticated) header committed to.
        // A truncated / frame-dropped backup ends at a clean frame boundary and
        // would otherwise "restore" a silent subset and report success — here it
        // fails loudly BEFORE the atomic swap, so the live store is never touched.
        guard fileCount == header.fileCount else { throw BackupError.corruptBackup }

        // Phase 2 — atomic swap with snapshot rollback. A whole-tree
        // FileManager.replaceItemAt is avoided here: the live appRoot also holds
        // the Backups/ folder (including the .enc we are restoring FROM and any
        // sibling backups) which the captured envelope may not faithfully contain,
        // so a blind whole-tree replace could delete still-needed backups. Instead
        // we move the live tree aside as a snapshot, move staging into place,
        // and preserve Backups/ from the snapshot. On ANY failure we move the
        // snapshot back, so the live store is restored EXACTLY as it was.
        try? fm.removeItem(at: snapshot)
        let liveExisted = fm.fileExists(atPath: appRoot.path)
        if liveExisted {
            try fm.moveItem(at: appRoot, to: snapshot)   // live -> snapshot (atomic rename)
        }
        do {
            try fm.moveItem(at: staging, to: appRoot)    // staging -> live (atomic rename)
            // Preserve the live Backups/ directory across the swap so we never
            // lose the source backup or its siblings.
            if liveExisted {
                let savedBackups = snapshot.appendingPathComponent("Backups", isDirectory: true)
                if fm.fileExists(atPath: savedBackups.path) {
                    let newBackups = appRoot.appendingPathComponent("Backups", isDirectory: true)
                    try? fm.removeItem(at: newBackups)
                    try fm.moveItem(at: savedBackups, to: newBackups)
                    try? fm.setAttributes([.protectionKey: FileSecurity.fileProtection], ofItemAtPath: newBackups.path)
                }
            }
        } catch {
            // Roll back: restore the original live tree from the snapshot, leaving
            // the store exactly as it was, then rethrow the original error type.
            try? fm.removeItem(at: appRoot)
            if liveExisted {
                try? fm.moveItem(at: snapshot, to: appRoot)
            }
            throw error
        }

        AuditLog.log(event: "Encrypted backup restored (schema v\(currentSchemaVersion), PBKDF2 \(header.kdfIterations), \(fileCount) files, staged+swapped)")
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

    /// Additional authenticated data bound into every frame (v4): the exact
    /// header bytes followed by the frame's relative path. Reconstructed
    /// identically on seal and open, so any tampering with the header (including
    /// `fileCount`) or a frame's path fails AES-GCM authentication.
    private static func aad(headerData: Data, relativePath: String) -> Data {
        var a = Data()
        a.append(headerData)
        a.append(Data(relativePath.utf8))
        return a
    }

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
