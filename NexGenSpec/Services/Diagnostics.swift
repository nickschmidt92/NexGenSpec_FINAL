import Foundation
import FirebaseCrashlytics
import os

enum Diagnostics {
    private static let maxBytes = 512 * 1024
    private static let queue = DispatchQueue(label: "com.nexgenspec.diagnostics")

    /// Unified-log channel for the sync pipeline (A7). `.notice` persists to the
    /// log store, so a field device's sysdiagnose / Console capture shows the
    /// sync pipeline without a debugger attached.
    private static let syncLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.nexgenspec.app",
        category: "Sync"
    )

    /// Permanent sync-pipeline diagnostics (A7 — replaces the throwaway
    /// [SYNCDIAG] scaffolding). Mirrors `context` to (a) the unified log at
    /// `.notice` with PUBLIC privacy, and (b) the same sinks as `logInfo`
    /// (Crashlytics breadcrumb + the on-disk diagnostics.log).
    ///
    /// RULE: because the unified-log line is `privacy: .public`, call sites may
    /// contain ONLY record UUIDs, change tags, counts, zone names, and error
    /// codes/domains — never user content (client names, addresses, payloads, or
    /// report file paths, whose folder names embed client name + address).
    static func logSync(_ context: String) {
        syncLogger.notice("\(context, privacy: .public)")
        Crashlytics.crashlytics().log("SYNC: \(context)")
        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            append("[\(timestamp)] [SYNC] \(context)")
        }
    }

    static func logError(context: String, error: Error? = nil, persistToDisk: Bool = true) {
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
