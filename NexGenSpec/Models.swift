//
//  Models.swift
//  NexGenSpec
//
//  Core data models. NexGenSpec reporting software — Denver, CO.
//

import SwiftUI
import Foundation

// MARK: - Enums

/// Per-item status (per NexGenSpec brief).
public enum ItemStatus: String, Codable, CaseIterable, Identifiable, Equatable {
    case inspected = "Inspected"
    case notInspected = "Not Inspected"
    case notPresent = "Not Present"
    public var id: Self { self }
}

public enum Severity: String, Codable, CaseIterable, Identifiable, Equatable {
    case safety = "Safety"
    case major = "Major"
    case marginal = "Marginal"
    case minor = "Minor"
    public var id: Self { self }
}

public enum VersionStatus: String, Codable, CaseIterable, Identifiable, Equatable {
    case draft = "Draft"
    case final = "Final"
    public var id: Self { self }
}

// MARK: - Media (photos on disk)

/// Photo reference. Stored on disk; no fileData in memory.
public struct InspectionPhoto: Identifiable, Codable, Equatable {
    public var id: UUID
    public var fileName: String
    public var caption: String
    public var sortOrder: Int
    /// AI-detected defect tags accepted by the inspector.
    public var defectTags: [String]

    public init(id: UUID = UUID(), fileName: String, caption: String = "", sortOrder: Int = 0, defectTags: [String] = []) {
        self.id = id
        self.fileName = fileName
        self.caption = caption
        self.sortOrder = sortOrder
        self.defectTags = defectTags
    }

    enum CodingKeys: String, CodingKey {
        case id, fileName, caption, sortOrder, defectTags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        defectTags = try c.decodeIfPresent([String].self, forKey: .defectTags) ?? []
    }
}

/// Video reference (e.g. drone footage). Stored on disk in inspection videos folder.
public struct InspectionVideo: Identifiable, Codable, Equatable {
    public var id: UUID
    public var fileName: String
    public var caption: String
    public var sortOrder: Int
    /// Optional source label, e.g. "drone", "walkthrough".
    public var source: String?

    public init(id: UUID = UUID(), fileName: String, caption: String = "", sortOrder: Int = 0, source: String? = "drone") {
        self.id = id
        self.fileName = fileName
        self.caption = caption
        self.sortOrder = sortOrder
        self.source = source
    }
}

/// Annotation color (per brief: green, yellow, red).
public enum AnnotationColor: String, Codable, CaseIterable {
    case green, yellow, red
}

// MARK: - Inspection Item

public struct InspectionItem: Identifiable, Codable, Equatable {
    public var id: UUID
    public var templateItemId: String
    public var title: String
    public var includeInReport: Bool
    public var status: ItemStatus
    /// When inspected and there is a defect. Nil = inspected OK.
    public var defectSeverity: Severity?
    public var location: String
    public var observed: String
    public var implication: String
    public var recommendation: String
    public var inspectorComments: String
    public var contractorTag: String
    public var photos: [InspectionPhoto]

    public init(
        id: UUID = UUID(),
        templateItemId: String,
        title: String,
        includeInReport: Bool = false,
        status: ItemStatus = .notInspected,
        defectSeverity: Severity? = nil,
        location: String = "",
        observed: String = "",
        implication: String = "",
        recommendation: String = "",
        inspectorComments: String = "",
        contractorTag: String = "",
        photos: [InspectionPhoto] = []
    ) {
        self.id = id
        self.templateItemId = templateItemId
        self.title = title
        self.includeInReport = includeInReport
        self.status = status
        self.defectSeverity = defectSeverity
        self.location = location
        self.observed = observed
        self.implication = implication
        self.recommendation = recommendation
        self.inspectorComments = inspectorComments
        self.contractorTag = contractorTag
        self.photos = photos
    }

    public var isDefect: Bool { status == .inspected && defectSeverity != nil }

