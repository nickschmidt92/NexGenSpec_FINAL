//
//  AuditEventSchema.swift
//  NexGenSpec
//
//  Structured audit events (JSON lines) for export and compliance.
//

import Foundation

/// Single audit event for append-only log. Schema versioned for future changes.
public struct AuditEvent: Codable {
    public var schemaVersion: Int
    public var timestamp: Date
    public var action: String
    public var versionId: UUID?
    public var inspectionId: UUID?
    public var actorId: String?
    public var appVersion: String?
    public var build: String?
    public var payload: [String: String]?

    public init(schemaVersion: Int = 1, timestamp: Date = Date(), action: String, versionId: UUID? = nil, inspectionId: UUID? = nil, actorId: String? = nil, appVersion: String? = nil, build: String? = nil, payload: [String: String]? = nil) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.action = action
        self.versionId = versionId
        self.inspectionId = inspectionId
        self.actorId = actorId
        self.appVersion = appVersion
        self.build = build
        self.payload = payload
    }
}

enum AuditEventStore {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static var eventsURL: URL {
        FilePaths.appRoot.appendingPathComponent("audit_events.jsonl", isDirectory: false)
    }

    static func append(_ event: AuditEvent) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        var e = event
        if e.appVersion == nil { e.appVersion = version }
        if e.build == nil { e.build = build }
        guard let data = try? encoder.encode(e),
              let line = String(data: data, encoding: .utf8) else { return }
        let url = eventsURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            try? handle.close()
        } else {
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func readAll() -> [AuditEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let content = try? String(contentsOf: eventsURL, encoding: .utf8) else { return [] }
        return content.components(separatedBy: "\n").compactMap { line in
            guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AuditEvent.self, from: data)
        }
    }
}
