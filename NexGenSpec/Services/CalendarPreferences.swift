//
//  CalendarPreferences.swift
//  NexGenSpec
//
//  Per-user persistence for calendar-related preferences. Keyed by the
//  signed-in user's email so multiple inspectors on one device (shared
//  company iPad, for example) don't stomp on each other's settings.
//
//  Stored in UserDefaults because the values are small (two strings)
//  and cheap to read on every event save. Device keychain would be
//  overkill — calendar identifiers are not secrets.
//

import Foundation

public enum CalendarPreferences {

    private static let defaultCalendarKeyPrefix = "NexGenSpec.calendar.defaultCalendarIdentifier."
    private static let autoAddNewInspectionsPrefix = "NexGenSpec.calendar.autoAddNewInspections."

    /// Canonical form of the login email used as the key suffix — lower
    /// cased + trimmed so a stray capital or space does not create a
    /// parallel preferences bucket.
    private static func normalize(email: String?) -> String {
        (email ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    // MARK: - Default calendar identifier

    /// The `EKCalendar.calendarIdentifier` of the calendar the user has
    /// picked as their "NexGenSpec default". Returns `nil` if never
    /// chosen (caller should fall back to the OS default calendar).
    public static func defaultCalendarIdentifier(for email: String?) -> String? {
        let key = defaultCalendarKeyPrefix + normalize(email: email)
        return UserDefaults.standard.string(forKey: key)
    }

    public static func setDefaultCalendarIdentifier(_ identifier: String?, for email: String?) {
        let key = defaultCalendarKeyPrefix + normalize(email: email)
        if let identifier, !identifier.isEmpty {
            UserDefaults.standard.set(identifier, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Auto-add new inspections

    /// When `true`, creating a new inspection also creates an event on
    /// the user's default calendar (assuming a real start time was
    /// picked). Defaults to `false` so we never surprise the inspector
    /// with an event before they've reviewed the details.
    public static func autoAddNewInspections(for email: String?) -> Bool {
        let key = autoAddNewInspectionsPrefix + normalize(email: email)
        return UserDefaults.standard.bool(forKey: key)
    }

    public static func setAutoAddNewInspections(_ value: Bool, for email: String?) {
        let key = autoAddNewInspectionsPrefix + normalize(email: email)
        UserDefaults.standard.set(value, forKey: key)
    }
}