    /// Severity-change seam with the one-shot report-inclusion default.
    ///
    /// The report body only renders items passing `isDefect && includeInReport`,
    /// but `includeInReport` defaults to false — so an inspector who just picked
    /// a severity built a "defect" the report silently excluded. Rule: when
    /// severity transitions nil → non-nil (the user just declared this item a
    /// defect), arm the report gates it now visibly implies: set
    /// `includeInReport = true`, and upgrade `status` to `.inspected` if it was
    /// still `.notInspected`.
    ///
    /// Deliberately ONE-SHOT at that transition: changing between two non-nil
    /// severities, clearing severity, re-saving, or re-rendering never re-forces
    /// the flags, so a manual "Include in Report" opt-out afterwards sticks.
    /// (Picking a severity again after clearing it to None is a new nil → value
    /// transition and arms the gates again.)
    public mutating func setDefectSeverity(_ newSeverity: Severity?) {
        let isFirstAssignment = defectSeverity == nil && newSeverity != nil
        defectSeverity = newSeverity
        guard isFirstAssignment else { return }
        includeInReport = true
        if status == .notInspected { status = .inspected }
    }

    private enum CodingKeys: String, CodingKey {
        case id, templateItemId, title, includeInReport, status, defectSeverity
        case location, observed, implication, recommendation, inspectorComments
        case contractorTag, photos
    }

    // Defensive decoder so adding a new stored property in a future build does
    // not fail to decode inspections saved by older builds — the synthesized
    // decoder throws on any missing key, and a thrown item-decode would make the
    // whole inspection (a legal record) fail to load. Mirrors the hand-written
    // decoders on Inspection / InspectionPhoto / InspectionSignature; each field
    // falls back to its init default. Encoding stays synthesized.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        templateItemId = try c.decodeIfPresent(String.self, forKey: .templateItemId) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        includeInReport = try c.decodeIfPresent(Bool.self, forKey: .includeInReport) ?? false
        status = try c.decodeIfPresent(ItemStatus.self, forKey: .status) ?? .notInspected
        defectSeverity = try c.decodeIfPresent(Severity.self, forKey: .defectSeverity)
        location = try c.decodeIfPresent(String.self, forKey: .location) ?? ""
        observed = try c.decodeIfPresent(String.self, forKey: .observed) ?? ""
        implication = try c.decodeIfPresent(String.self, forKey: .implication) ?? ""
        recommendation = try c.decodeIfPresent(String.self, forKey: .recommendation) ?? ""
        inspectorComments = try c.decodeIfPresent(String.self, forKey: .inspectorComments) ?? ""
        contractorTag = try c.decodeIfPresent(String.self, forKey: .contractorTag) ?? ""
        photos = try c.decodeIfPresent([InspectionPhoto].self, forKey: .photos) ?? []
    }
}

// MARK: - Section

public struct InspectionSection: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var items: [InspectionItem]

    public init(id: UUID = UUID(), title: String, items: [InspectionItem] = []) {
        self.id = id
        self.title = title
        self.items = items
    }

    public var safetyCount: Int { items.filter { $0.defectSeverity == .safety }.count }
    public var majorCount: Int { items.filter { $0.defectSeverity == .major }.count }
    public var marginalCount: Int { items.filter { $0.defectSeverity == .marginal }.count }
    public var minorCount: Int { items.filter { $0.defectSeverity == .minor }.count }
}

// MARK: - Real Estate Agent

/// Real estate agent associated with an inspection. Both buyer's and listing
/// agent are independently optional; an inspection may have one, both, or
/// neither. Empty strings are treated as "not provided".
public struct RealEstateAgent: Codable, Equatable, Hashable {
    public var name: String
    public var brokerage: String
    public var phone: String
    public var email: String

    public init(name: String = "", brokerage: String = "", phone: String = "", email: String = "") {
        self.name = name
        self.brokerage = brokerage
        self.phone = phone
        self.email = email
    }

    /// True if any field has content. Used to decide whether to render this
    /// agent on the report and in summary views.
    public var hasContent: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !brokerage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Inspection

// MARK: - Reminder / To-Do items
//
// Both are per-inspection scratchpads that testers asked for. A
// Reminder optionally carries a due date (surfaced as a dot/badge in
// the UI); a Todo is a pure checklist item. Kept as separate types
// so the UI can render them differently without bool-flag gymnastics.

public struct InspectionReminder: Identifiable, Codable, Equatable {
    public var id: UUID
    public var text: String
    public var dueAt: Date?
    public var isCompleted: Bool

