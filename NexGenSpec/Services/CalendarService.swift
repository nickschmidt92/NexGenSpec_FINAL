//
//  CalendarService.swift
//  NexGenSpec
//
//  Thin wrapper around EventKit used to mirror NexGenSpec inspections into
//  the device's OS-level calendar. The app never reads events that it did
//  not author for editing purposes — it only reads the user's existing
//  events to display "conflict" dots on the in-app month grid, so the
//  inspector can see when a time slot clashes with something else.
//
//  Authorization: iOS 17+ uses `requestFullAccessToEvents`. "Full" access
//  is required because the app both creates/updates events and reads the
//  user's other events for conflict visualization. The Info.plist must
//  carry `NSCalendarsFullAccessUsageDescription` explaining why.
//
//  This class is `@MainActor` because it is used directly by SwiftUI
//  views (CalendarView, InspectionOverviewView, AppSettingsView) and
//  publishes `@Published` state they observe.
//

import Foundation
import EventKit

/// Represents the current calendar-access grant, mapped from
/// `EKAuthorizationStatus` to a form that the UI can reason about
/// without importing EventKit directly.
public enum CalendarAuthorizationState: Equatable {
    case notDetermined
    case denied
    case restricted
    case writeOnly      // iOS 17+: app has write but not read
    case fullAccess     // iOS 17+: the state we need for conflicts
    case unknown

    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .writeOnly: self = .writeOnly
        case .fullAccess: self = .fullAccess
        case .authorized: self = .fullAccess
        @unknown default: self = .unknown
        }
    }

    public var canCreateEvents: Bool {
        self == .fullAccess || self == .writeOnly
    }

    public var canReadOtherEvents: Bool {
        self == .fullAccess
    }
}

/// Error type surfaced to UI layers. String-convertible for simple
/// toast/banner messages.
public enum CalendarServiceError: Error, LocalizedError {
    case notAuthorized
    case missingCalendar
    case eventNotFound
    case eventKitError(Error)
    case missingStartTime

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "NexGenSpec does not have permission to access Calendar. Enable it in Settings > NexGenSpec > Calendar."
        case .missingCalendar:
            return "No writable calendar is available on this device."
        case .eventNotFound:
            return "The calendar event could not be found — it may have been deleted externally."
        case .eventKitError(let err):
            return "Calendar error: \(err.localizedDescription)"
        case .missingStartTime:
            return "Pick a start time for this inspection before adding it to your calendar."
        }
    }
}

/// Simple DTO used when drawing "conflict" overlays on the month grid.
/// Contains only the fields needed for that view — the raw EKEvent is
/// intentionally not exposed outside this service.
public struct CalendarConflictEvent: Identifiable, Equatable {
    public let id: String        // EKEvent.eventIdentifier
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let calendarTitle: String
}

@MainActor
public final class CalendarService: ObservableObject {

    /// Shared instance so multiple views can observe the same auth state
    /// and avoid creating competing EKEventStores.
    public static let shared = CalendarService()

    /// Current authorization. Starts as whatever the OS says at init
    /// time. Updated on each request.
    @Published public private(set) var authorizationState: CalendarAuthorizationState

    /// `EKEventStore` is documented as thread-safe for concurrent calls;
    /// we mark it `nonisolated(unsafe)` so the conflict-fetch path can
    /// run the blocking predicate query on a background executor
    /// without hopping back through the main actor.
    nonisolated(unsafe) private let store = EKEventStore()

    /// Default alarm offsets (seconds). Two alarms per event:
    ///   - 60 min before start
    ///   - the morning of the event at 8:00 local time (computed at
    ///     create/update time; this constant is a sentinel signaling
    ///     "day-before-at-8am" semantics)
    private let oneHourBefore: TimeInterval = -60 * 60

    public init() {
        self.authorizationState = CalendarAuthorizationState(
            EKEventStore.authorizationStatus(for: .event)
        )
    }

    // MARK: - Authorization

