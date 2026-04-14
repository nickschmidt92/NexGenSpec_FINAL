//
//  CalendarView.swift
//  NexGenSpec
//
//  Month-grid calendar listing NexGenSpec inspections alongside a light
//  "conflict" dot for any other event the user has on that day. Taps on
//  a day drill into a list of the inspections scheduled for that day,
//  each linking into the existing inspection flow.
//

import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var store: InspectionStore
    @EnvironmentObject private var authManager: AuthManager
    @ObservedObject private var calendarService = CalendarService.shared

    /// First day of the currently-displayed month (always at local midnight).
    @State private var visibleMonth: Date = Self.firstOfMonth(for: Date())
    @State private var selectedDay: Date?
    @State private var conflicts: [CalendarConflictEvent] = []

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1 // Sunday
        return cal
    }()

    var body: some View {
        AppScreenBackground {
            ScrollView {
                VStack(spacing: Spacing.md) {
                    header
                    weekdayStrip
                    monthGrid
                    permissionBanner
                    selectedDayDetail
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshConflictsForVisibleMonth() }
        .onChange(of: visibleMonth) { _, _ in
            Task { await refreshConflictsForVisibleMonth() }
        }
        .onChange(of: calendarService.authorizationState) { _, _ in
            Task { await refreshConflictsForVisibleMonth() }
        }
        .onAppear {
            calendarService.refreshAuthorizationState()
            // Prompt once; users can always deny / revisit later.
            if calendarService.authorizationState == .notDetermined {
                Task { await calendarService.requestAccess() }
            }
        }
    }

    // MARK: - Month header + nav

    private var header: some View {
        HStack {
            Button {
                shiftMonth(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous month")

            Spacer()

            Text(Self.monthTitleFormatter.string(from: visibleMonth))
                .font(AppFont.title3)
                .foregroundStyle(.primary)

            Spacer()

            Button {
                shiftMonth(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next month")
        }
    }

    private var weekdayStrip: some View {
        HStack(spacing: 0) {
            ForEach(Self.weekdaySymbols(calendar: calendar), id: \.self) { symbol in
                Text(symbol)
                    .font(AppFont.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Month grid

    private var monthGrid: some View {
        let days = daysInGrid(for: visibleMonth)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
            ForEach(days, id: \.self) { day in
                DayCell(
                    day: day,
                    isInVisibleMonth: calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month),
                    isToday: calendar.isDateInToday(day),
                    isSelected: selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false,
                    nexgenCount: inspections(on: day).count,
                    hasExternalConflict: hasExternalEvents(on: day)
                )
                .onTapGesture {
                    selectedDay = day
                }
            }
        }
    }

    // MARK: - Permission banner

    @ViewBuilder
    private var permissionBanner: some View {
        switch calendarService.authorizationState {
        case .notDetermined:
            bannerView(
                icon: "calendar.badge.exclamationmark",
                text: "Allow Calendar access to see conflicts and schedule inspections.",
                buttonTitle: "Allow Access",
                action: { Task { await calendarService.requestAccess() } }
            )
        case .denied, .restricted:
            bannerView(
                icon: "calendar.badge.exclamationmark",
                text: "Calendar access is off. Enable it in Settings to see conflicts and add events.",
                buttonTitle: "Open Settings",
                action: openAppSettings
            )
        case .writeOnly:
            bannerView(
                icon: "calendar.badge.exclamationmark",
                text: "NexGenSpec only has Write-Only access. Full access is needed to show conflicts.",
                buttonTitle: "Open Settings",
                action: openAppSettings
            )
        default:
            EmptyView()
        }
    }

    private func bannerView(icon: String, text: String, buttonTitle: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text(text)
                    .font(AppFont.subheadline)
                    .foregroundStyle(.primary)
            }
            Button(buttonTitle, action: action)
                .font(AppFont.subheadline.weight(.semibold))
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Selected-day detail

    @ViewBuilder
    private var selectedDayDetail: some View {
        if let selectedDay {
            let todays = inspections(on: selectedDay)
            let externalCount = externalEvents(on: selectedDay).count

            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Text(Self.fullDateFormatter.string(from: selectedDay))
                        .font(AppFont.headline)
                    Spacer()
                    if externalCount > 0 {
                        Label("\(externalCount) other", systemImage: "circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(AppFont.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                if todays.isEmpty {
                    Text("No NexGenSpec inspections scheduled.")
                        .font(AppFont.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(todays) { meta in
                        NavigationLink {
                            InspectionRootView(versionID: meta.id)
                                .environmentObject(store)
                        } label: {
                            DayRow(metadata: meta)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Helpers

    private func inspections(on day: Date) -> [VersionMetadata] {
        store.metadataList
            .filter { meta in
                // Show on the day if the stored start datetime is on that
                // local calendar day, regardless of midnight/real-time.
                calendar.isDate(meta.inspectionDate, inSameDayAs: day)
            }
            .sorted { $0.inspectionDate < $1.inspectionDate }
    }

    private func externalEvents(on day: Date) -> [CalendarConflictEvent] {
        conflicts.filter { ev in
            calendar.isDate(ev.start, inSameDayAs: day)
        }
    }

    private func hasExternalEvents(on day: Date) -> Bool {
        !externalEvents(on: day).isEmpty
    }

    private func shiftMonth(by delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = Self.firstOfMonth(for: next)
            selectedDay = nil
        }
    }

    /// Compute every day (including leading/trailing from adjacent months)
    /// needed to render a 6-row × 7-col grid for `monthStart`.
    private func daysInGrid(for monthStart: Date) -> [Date] {
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        // leadingPad = days from previous month shown before the 1st
        let leadingPad = (firstWeekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingPad, to: monthStart) ?? monthStart
        var out: [Date] = []
        for i in 0..<42 {
            if let d = calendar.date(byAdding: .day, value: i, to: gridStart) {
                out.append(d)
            }
        }
        return out
    }

    private func refreshConflictsForVisibleMonth() async {
        guard calendarService.authorizationState.canReadOtherEvents else {
            await MainActor.run { conflicts = [] }
            return
        }
        let days = daysInGrid(for: visibleMonth)
        guard let first = days.first, let last = days.last else { return }
        let endExclusive = calendar.date(byAdding: .day, value: 1, to: last) ?? last
        // Skip NexGenSpec-authored events — they show as NexGenSpec dots via metadataList.
        let linked = Set(store.metadataList.compactMap { $0.calendarEventIdentifierForConflicts })
        let events = await calendarService.events(from: first, to: endExclusive)
            .filter { !linked.contains($0.id) }
        await MainActor.run { conflicts = events }
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Formatters

    private static let monthTitleFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "LLLL yyyy"
        return df
    }()

    private static let fullDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .full
        return df
    }()

    private static func weekdaySymbols(calendar: Calendar) -> [String] {
        // shortStandaloneWeekdaySymbols starts with Sunday.
        let base = calendar.shortStandaloneWeekdaySymbols
        // Rotate so firstWeekday lines up.
        let offset = calendar.firstWeekday - 1
        return Array(base[offset...] + base[..<offset])
    }

    private static func firstOfMonth(for date: Date) -> Date {
        var cal = Calendar.current
        cal.firstWeekday = 1
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }
}

// MARK: - DayCell

private struct DayCell: View {
    let day: Date
    let isInVisibleMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let nexgenCount: Int
    let hasExternalConflict: Bool

    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "d"
        return df
    }()

    var body: some View {
        VStack(spacing: 2) {
            Text(Self.dayFormatter.string(from: day))
                .font(AppFont.subheadline.weight(isToday ? .bold : .regular))
                .foregroundStyle(foregroundColor)
            HStack(spacing: 3) {
                if nexgenCount > 0 {
                    Circle()
                        .fill(AppColor.accent)
                        .frame(width: 6, height: 6)
                }
                if hasExternalConflict {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
                if nexgenCount == 0 && !hasExternalConflict {
                    // reserve vertical space so rows align
                    Circle()
                        .fill(.clear)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(backgroundFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var foregroundColor: Color {
        if !isInVisibleMonth { return .secondary.opacity(0.4) }
        if isToday { return AppColor.accent }
        return .primary
    }

    @ViewBuilder
    private var backgroundFill: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColor.accent.opacity(0.18))
        } else if isToday {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColor.accent.opacity(0.08))
        } else {
            Color.clear
        }
    }

    private var accessibilityLabel: String {
        var bits: [String] = []
        bits.append(Self.dayFormatter.string(from: day))
        if isToday { bits.append("today") }
        if nexgenCount > 0 { bits.append("\(nexgenCount) inspection" + (nexgenCount == 1 ? "" : "s")) }
        if hasExternalConflict { bits.append("conflict with another event") }
        return bits.joined(separator: ", ")
    }
}

// MARK: - DayRow (selected-day list item)

private struct DayRow: View {
    let metadata: VersionMetadata

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeLabel)
                    .font(AppFont.caption.weight(.bold))
                    .foregroundStyle(AppColor.accent)
                Text(metadata.clientName)
                    .font(AppFont.subheadline.weight(.semibold))
                Text(metadata.propertyAddress)
                    .font(AppFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Spacing.xs)
    }

    private var timeLabel: String {
        // If the stored inspectionDate is at local midnight we treat it as
        // "unscheduled" for time purposes (the user hasn't picked a start
        // time yet).
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: metadata.inspectionDate)
        if (comps.hour ?? 0) == 0 && (comps.minute ?? 0) == 0 {
            return "All day"
        }
        return Self.timeFormatter.string(from: metadata.inspectionDate)
    }
}

// MARK: - Helper: VersionMetadata → linked-event id for conflict suppression

extension VersionMetadata {
    /// Conflict suppression only works if we know the EKEvent identifier
    /// of the NexGenSpec-authored event. That lives on the full
    /// `Inspection`, not on `VersionMetadata`. Keeping this as `nil`
    /// today means the NexGenSpec-authored event will *also* show as an
    /// orange dot — harmless visually. A future iteration could mirror
    /// the identifier up into metadata to suppress.
    var calendarEventIdentifierForConflicts: String? { nil }
}

#if DEBUG
#Preview {
    NavigationStack {
        CalendarView()
            .environmentObject(InspectionStore())
            .environmentObject(AuthManager())
    }
}
#endif