    public init(id: UUID = UUID(), text: String = "", dueAt: Date? = nil, isCompleted: Bool = false) {
        self.id = id
        self.text = text
        self.dueAt = dueAt
        self.isCompleted = isCompleted
    }
}

public struct InspectionTodo: Identifiable, Codable, Equatable {
    public var id: UUID
    public var text: String
    public var isCompleted: Bool

    public init(id: UUID = UUID(), text: String = "", isCompleted: Bool = false) {
        self.id = id
        self.text = text
        self.isCompleted = isCompleted
    }
}

public struct Inspection: Identifiable, Codable, Equatable {
    public var inspectionId: String
    public var inspectionNumber: Int
    public var title: String
    public var description: String
    public var creationDate: Date
    public var clientName: String
    public var clientEmail: String
    public var clientPhone: String
    public var propertyAddress: String
    public var inspectionDate: Date
    public var inspectorName: String
    /// Company/branding snapshot, frozen onto the inspection at creation from
    /// `InspectorProfile.shared` (alongside `inspectorName`). Carried IN the
    /// synced inspection payload — NOT in device-local UserDefaults — so a
    /// record finalized on device A renders the report/invoice/ZIP with the
    /// correct company identity on device B (the profile is device-local and
    /// would otherwise be blank on B). Frozen at creation keeps the finalized
    /// integrity hash deterministic and byte-reproducible across devices.
    public var companyName: String
    public var licenseNumber: String
    public var companyPhone: String
    public var companyEmail: String
    /// Company logo, stored as a base64-encoded PNG so it rides along in the
    /// JSON payload (kept reasonably small — the source PNG is capped at 512px
    /// longest side by `InspectorProfile`). Nil when no logo was set.
    public var companyLogoBase64: String?
    public var sections: [InspectionSection]
    public var signatures: [InspectionSignature]
    public var inspectorConfirmed: Bool
    public var videos: [InspectionVideo]
    /// Weather conditions captured at inspection time.
    public var weather: WeatherData?
    /// Timer: when the inspection was first opened.
    public var timerStartDate: Date?
    /// Timer: total elapsed seconds (accumulated across sessions).
    public var timerElapsedSeconds: Double
    /// Filename (relative to inspection folder) of the cover photo of the
    /// property. Stored as `<jobId>/cover.jpg`. Nil until the user picks one.
    public var coverPhotoFileName: String?
    /// Buyer's-side real estate agent. Optional.
    public var buyersAgent: RealEstateAgent?
    /// Listing-side (seller's) real estate agent. Optional.
    public var listingAgent: RealEstateAgent?
    /// Planned duration of the inspection in minutes. When `nil`, the
    /// calendar layer treats it as the default (4 hours / 240 min). The
    /// inspector may override at schedule time.
    public var scheduledDurationMinutes: Int?
    /// Identifier (`EKEvent.eventIdentifier`) of the mirrored OS-calendar
    /// event, when the inspection has been added to the user's calendar.
    /// Nil until the inspector taps "Add to Calendar".
    public var calendarEventIdentifier: String?
    /// Identifier (`EKCalendar.calendarIdentifier`) of the calendar the
    /// mirrored event was written to. Stored so the app can refetch /
    /// update / delete the event later.
    public var calendarIdentifier: String?
    /// Per-inspection reminders. Lightweight scratchpad for the
    /// inspector ("bring extension ladder", "call client about gate
    /// code"). Optional due date surfaces as a badge.
    public var reminders: [InspectionReminder]
    /// Per-inspection todos. Plain checklist for the inspector,
    /// separate from section items — these are workflow tasks, not
    /// defects.
    public var todos: [InspectionTodo]

    public var id: String { inspectionId }

