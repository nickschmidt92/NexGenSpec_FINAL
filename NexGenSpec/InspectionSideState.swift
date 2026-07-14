//
//  InspectionSideState.swift
//  NexGenSpec
//
//  Cross-device per-inspection "side state": invoice amounts / sent / paid and
//  the archived flag. Historically these were device-local UserDefaults soft
//  flags (InspectionFlags / InvoiceAndSendView) with NO sync path, so an invoice
//  marked paid on the iPad never showed Paid on the iPhone/Mac.
//
//  DESIGN (sync data completeness pass). This state is created/edited AFTER a
//  version is finalized, and the finalized InspectionVersion record is sealed:
//  its payload is integrity-hashed and the server-side push guard refuses ALL
//  updates to a locked record. Side state therefore CANNOT ride the version
//  payload. Instead it lives in its own tiny JSON document at
//  `Inspections/<inspectionId>/sidestate.json` and syncs through the EXISTING
//  D-0203 MediaAsset machinery as `SyncAssetKind.sideState` — reusing the
//  allowlist, push/pull, tombstones, seeding, per-UID pinning, and the
//  server-modificationDate last-writer-wins arbitration wholesale, with no new
//  CloudKit record type beyond the MediaAsset type already in the planned
//  Dev→Prod schema deploy (T-01623).
//
//  MIGRATION: on the first read for an inspection with no side file, any legacy
//  per-UID UserDefaults values (invoice.sentAt/paidAt/price/services/total,
//  inspection.archivedAt) are hoisted into the file once and the file becomes
//  authoritative; UserDefaults stays legacy-read-only (still swept by
//  InspectionFlags.clearAll on Account Deletion).
//

import Foundation
import UIKit

extension Notification.Name {
    /// Posted (on main) whenever an inspection's side state changes — a local
    /// edit or a synced-in remote apply. `userInfo["inspectionId"]` is the
    /// inspection's UUID string; `userInfo["remote"]` is true for a synced-in
    /// change. Badge/list UI re-derives on receipt.
    public static let sideStateDidChange = Notification.Name("NexGenSpec.sideStateDidChange")
}

/// One inspection's synced side state. Codable is the on-disk AND transport
/// format (the file's bytes are the CloudKit payload) — additive-only: new
/// fields must be optional and decode with `decodeIfPresent`.
public struct InspectionSideState: Codable, Equatable {
    public var schemaVersion: Int
    /// The owning inspectionId (uuidString) — matches the folder the file lives in.
    public var inspectionId: String
    public var invoicePrice: String?
    public var invoiceServices: String?
    public var invoiceTotal: String?
    public var invoiceSentAt: Date?
    public var invoicePaidAt: Date?
    public var archivedAt: Date?
    /// Informational last-edit clock (LWW between devices is arbitrated by the
    /// asset machinery on the CloudKit server modificationDate; this travels in
    /// the payload for observability and future field-level merging).
    public var updatedAt: Date