    /// Prompts for calendar access if not yet determined. No-op (returns
    /// current state) if the user already answered. Uses iOS 17's
    /// `requestFullAccessToEvents` since we need read access for
    /// conflict visualization.
    @discardableResult
    public func requestAccess() async -> CalendarAuthorizationState {
        do {
            if #available(iOS 17.0, *) {
                _ = try await store.requestFullAccessToEvents()
            } else {
                _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                    store.requestAccess(to: .event) { granted, error in
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume(returning: granted) }
                    }
                }
            }
        } catch {
            LoggerUtility.logError("CalendarService: requestAccess error \(error.localizedDescription)")
        }
        refreshAuthorizationState()
        return authorizationState
    }

    /// Re-reads `EKEventStore.authorizationStatus` and updates the
    /// published state. Call after returning from Settings.app.
    public func refreshAuthorizationState() {
        authorizationState = CalendarAuthorizationState(
            EKEventStore.authorizationStatus(for: .event)
        )
    }

    // MARK: - Calendars (for picker UI)

    /// All writable calendars the user could pick as their
    /// "NexGenSpec default".
    public func writableCalendars() -> [EKCalendar] {
        guard authorizationState.canCreateEvents else { return [] }
        return store.calendars(for: .event).filter { $0.allowsContentModifications }
    }

    /// Resolve a calendar by its stable identifier. Returns `nil` if
    /// the calendar has since been deleted from the device.
    public func calendar(withIdentifier id: String) -> EKCalendar? {
        store.calendar(withIdentifier: id)
    }

    /// Device default calendar for new events, or the first writable
    /// calendar if none is configured. Used as a last-resort fallback
    /// when `CalendarPreferences` has no stored choice.
    public func fallbackDefaultCalendar() -> EKCalendar? {
        store.defaultCalendarForNewEvents ?? writableCalendars().first
    }

    // MARK: - Event CRUD

    /// Create an OS-level event mirroring `inspection`, on `calendar`.
    /// Returns the new event identifier (which the caller should store
    /// on the inspection as `calendarEventIdentifier`).
    public func createEvent(
        for inspection: Inspection,
        in calendar: EKCalendar
    ) throws -> String {
        guard authorizationState.canCreateEvents else {
            throw CalendarServiceError.notAuthorized
        }
        guard inspection.hasScheduledStartTime else {
            throw CalendarServiceError.missingStartTime
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        apply(inspection: inspection, to: event)
        do {
            try store.save(event, span: .thisEvent)
            return event.eventIdentifier ?? ""
        } catch {
            throw CalendarServiceError.eventKitError(error)
        }
    }

    /// Update an existing event. If the event no longer exists (user
    /// deleted it in Calendar.app), throws `.eventNotFound` so the
    /// caller can clear the saved identifiers and re-prompt.
    public func updateEvent(
        eventIdentifier: String,
        for inspection: Inspection
    ) throws {
        guard authorizationState.canCreateEvents else {
            throw CalendarServiceError.notAuthorized
        }
        guard inspection.hasScheduledStartTime else {
            throw CalendarServiceError.missingStartTime
        }
        guard let event = store.event(withIdentifier: eventIdentifier) else {
            throw CalendarServiceError.eventNotFound
        }
        apply(inspection: inspection, to: event)
        do {
            try store.save(event, span: .thisEvent)
        } catch {
            throw CalendarServiceError.eventKitError(error)
        }
    }

    /// Delete an event if it still exists. Missing events are treated
    /// as success — they're already gone, which is the goal.
    public func deleteEvent(eventIdentifier: String) throws {
        guard authorizationState.canCreateEvents else {
            throw CalendarServiceError.notAuthorized
        }
        guard let event = store.event(withIdentifier: eventIdentifier) else {
            return
        }
        do {
            try store.remove(event, span: .thisEvent)
        } catch {
            throw CalendarServiceError.eventKitError(error)
        }
    }

    /// Returns `true` iff the event identifier still resolves to an
    /// event in the store. Used by the UI to detect "externally
    /// deleted" before trying to update.
    public func eventExists(eventIdentifier: String) -> Bool {
        store.event(withIdentifier: eventIdentifier) != nil
    }

    // MARK: - Reads for the conflict overlay

    /// Fetch events in [start, end) across all calendars the user has
    /// exposed. Used only to power the month-grid conflict overlay —
    /// events are not displayed individually, only as "has-events"
    /// dots for non-NexGenSpec events on days that also hold an
    /// inspection slot.
    ///
    /// `EKEventStore.events(matching:)` is a blocking call that can
    /// take >100 ms on devices syncing large iCloud/Google calendars,
    /// so we run it on a detached task instead of the main actor.
    public func events(from start: Date, to end: Date) async -> [CalendarConflictEvent] {
        guard authorizationState.canReadOtherEvents else { return [] }
        let store = self.store
        return await Task.detached(priority: .userInitiated) { () -> [CalendarConflictEvent] in
            let predicate = store.predicateForEvents(
                withStart: start,
                end: end,
                calendars: nil
            )
            return store.events(matching: predicate).map { ek in
                CalendarConflictEvent(
                    id: ek.eventIdentifier ?? UUID().uuidString,
                    title: ek.title ?? "",
                    start: ek.startDate,
                    end: ek.endDate ?? ek.startDate,
                    isAllDay: ek.isAllDay,
                    calendarTitle: ek.calendar?.title ?? ""
                )
            }
        }.value
    }

    // MARK: - Private

    /// Copy the inspection's schedulable fields onto the given event.
    /// Used by both create and update paths so the logic lives in one
    /// place (title, notes body, alarms).
    private func apply(inspection: Inspection, to event: EKEvent) {
        event.title = Self.eventTitle(for: inspection)
        event.location = inspection.propertyAddress
        event.notes = Self.eventNotes(for: inspection)
        event.startDate = inspection.inspectionDate
        event.endDate = inspection.scheduledEndDate
        event.isAllDay = false

        // Refresh alarms every save so duration changes are reflected.
        event.alarms = []
        event.addAlarm(EKAlarm(relativeOffset: oneHourBefore))
        if let dayBeforeAt8 = Self.dayBeforeAt8AM(relativeTo: inspection.inspectionDate) {
            event.addAlarm(EKAlarm(absoluteDate: dayBeforeAt8))
        }
    }

    static func eventTitle(for inspection: Inspection) -> String {
        let address = inspection.propertyAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty {
            return "NexGenSpec Inspection"
        }
        return "NexGenSpec: \(address)"
    }

    static func eventNotes(for inspection: Inspection) -> String {
        var lines: [String] = []
        lines.append("NexGenSpec Inspection")
        lines.append("Job ID: \(inspection.inspectionId)")

        if !inspection.clientName.isEmpty {
            lines.append("")
            lines.append("Client: \(inspection.clientName)")
            if !inspection.clientPhone.isEmpty {
                lines.append("Phone: \(inspection.clientPhone)")
            }
            if !inspection.clientEmail.isEmpty {
                lines.append("Email: \(inspection.clientEmail)")
            }
        }

        if let buyer = inspection.buyersAgent, buyer.hasContent {
            lines.append("")
            lines.append("Buyer's Agent: \(agentLine(buyer))")
        }
        if let listing = inspection.listingAgent, listing.hasContent {
            lines.append("")
            lines.append("Listing Agent: \(agentLine(listing))")
        }

        return lines.joined(separator: "\n")
    }

    private static func agentLine(_ agent: RealEstateAgent) -> String {
        var parts: [String] = []
        if !agent.name.isEmpty { parts.append(agent.name) }
        if !agent.brokerage.isEmpty { parts.append(agent.brokerage) }
        if !agent.phone.isEmpty { parts.append(agent.phone) }
        if !agent.email.isEmpty { parts.append(agent.email) }
        return parts.joined(separator: " / ")
    }

    /// 8:00 local time on the day before `start`. Returns `nil` if the
    /// computed absolute alarm would be in the past (so EventKit does
    /// not reject the save). `calendar` and `now` are injectable for
    /// unit testing DST transitions and timezone behavior.
    static func dayBeforeAt8AM(
        relativeTo start: Date,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Date? {
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: start) else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: dayBefore)
        comps.hour = 8
        comps.minute = 0
        comps.second = 0
        guard let eightAM = calendar.date(from: comps) else { return nil }
        if eightAM <= now { return nil }
        return eightAM
    }
}