    public init(
        id: UUID = UUID(),
        inspectionNumber: Int = 0,
        title: String = "",
        description: String = "",
        creationDate: Date = Date(),
        clientName: String,
        clientEmail: String = "",
        clientPhone: String = "",
        propertyAddress: String,
        inspectionDate: Date,
        inspectorName: String,
        companyName: String = "",
        licenseNumber: String = "",
        companyPhone: String = "",
        companyEmail: String = "",
        companyLogoBase64: String? = nil,
        sections: [InspectionSection],
        signatures: [InspectionSignature] = [],
        inspectorConfirmed: Bool = false,
        videos: [InspectionVideo] = [],
        weather: WeatherData? = nil,
        timerStartDate: Date? = nil,
        timerElapsedSeconds: Double = 0,
        coverPhotoFileName: String? = nil,
        buyersAgent: RealEstateAgent? = nil,
        listingAgent: RealEstateAgent? = nil,
        scheduledDurationMinutes: Int? = nil,
        calendarEventIdentifier: String? = nil,
        calendarIdentifier: String? = nil,
        reminders: [InspectionReminder] = [],
        todos: [InspectionTodo] = []
    ) {
        self.inspectionId = id.uuidString
        self.inspectionNumber = inspectionNumber
        self.title = title
        self.description = description
        self.creationDate = creationDate
        self.clientName = clientName
        self.clientEmail = clientEmail
        self.clientPhone = clientPhone
        self.propertyAddress = propertyAddress
        self.inspectionDate = inspectionDate
        self.inspectorName = inspectorName
        self.companyName = companyName
        self.licenseNumber = licenseNumber
        self.companyPhone = companyPhone
        self.companyEmail = companyEmail
        self.companyLogoBase64 = companyLogoBase64
        self.sections = sections
        self.signatures = signatures
        self.inspectorConfirmed = inspectorConfirmed
        self.videos = videos
        self.weather = weather
        self.timerStartDate = timerStartDate
        self.timerElapsedSeconds = timerElapsedSeconds
        self.coverPhotoFileName = coverPhotoFileName
        self.buyersAgent = buyersAgent
        self.listingAgent = listingAgent
        self.scheduledDurationMinutes = scheduledDurationMinutes
        self.calendarEventIdentifier = calendarEventIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.reminders = reminders
        self.todos = todos
    }
}

// Backward-compatible Codable for Inspection (clientEmail/clientPhone added later).
extension Inspection {
    enum CodingKeys: String, CodingKey {
        case inspectionId, inspectionNumber, title, description, creationDate
        case clientName, clientEmail, clientPhone, propertyAddress, inspectionDate
        case inspectorName
        case companyName, licenseNumber, companyPhone, companyEmail, companyLogoBase64
        case sections, signatures, inspectorConfirmed, videos
        case weather, timerStartDate, timerElapsedSeconds
        case coverPhotoFileName, buyersAgent, listingAgent
        case scheduledDurationMinutes, calendarEventIdentifier, calendarIdentifier
        case reminders, todos
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inspectionId = try c.decode(String.self, forKey: .inspectionId)
        inspectionNumber = try c.decode(Int.self, forKey: .inspectionNumber)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decode(String.self, forKey: .description)
        creationDate = try c.decode(Date.self, forKey: .creationDate)
        clientName = try c.decode(String.self, forKey: .clientName)
        clientEmail = try c.decodeIfPresent(String.self, forKey: .clientEmail) ?? ""
        clientPhone = try c.decodeIfPresent(String.self, forKey: .clientPhone) ?? ""
        propertyAddress = try c.decode(String.self, forKey: .propertyAddress)
        inspectionDate = try c.decode(Date.self, forKey: .inspectionDate)
        inspectorName = try c.decode(String.self, forKey: .inspectorName)
        // Branding snapshot added in build 26. Decode OPTIONALLY with safe
        // defaults so inspections stored/synced by older builds (no branding
        // keys) still decode without throwing — they fall back to the live
        // profile at render time (see HTMLReportRenderer / InvoiceAndSendView).
        companyName = try c.decodeIfPresent(String.self, forKey: .companyName) ?? ""
        licenseNumber = try c.decodeIfPresent(String.self, forKey: .licenseNumber) ?? ""
        companyPhone = try c.decodeIfPresent(String.self, forKey: .companyPhone) ?? ""
        companyEmail = try c.decodeIfPresent(String.self, forKey: .companyEmail) ?? ""
        companyLogoBase64 = try c.decodeIfPresent(String.self, forKey: .companyLogoBase64)
        sections = try c.decode([InspectionSection].self, forKey: .sections)
        signatures = try c.decode([InspectionSignature].self, forKey: .signatures)
        inspectorConfirmed = try c.decode(Bool.self, forKey: .inspectorConfirmed)
        videos = try c.decodeIfPresent([InspectionVideo].self, forKey: .videos) ?? []
        weather = try c.decodeIfPresent(WeatherData.self, forKey: .weather)
        timerStartDate = try c.decodeIfPresent(Date.self, forKey: .timerStartDate)
        timerElapsedSeconds = try c.decodeIfPresent(Double.self, forKey: .timerElapsedSeconds) ?? 0
        coverPhotoFileName = try c.decodeIfPresent(String.self, forKey: .coverPhotoFileName)
        buyersAgent = try c.decodeIfPresent(RealEstateAgent.self, forKey: .buyersAgent)
        listingAgent = try c.decodeIfPresent(RealEstateAgent.self, forKey: .listingAgent)
        scheduledDurationMinutes = try c.decodeIfPresent(Int.self, forKey: .scheduledDurationMinutes)
        calendarEventIdentifier = try c.decodeIfPresent(String.self, forKey: .calendarEventIdentifier)
        calendarIdentifier = try c.decodeIfPresent(String.self, forKey: .calendarIdentifier)
        reminders = try c.decodeIfPresent([InspectionReminder].self, forKey: .reminders) ?? []
        todos = try c.decodeIfPresent([InspectionTodo].self, forKey: .todos) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inspectionId, forKey: .inspectionId)
        try c.encode(inspectionNumber, forKey: .inspectionNumber)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(creationDate, forKey: .creationDate)
        try c.encode(clientName, forKey: .clientName)
        try c.encode(clientEmail, forKey: .clientEmail)
        try c.encode(clientPhone, forKey: .clientPhone)
        try c.encode(propertyAddress, forKey: .propertyAddress)
        try c.encode(inspectionDate, forKey: .inspectionDate)
        try c.encode(inspectorName, forKey: .inspectorName)
        // Branding snapshot (build 26). Encode each string field ONLY when
        // non-empty (mirroring reminders/todos below). An inspection with no
        // branding then serializes byte-identically to a pre-build-26 record,
        // so the finalize integrity hash of any report sealed by an older build
        // keeps verifying after upgrade — emitting an empty-string key would
        // change the canonical sorted-key JSON and trip a FALSE "INTEGRITY
        // CHECK FAILED" banner on a legitimate, untouched report. Populated
        // branding still seals deterministically: sorted keys, and every device
        // encodes the same frozen model bytes. The logo is optional.
        if !companyName.isEmpty { try c.encode(companyName, forKey: .companyName) }
        if !licenseNumber.isEmpty { try c.encode(licenseNumber, forKey: .licenseNumber) }
        if !companyPhone.isEmpty { try c.encode(companyPhone, forKey: .companyPhone) }
        if !companyEmail.isEmpty { try c.encode(companyEmail, forKey: .companyEmail) }
        try c.encodeIfPresent(companyLogoBase64, forKey: .companyLogoBase64)
        try c.encode(sections, forKey: .sections)
        try c.encode(signatures, forKey: .signatures)
        try c.encode(inspectorConfirmed, forKey: .inspectorConfirmed)
        try c.encode(videos, forKey: .videos)
        try c.encodeIfPresent(weather, forKey: .weather)
        try c.encodeIfPresent(timerStartDate, forKey: .timerStartDate)
        try c.encode(timerElapsedSeconds, forKey: .timerElapsedSeconds)
        try c.encodeIfPresent(coverPhotoFileName, forKey: .coverPhotoFileName)
        try c.encodeIfPresent(buyersAgent, forKey: .buyersAgent)
        try c.encodeIfPresent(listingAgent, forKey: .listingAgent)
        try c.encodeIfPresent(scheduledDurationMinutes, forKey: .scheduledDurationMinutes)
        try c.encodeIfPresent(calendarEventIdentifier, forKey: .calendarEventIdentifier)
        try c.encodeIfPresent(calendarIdentifier, forKey: .calendarIdentifier)
        if !reminders.isEmpty { try c.encode(reminders, forKey: .reminders) }
        if !todos.isEmpty { try c.encode(todos, forKey: .todos) }
    }
}

