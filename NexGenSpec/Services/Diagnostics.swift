import Foundation

enum Diagnostics {
    private static let maxBytes = 512 * 1024
    private static let queue = DispatchQueue(label: "com.nexgenspec.diagnostics")

    static func logError(context: String, error: Error? = nil) {
        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let message: String
            if let error {
                message = "[\(timestamp)] [ERROR] \(context): \(error.localizedDescription)"
            } else {
                message = "[\(timestamp)] [ERROR] \(context)"
            }
            append(message)
        }
    }

    static func logInfo(_ context: String) {
        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            append("[\(timestamp)] [INFO] \(context)")
        }
    }

    private static func append(_ line: String) {
        let url = FilePaths.appRoot.appendingPathComponent("diagnostics.log", isDirectory: false)
        let payload = (line + "\n").data(using: .utf8) ?? Data()
        do {
            try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(payload)
            } else {
                try FileSecurity.writeProtected(payload, to: url)
            }
            try trimIfNeeded(url: url)
        } catch {
            // Best effort logging only.
        }
    }

    private static func trimIfNeeded(url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs[.size] as? NSNumber, size.intValue > maxBytes else { return }
        let data = try Data(contentsOf: url)
        guard data.count > maxBytes / 2 else { return }
        let tail = data.suffix(maxBytes / 2)
        try FileSecurity.writeProtected(Data(tail), to: url)
    }
}
