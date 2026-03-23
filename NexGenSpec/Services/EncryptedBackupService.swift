import Foundation
import CryptoKit

enum EncryptedBackupService {
    struct BackupEnvelope: Codable {
        var schemaVersion: Int
        var createdAt: Date
        var salt: Data
        var nonce: Data
        var cipherText: Data
        var tag: Data
    }

    struct BackupPayload: Codable {
        var files: [StoredFile]
    }

    struct StoredFile: Codable {
        var relativePath: String
        var data: Data
    }

    static func createEncryptedBackup(passphrase: String, destinationURL: URL) throws {
        let payload = try buildPayload()
        let payloadData = try JSONEncoder().encode(payload)

        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let key = keyFrom(passphrase: passphrase, salt: salt)
        let sealed = try AES.GCM.seal(payloadData, using: key)

        let envelope = BackupEnvelope(
            schemaVersion: 1,
            createdAt: Date(),
            salt: salt,
            nonce: sealed.nonce.data,
            cipherText: sealed.ciphertext,
            tag: sealed.tag
        )
        let envelopeData = try JSONEncoder().encode(envelope)
        try FileSecurity.writeProtected(envelopeData, to: destinationURL)
        AuditLog.log(event: "Encrypted backup created")
    }

    static func restoreEncryptedBackup(passphrase: String, sourceURL: URL) throws {
        let envelopeData = try Data(contentsOf: sourceURL)
        let envelope = try JSONDecoder().decode(BackupEnvelope.self, from: envelopeData)
        let key = keyFrom(passphrase: passphrase, salt: envelope.salt)

        let box = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: envelope.nonce),
            ciphertext: envelope.cipherText,
            tag: envelope.tag
        )
        let clear = try AES.GCM.open(box, using: key)
        let payload = try JSONDecoder().decode(BackupPayload.self, from: clear)

        for file in payload.files {
            let target = FilePaths.appRoot.appendingPathComponent(file.relativePath)
            try FileSecurity.writeProtected(file.data, to: target)
        }
        AuditLog.log(event: "Encrypted backup restored")
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

    private static func keyFrom(passphrase: String, salt: Data) -> SymmetricKey {
        let input = Data(passphrase.utf8) + salt
        let digest = SHA256.hash(data: input)
        return SymmetricKey(data: Data(digest))
    }
}

private extension AES.GCM.Nonce {
    var data: Data { withUnsafeBytes { Data($0) } }
}