// MARK: - Schedule helpers

public extension Inspection {
    /// The default inspection length used when `scheduledDurationMinutes`
    /// is `nil`. The user can override per-inspection at scheduling time.
    static let defaultScheduledDurationMinutes: Int = 240

    /// Effective duration (minutes) for calendar events.
    var effectiveDurationMinutes: Int {
        scheduledDurationMinutes ?? Inspection.defaultScheduledDurationMinutes
    }

    /// `inspectionDate` stored from a date-only picker lands on local
    /// midnight. Treat exactly-midnight (local) values as "unscheduled"
    /// — i.e. the inspector has not yet picked a specific start time.
    /// Calendar-event creation should prompt for a real time first.
    var hasScheduledStartTime: Bool {
        let comps = Calendar.current.dateComponents(
            [.hour, .minute, .second, .nanosecond],
            from: inspectionDate
        )
        let h = comps.hour ?? 0
        let m = comps.minute ?? 0
        let s = comps.second ?? 0
        let ns = comps.nanosecond ?? 0
        return !(h == 0 && m == 0 && s == 0 && ns == 0)
    }

    /// End datetime derived from `inspectionDate` + effective duration.
    var scheduledEndDate: Date {
        inspectionDate.addingTimeInterval(TimeInterval(effectiveDurationMinutes * 60))
    }
}

