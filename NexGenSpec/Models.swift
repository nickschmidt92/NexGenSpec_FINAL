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
        sections: [InspectionSection],
        signatures: [InspectionSignature] = [],
        inspectorConfirmed: Bool = false,
        videos: [InspectionVideo] = [],
        weather: WeatherData? = nil,
        timerStartDate: Date? = nil,
        timerElapsedSeconds: Double = 0,
        coverPhotoFileName: String? = nil,
        buyersAgent: RealEstateAgent? = nil,
        listingAgent: RealEstateAgent? = nil
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
    }
}

// Backward-compatible Codable for Inspection (clientEmail/clientPhone added later).
extension Inspection {
    enum CodingKeys: String, CodingKey {
        case inspectionId, inspectionNumber, title, description, creationDate
        case clientName, clientEmail, clientPhone, propertyAddress, inspectionDate
        case inspectorName, sections, signatures, inspectorConfirmed, videos
        case weather, timerStartDate, timerElapsedSeconds
        case coverPhotoFileName, buyersAgent, listingAgent
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
    }
}

// MARK: - Version

public struct InspectionVersion: Identifiable, Codable, Equatable {
    public var inspectionVersionId: UUID
    public var versionNumber: Int
    public var status: VersionStatus
    public var finalizedAt: Date?
    public var locked: Bool
    public var inspection: Inspection

    public var id: UUID { inspectionVersionId }

    public init(
        id: UUID = UUID(),
        versionNumber: Int,
        status: VersionStatus,
        finalizedAt: Date? = nil,
        locked: Bool,
        inspection: Inspection
    ) {
        self.inspectionVersionId = id
        self.versionNumber = versionNumber
        self.status = status
        self.finalizedAt = finalizedAt
        self.locked = locked
        self.inspection = inspection
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

public extension Inspection {
    func summaryCounts() -> SummaryCounts {
        var c = SummaryCounts(safety: 0, major: 0, marginal: 0, minor: 0)
        for s in sections {
            for i in s.items where i.isDefect {
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
