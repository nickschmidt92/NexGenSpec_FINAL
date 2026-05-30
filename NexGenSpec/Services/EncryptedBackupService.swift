import Foundation
import CryptoKit
import CommonCrypto

enum EncryptedBackupService {

    // MARK: - Config (B-0047)

    /// Current backup format. v1 used an un-iterated SHA-256 "KDF" and is no
    /// longer restorable (rejected with a clear, non-crashing error).
    static let currentSchemaVersion = 2
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
            }
        }
    }

    struct BackupEnvelope: Codable {
        var schemaVersion: Int
        var createdAt: Date
        var salt: Data
        var nonce: Data
        var cipherText: Data
        var tag: Data
        var kdfAlgorithm: String
        var kdfIterations: Int
    }

    struct BackupPayload: Codable {
        var files: [StoredFile]
    }

    struct StoredFile: Codable {
        var relativePath: String
        var data: Data
    }

    static func createEncryptedBackup(passphrase: String, destinationURL: URL) throws {
        guard passphrase.count >= minPassphraseLength else {
            throw BackupError.passphraseTooShort(min: minPassphraseLength)
        }
        let payload = try buildPayload()
        let payloadData = try JSONEncoder().encode(payload)

        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: pbkdf2Iterations)
        let sealed = try AES.GCM.seal(payloadData, using: key)

        let envelope = BackupEnvelope(
            schemaVersion: currentSchemaVersion,
            createdAt: Date(),
            salt: salt,
            nonce: sealed.nonce.data,
            cipherText: sealed.ciphertext,
            tag: sealed.tag,
            kdfAlgorithm: kdfAlgorithmID,
            kdfIterations: pbkdf2Iterations
        )
        let envelopeData = try JSONEncoder().encode(envelope)
        try FileSecurity.writeProtected(envelopeData, to: destinationURL)
        AuditLog.log(event: "Encrypted backup created (schema v\(currentSchemaVersion), PBKDF2 \(pbkdf2Iterations))")
    }

    static func restoreEncryptedBackup(passphrase: String, sourceURL: URL) throws {
        guard passphrase.count >= minPassphraseLength else {
            throw BackupError.passphraseTooShort(min: minPassphraseLength)
        }
        let envelopeData = try Data(contentsOf: sourceURL)

        // Stage 1: peek the schema version so an unsupported (e.g. legacy v1)
        // backup yields a precise, friendly error instead of an opaque decode
        // failure or a crash.
        struct VersionPeek: Decodable { let schemaVersion: Int }
        let peek = try JSONDecoder().decode(VersionPeek.self, from: envelopeData)
        guard peek.schemaVersion == currentSchemaVersion else {
            throw BackupError.unsupportedSchema(found: peek.schemaVersion, supported: currentSchemaVersion)
        }

        let envelope = try JSONDecoder().decode(BackupEnvelope.self, from: envelopeData)
        guard envelope.kdfAlgorithm == kdfAlgorithmID else {
            throw BackupError.unknownKDF(envelope.kdfAlgorithm)
        }
        guard envelope.kdfIterations >= minAcceptableIterations,
              envelope.kdfIterations <= maxAcceptableIterations else {
            throw BackupError.weakKDF(iterations: envelope.kdfIterations)
        }
        let key = try deriveKey(passphrase: passphrase, salt: envelope.salt, iterations: envelope.kdfIterations)

        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: envelope.nonce),
            ciphertext: envelope.cipherText,
            tag: envelope.tag
        )
        let clear = try AES.GCM.open(box, using: key)
        let payload = try JSONDecoder().decode(BackupPayload.self, from: clear)

        for file in payload.files {
            // Validate each stored path before writing — a crafted backup could
            // otherwise use `..`/absolute paths to overwrite files outside the
            // app's sandboxed store (T-01437).
            guard let target = safeRestoreTarget(forRelativePath: file.relativePath) else {
                throw BackupError.unsafePath(file.relativePath)
            }
            try FileSecurity.writeProtected(file.data, to: target)
        }
        AuditLog.log(event: "Encrypted backup restored (schema v\(currentSchemaVersion), PBKDF2 \(envelope.kdfIterations))")
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

    private static func buildPayload() throws -> BackupPayload {
        let root = FilePaths.appRoot
        guard FileManager.default.fileExists(atPath: root.path) else { return BackupPayload(files: []) }

        let urls = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        var files: [StoredFile] = []
        for relative in urls {
            let absolute = root.appendingPathComponent(relative)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absolute.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if relative.hasSuffix(".backup.enc") { continue }
            let data = try Data(contentsOf: absolute)
            files.append(StoredFile(relativePath: relative, data: data))
        }
        return BackupPayload(files: files)
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
