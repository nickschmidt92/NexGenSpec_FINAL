import Foundation

enum FileSecurity {
    static let fileProtection: FileProtectionType = .completeUntilFirstUserAuthentication

    static func ensureProtectedDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: fileProtection]
        )
        try? FileManager.default.setAttributes([.protectionKey: fileProtection], ofItemAtPath: url.path)
    }

    static func writeProtected(_ data: Data, to url: URL, options: Data.WritingOptions = [.atomic]) throws {
        try ensureProtectedDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: options)
        try? FileManager.default.setAttributes([.protectionKey: fileProtection], ofItemAtPath: url.path)
    }

    static func copyProtectedItem(from sourceURL: URL, to destinationURL: URL) throws {
        try ensureProtectedDirectory(destinationURL.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        try? FileManager.default.setAttributes([.protectionKey: fileProtection], ofItemAtPath: destinationURL.path)
    }
}