    public init(
        inspectionId: String,
        invoicePrice: String? = nil,
        invoiceServices: String? = nil,
        invoiceTotal: String? = nil,
        invoiceSentAt: Date? = nil,
        invoicePaidAt: Date? = nil,
        archivedAt: Date? = nil,
        updatedAt: Date = .distantPast,
        schemaVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.inspectionId = inspectionId
        self.invoicePrice = invoicePrice
        self.invoiceServices = invoiceServices
        self.invoiceTotal = invoiceTotal
        self.invoiceSentAt = invoiceSentAt
        self.invoicePaidAt = invoicePaidAt
        self.archivedAt = archivedAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, inspectionId, invoicePrice, invoiceServices, invoiceTotal
        case invoiceSentAt, invoicePaidAt, archivedAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        inspectionId = try c.decode(String.self, forKey: .inspectionId)
        invoicePrice = try c.decodeIfPresent(String.self, forKey: .invoicePrice)
        invoiceServices = try c.decodeIfPresent(String.self, forKey: .invoiceServices)
        invoiceTotal = try c.decodeIfPresent(String.self, forKey: .invoiceTotal)
        invoiceSentAt = try c.decodeIfPresent(Date.self, forKey: .invoiceSentAt)
        invoicePaidAt = try c.decodeIfPresent(Date.self, forKey: .invoicePaidAt)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    /// True when nothing meaningful is set — writing/syncing such a state is
    /// pointless (used to skip creating files for untouched inspections).
    var isEmpty: Bool {
        (invoicePrice ?? "").isEmpty && (invoiceServices ?? "").isEmpty && (invoiceTotal ?? "").isEmpty
            && invoiceSentAt == nil && invoicePaidAt == nil && archivedAt == nil
    }
}

/// File-backed, cross-device store for `InspectionSideState`. Thread-safe
/// (lock-guarded) and callable from anywhere, mirroring the InspectionFlags
/// call sites it replaces; UI updates flow through `.sideStateDidChange`.
///
/// - Files live under the ACTIVE user's per-UID `appRoot`
///   (`Inspections/<inspectionId>/sidestate.json`), so per-account isolation
///   matches the on-disk store; the in-memory cache is invalidated whenever the
///   active segment changes (self-healing across account switches).
/// - Local writes emit `.mediaUpserted` so the CloudKit mirror pushes the file;
///   the amounts path debounces its emit (per-keystroke persistence would spam
///   CloudKit) and flushes on app-resign so a pending emit is never stranded.
/// - Remote applies land through `InspectionStoreVersionWriter.applyRemoteAsset`
///   (bytes to disk), which calls `noteRemoteChange` to invalidate the cache and
///   notify the UI. Receiver-side LWW (local file newer wins) is handled there.
public final class InspectionSideStateStore: @unchecked Sendable {

    public static let shared = InspectionSideStateStore()

    private let lock = NSLock()
    private enum Entry { case absent, present(InspectionSideState) }
    private var cache: [String: Entry] = [:]
    private var cacheSegment: String = ""
    /// Debounced sync emits, keyed by inspectionId. Main-queue work items.
    private var pendingEmits: [String: DispatchWorkItem] = [:]
    /// Debounce for the free-typed invoice amount fields.
    private let fieldEmitDebounce: TimeInterval = 2.0

    init() {
        // Flush any debounced sync emit when the app resigns active, so an edit
        // made just before backgrounding still mirrors to CloudKit promptly
        // (mirrors InspectionStore's willResignActive save).
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.flushPendingEmits()
        }
    }

    // MARK: - Paths

    static func relativePath(inspectionId: String) -> String {
        "Inspections/\(inspectionId)/\(FilePaths.sideStateFileName)"
    }

    private static func fileURL(inspectionId: String) -> URL? {
        guard let id = UUID(uuidString: inspectionId) else { return nil }
        return FilePaths.sideStateFile(inspectionId: id)
    }

    // MARK: - Reads

    /// The side state for an inspection, or nil when none exists. Read order:
    /// cache → `sidestate.json` → one-time legacy UserDefaults hoist.
    public func state(for inspectionId: String) -> InspectionSideState? {
        var hoisted: InspectionSideState?
        lock.lock()
        resetCacheIfSegmentChangedLocked()
        if let entry = cache[inspectionId] {
            defer { lock.unlock() }
            if case .present(let s) = entry { return s }
            return nil
        }
        if let url = Self.fileURL(inspectionId: inspectionId),
           let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode(InspectionSideState.self, from: data) {
            cache[inspectionId] = .present(s)
            lock.unlock()
            return s
        }
        // Legacy hoist (one-time per inspection): lift the old per-UID UserDefaults
        // soft flags into the synced file, then treat UserDefaults as read-only.
        if let legacy = Self.legacyState(inspectionId: inspectionId) {
            cache[inspectionId] = .present(legacy)
            writeToDiskLocked(legacy)
            scheduleEmitLocked(inspectionId: inspectionId, delay: 0)
            hoisted = legacy
        } else {
            cache[inspectionId] = .absent
        }
        lock.unlock()
        if hoisted != nil { postChange(inspectionId: inspectionId, remote: false) }
        return hoisted
    }

