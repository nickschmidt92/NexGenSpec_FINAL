import Foundation
import SwiftUI

/// A helper for logging and exporting critical audit events (e.g. T&C acceptance),
/// with optional per-user logging support.
public struct AuditLog {
    public static let logFileName = "tc_audit_log.txt"

    /// Appends a line to the audit log with timestamp, optional user, app version, build, and event description.
    /// - Parameters:
    ///   - event: The event description to log.
    ///   - user: An optional user identifier to associate with the event.
    ///
    /// The log line format is:
    /// [timestamp] [user] [appVersion] [build] event
    /// If user, version, or build cannot be determined, falls back to previous format without version/build.
    public static func log(event: String, user: String? = nil, versionId: UUID? = nil, inspectionId: UUID? = nil) {
        AuditEventStore.append(AuditEvent(action: event, versionId: versionId, inspectionId: inspectionId, actorId: user))
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let line: String
        if let user = user, version != "?", build != "?" {
            line = "[\(timestamp)] [\(user)] [\(version)] [\(build)] \(event)\n"
        } else if let user = user {
            line = "[\(timestamp)] [\(user)] \(event)\n"
        } else {
            line = "[\(timestamp)] \(event)\n"
        }
        let url = logFileURL()
        try? FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
        // Append line to file
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            } else {
                // Basic error reporting: data conversion failed
                print("AuditLog Error: Failed to convert event line to data. Event: \(event), File URL: \(url)")
                // In production, implement user-facing error reporting here.
            }
            do {
                try handle.close()
            } catch {
                print("AuditLog Error: Failed to close file handle. Event: \(event), File URL: \(url), Error: \(error)")
                // In production, implement user-facing error reporting here.
            }
        } else {
            do {
                if let data = line.data(using: .utf8) {
                    try FileSecurity.writeProtected(data, to: url)
                } else {
                    print("AuditLog Error: Failed to convert event line to data. Event: \(event), File URL: \(url)")
                    // In production, implement user-facing error reporting here.
                }
            } catch {
                print("AuditLog Error: Failed to write event to log file. Event: \(event), File URL: \(url), Error: \(error)")
                // In production, implement user-facing error reporting here.
            }
        }
    }

    /// Reads the full audit log as plain text.
    public static func read() -> String {
        let url = logFileURL()
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return "No audit log events recorded."
        }
        return text
    }

    /// Returns the file URL of the audit log.
    public static func logFileURL() -> URL {
        FilePaths.auditLog
    }
}