// MARK: - Version

public struct InspectionVersion: Identifiable, Codable, Equatable {
    /// Schema version anchor. v1.0 ships as 1. Beta JSON without this key decodes as 1.
    public var schemaVersion: Int
    public var inspectionVersionId: UUID
    public var versionNumber: Int
    public var status: VersionStatus
    public var finalizedAt: Date?
    public var locked: Bool
    /// Last local-edit time — the last-writer-wins clock for draft sync conflict
    /// resolution (build 22, slice 4c). Stamped by `InspectionStore.writeVersionToFile`
    /// on every genuine local write, and deliberately PRESERVED (never re-stamped)
    /// when a synced-in remote version is applied, so a pull doesn't overwrite the
    /// remote's edit time with the local pull time. Additive + optional: legacy JSON
    /// written before build 22 decodes to nil and falls back to the file mtime in
    /// `DiskVersionReader.localState`.
    public var updatedAt: Date?
    public var inspection: Inspection

    public var id: UUID { inspectionVersionId }

    public init(
        id: UUID = UUID(),
        versionNumber: Int,
        status: VersionStatus,
        finalizedAt: Date? = nil,
        locked: Bool,
        inspection: Inspection,
        updatedAt: Date? = nil,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.inspectionVersionId = id
        self.versionNumber = versionNumber
        self.status = status
        self.finalizedAt = finalizedAt
        self.locked = locked
        self.updatedAt = updatedAt
        self.inspection = inspection
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case inspectionVersionId
        case versionNumber
        case status
        case finalizedAt
        case locked
        case updatedAt
        case inspection
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.inspectionVersionId = try c.decode(UUID.self, forKey: .inspectionVersionId)
        self.versionNumber = try c.decode(Int.self, forKey: .versionNumber)
        self.status = try c.decode(VersionStatus.self, forKey: .status)
        self.finalizedAt = try c.decodeIfPresent(Date.self, forKey: .finalizedAt)
        self.locked = try c.decode(Bool.self, forKey: .locked)
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        self.inspection = try c.decode(Inspection.self, forKey: .inspection)
    }
}

// MARK: - Signature

/// Signature metadata. Image stored on disk at signatures/{id}.png when imageFileName is set; legacy may have imageData in memory.
public struct InspectionSignature: Identifiable, Equatable {
    public var id: UUID
    public var name: String
    /// Legacy: in-memory image (when loading old JSON). Prefer loading via SignatureStore when imageFileName != nil.
    public var imageData: Data?
    /// When set, image is on disk at signatures/{id}.png. Not encoded as full path.
    public var imageFileName: String?
    public var date: Date
    public var deviceId: String?