    public func invoiceSentAt(inspectionId: String) -> Date? { state(for: inspectionId)?.invoiceSentAt }
    public func invoicePaidAt(inspectionId: String) -> Date? { state(for: inspectionId)?.invoicePaidAt }
    public func archivedAt(inspectionId: String) -> Date? { state(for: inspectionId)?.archivedAt }
    public func isArchived(inspectionId: String) -> Bool { archivedAt(inspectionId: inspectionId) != nil }

    // MARK: - Writes (local edits — emit a sync change)

    public func setArchived(_ archived: Bool, inspectionId: String) {
        mutate(inspectionId: inspectionId) { $0.archivedAt = archived ? Date() : nil }
    }

    public func setInvoiceSent(at date: Date, inspectionId: String) {
        mutate(inspectionId: inspectionId) { $0.invoiceSentAt = date }
    }

    /// nil clears the paid marker.
    public func setInvoicePaid(at date: Date?, inspectionId: String) {
        mutate(inspectionId: inspectionId) { $0.invoicePaidAt = date }
    }

    /// Persists the free-typed invoice amount fields. The FILE write is
    /// immediate (no data loss); the SYNC emit is debounced so per-keystroke
    /// edits don't spam CloudKit. Empty strings normalize to nil so an
    /// echo-write of untouched blank fields is a detected no-op.
    public func setInvoiceFields(price: String, services: String, total: String, inspectionId: String) {
        mutate(inspectionId: inspectionId, emitDelay: fieldEmitDebounce) {
            $0.invoicePrice = price.isEmpty ? nil : price
            $0.invoiceServices = services.isEmpty ? nil : services
            $0.invoiceTotal = total.isEmpty ? nil : total
        }
    }

    // MARK: - Remote apply (called by the sync writer)

    /// A synced-in `sidestate.json` was written (or deleted) on disk for this
    /// inspection: drop the cached copy so the next read hits disk, and notify
    /// the UI. Safe from any thread.
    public func noteRemoteChange(inspectionId: String) {
        lock.withLock {
            resetCacheIfSegmentChangedLocked()
            cache[inspectionId] = nil
        }
        postChange(inspectionId: inspectionId, remote: true)
    }

    // MARK: - Internals

    private func mutate(inspectionId: String, emitDelay: TimeInterval = 0, _ apply: (inout InspectionSideState) -> Void) {
        lock.lock()
        resetCacheIfSegmentChangedLocked()
        // Read-through without the public accessor (we already hold the lock):
        // cache → disk → legacy — else a fresh empty state.
        var current: InspectionSideState
        if case .present(let s)? = cache[inspectionId] {
            current = s
        } else if let url = Self.fileURL(inspectionId: inspectionId),
                  let data = try? Data(contentsOf: url),
                  let s = try? JSONDecoder().decode(InspectionSideState.self, from: data) {
            current = s
        } else if let legacy = Self.legacyState(inspectionId: inspectionId) {
            current = legacy
        } else {
            current = InspectionSideState(inspectionId: inspectionId)
        }
        let before = current
        apply(&current)
        // No effective change → nothing to persist/emit; avoids updatedAt churn
        // and redundant CloudKit pushes. (A never-persisted empty state stays
        // absent; anything else is cached as-is.)
        if current == before {
            cache[inspectionId] = before.isEmpty ? .absent : .present(before)
            lock.unlock()
            return
        }
        current.updatedAt = Date()
        cache[inspectionId] = .present(current)
        writeToDiskLocked(current)
        scheduleEmitLocked(inspectionId: inspectionId, delay: emitDelay)
        lock.unlock()
        postChange(inspectionId: inspectionId, remote: false)
    }

    /// Writes the state file (protected, atomic). Caller holds `lock`.
    private func writeToDiskLocked(_ state: InspectionSideState) {
        guard let url = Self.fileURL(inspectionId: state.inspectionId) else { return }
        do {
            try FileSecurity.ensureProtectedDirectory(url.deletingLastPathComponent())
            let data = try JSONEncoder().encode(state)
            try FileSecurity.writeProtected(data, to: url)
        } catch {
            // Degrades to in-memory-only for this launch; the next successful
            // write (or the legacy UserDefaults fallback) still covers reads.
            Diagnostics.logError(context: "InspectionSideStateStore: side-state write failed", error: error)
        }
    }

