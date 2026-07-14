import Foundation
import FirebaseCrashlytics
import os

enum Diagnostics {
    private static let maxBytes = 512 * 1024
    private static let queue = DispatchQueue(label: "com.nexgenspec.diagnostics")

    // Build-37 [SYNCDIAG] scaffolding (remove with the rest of the diag branch):
    // mirror to os_log so the lines stream live in Console.app from a
    // TestFlight/Release install. privacy: .public is required — Release
    // builds redact interpolated values to "<private>" otherwise.
    private static let console = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nexgenspec.app",
                                        category: "Diagnostics")

    static func logError(context: String, error: Error? = nil, persistToDisk: Bool = true) {
        let consoleMessage = error.map { "\(context): \($0.localizedDescription)" } ?? context
        console.error("\(consoleMessage, privacy: .public)")

        // Report to Crashlytics for remote monitoring
        if let error {
            Crashlytics.crashlytics().record(error: error, userInfo: ["context": context])
        } else {
            Crashlytics.crashlytics().log("ERROR: \(context)")
        }

        // The Crashlytics calls above touch no app directory. The on-disk
        // diagnostics.log, however, lives INSIDE FilePaths.appRoot (see
        // append()), so callers running during a Delete-Account wipe pass
        // persistToDisk: false to avoid re-creating the directory being deleted.
        guard persistToDisk else { return }
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
        console.notice("\(context, privacy: .public)")
        Crashlytics.crashlytics().log("INFO: \(context)")

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