    public init(id: UUID = UUID(), name: String, imageData: Data? = nil, imageFileName: String? = nil, date: Date, deviceId: String? = nil) {
        self.id = id
        self.name = name
        self.imageData = imageData
        self.imageFileName = imageFileName
        self.date = date
        self.deviceId = deviceId
    }

    /// Load image data for report/display. Uses disk when imageFileName set, else in-memory imageData.
    public func loadImageData(jobId: UUID) -> Data? {
        if let data = imageData, !data.isEmpty { return data }
        return SignatureStore.loadImageData(jobId: jobId, signatureId: id)
    }
}

extension InspectionSignature: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, date, deviceId, imageFileName, imageData
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        date = try c.decode(Date.self, forKey: .date)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        imageFileName = try c.decodeIfPresent(String.self, forKey: .imageFileName)
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(deviceId, forKey: .deviceId)
        try c.encodeIfPresent(imageFileName, forKey: .imageFileName)
        // Do not encode imageData; image lives on disk when imageFileName is set.
    }
}

// MARK: - Summary Counts

public struct SummaryCounts {
    public var safety: Int
    public var major: Int
    public var marginal: Int
    public var minor: Int
}

// MARK: - Sendable conformance
//
// Every inspection model below is a pure value type with only value-type
// members (String/Int/Double/Bool/Date/UUID/Data/enums and arrays/optionals
// thereof — no classes, closures, or reference types). Declaring Sendable in
// the same file as the types lets the compiler verify this member-wise.
//
// This is what lets `InspectionStore` hand an `InspectionVersion` across its
// background I/O queue (off-main autosave write + off-main `loadFullVersionAsync`)
// without a data race, and it future-proofs the models for Swift 6 strict
// concurrency. (`WeatherData` gets the same treatment in WeatherService.swift.)
extension ItemStatus: Sendable {}
extension Severity: Sendable {}
extension VersionStatus: Sendable {}
extension AnnotationColor: Sendable {}
extension InspectionPhoto: Sendable {}
extension InspectionVideo: Sendable {}
extension InspectionItem: Sendable {}
extension InspectionSection: Sendable {}
extension RealEstateAgent: Sendable {}
extension InspectionReminder: Sendable {}
extension InspectionTodo: Sendable {}
extension InspectionSignature: Sendable {}
extension Inspection: Sendable {}
extension InspectionVersion: Sendable {}

public extension Inspection {
    /// Counts defects by severity. Pass `includeInReportOnly: true` for any
    /// REPORT-facing total (the report body and finalize per-section counts only
    /// show defects flagged `includeInReport`, so the header badges must match or
    /// they overstate the count — T-01439). Defaults to all defects for the
    /// editing/overview screens.
    func summaryCounts(includeInReportOnly: Bool = false) -> SummaryCounts {
        var c = SummaryCounts(safety: 0, major: 0, marginal: 0, minor: 0)
        for s in sections {
            for i in s.items where i.isDefect && (!includeInReportOnly || i.includeInReport) {
                guard let sev = i.defectSeverity else { continue }
                switch sev {
                case .safety: c.safety += 1
                case .major: c.major += 1
                case .marginal: c.marginal += 1
                case .minor: c.minor += 1
                }
            }
        }
        return c
    }
}

// MARK: - Display Extensions

extension Severity {
    public var displayName: String {
        switch self {
        case .safety: return "Safety"
        case .major: return "Major"
        case .marginal: return "Marginal"
        case .minor: return "Minor"
        }
    }
    public var badgeColor: Color {
        switch self {
        case .safety: return .red
        case .major: return .orange
        case .marginal: return .yellow
        case .minor: return .green
        }
    }
}

extension ItemStatus {
    public var displayName: String { rawValue }
    public var badgeColor: Color {
        switch self {
        case .inspected: return .green
        case .notInspected: return .gray
        case .notPresent: return .blue
        }
    }
}

extension VersionStatus {
    public var displayName: String { rawValue }
    public var badgeColor: Color {
        switch self {
        case .draft: return .orange
        case .final: return .green
        }
    }
}