    /// Schedules (or immediately fires) the `.mediaUpserted` emit for an
    /// inspection's side file. Caller holds `lock`. Coalesces per inspection:
    /// a newer schedule cancels the pending one.
    private func scheduleEmitLocked(inspectionId: String, delay: TimeInterval) {
        guard let jobId = UUID(uuidString: inspectionId) else { return }
        pendingEmits[inspectionId]?.cancel()
        let relativePath = Self.relativePath(inspectionId: inspectionId)
        if delay <= 0 {
            pendingEmits[inspectionId] = nil
            SyncCoordinator.noteMediaUpserted(jobId: jobId, relativePath: relativePath)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            self?.lock.withLock { self?.pendingEmits[inspectionId] = nil }
            SyncCoordinator.noteMediaUpserted(jobId: jobId, relativePath: relativePath)
        }
        pendingEmits[inspectionId] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Fires every pending debounced emit now (app resigning active).
    private func flushPendingEmits() {
        let items: [DispatchWorkItem] = lock.withLock {
            let pending = Array(pendingEmits.values)
            pendingEmits.removeAll()
            return pending
        }
        for item in items where !item.isCancelled {
            item.perform()
            item.cancel()   // the scheduled asyncAfter copy becomes a no-op
        }
    }

    /// The in-memory cache follows the ACTIVE per-UID segment: an account switch
    /// re-points `appRoot`, so cached entries from the previous segment must
    /// never answer for the new one. Caller holds `lock`.
    private func resetCacheIfSegmentChangedLocked() {
        let segment = SessionScope.currentSegment
        guard segment != cacheSegment else { return }
        cacheSegment = segment
        cache.removeAll()
        for item in pendingEmits.values { item.cancel() }
        pendingEmits.removeAll()
    }

    /// Reads the LEGACY per-UID UserDefaults soft flags for an inspection, or nil
    /// when none are set. Keys mirror InspectionFlags/InvoiceAndSendView exactly
    /// (scoped by `SessionScope.currentSegment`). Read-only: the values are left
    /// in place (swept later by InspectionFlags.clearAll on Account Deletion).
    private static func legacyState(inspectionId: String) -> InspectionSideState? {
        let defaults = UserDefaults.standard
        let sentAt = defaults.object(forKey: InspectionFlags.scopedKey("invoice.sentAt.\(inspectionId)")) as? Date
        let paidAt = defaults.object(forKey: InspectionFlags.scopedKey("invoice.paidAt.\(inspectionId)")) as? Date
        let archivedAt = defaults.object(forKey: InspectionFlags.scopedKey("inspection.archivedAt.\(inspectionId)")) as? Date
        let price = defaults.string(forKey: InspectionFlags.scopedKey("invoice.price.\(inspectionId)"))
        let services = defaults.string(forKey: InspectionFlags.scopedKey("invoice.services.\(inspectionId)"))
        let total = defaults.string(forKey: InspectionFlags.scopedKey("invoice.total.\(inspectionId)"))
        let state = InspectionSideState(
            inspectionId: inspectionId,
            invoicePrice: price, invoiceServices: services, invoiceTotal: total,
            invoiceSentAt: sentAt, invoicePaidAt: paidAt, archivedAt: archivedAt,
            // Informational clock: the newest legacy timestamp (LWW between
            // devices is mtime/server-date-based, so this is observability only).
            updatedAt: [sentAt, paidAt, archivedAt].compactMap { $0 }.max() ?? Date()
        )
        return state.isEmpty ? nil : state
    }

    private func postChange(inspectionId: String, remote: Bool) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .sideStateDidChange,
                object: nil,
                userInfo: ["inspectionId": inspectionId, "remote": remote]
            )
        }
    }
}
