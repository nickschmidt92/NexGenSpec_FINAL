import SwiftUI

// MARK: - Pane selection (Overview, section, Summary, Finalize, Invoice & Send when finalized)
private enum InspectionPane: Hashable {
    case overview
    case section(UUID)
    case summary
    case finalize
    case invoice
}

/// Used for sheet presentation so item detail isn’t pushed (avoids keyboard constraint timeout).
private struct SectionItemRef: Hashable, Identifiable {
    let sectionIndex: Int
    let itemIndex: Int
    var id: Self { self }
}

// ──────────────────────────────────────────────────────────────
// MARK: - InspectionView -- edits a single InspectionVersion
// Sidebar: Overview | Sections (Roof, Attic, …) | Summary | Finalize. Detail: selected pane content.
// ──────────────────────────────────────────────────────────────

struct InspectionView: View {
    @EnvironmentObject private var store: InspectionStore
    @State var version: InspectionVersion
    var updated: (InspectionVersion) -> Void
    @State private var draft: InspectionVersion = .empty
    @State private var selectedPane: InspectionPane = .overview
    @State private var showShortcutsHelp = false
    @State private var showReportPreview = false
    @StateObject private var voiceManager = VoiceCommandManager()
    @StateObject private var weatherService = WeatherService()
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Auto-save debounce task. Cancelled + recreated on every `draft`
    /// change so rapid edits coalesce into one write ~1.0s after the
    /// user stops typing. A nil task means no write is pending.
    ///
    /// This is the critical primary save path — v1 only saved on
    /// `onDisappear`, which meant app crashes, force-quits, and
    /// log-out-mid-edit lost all in-progress work. Bug caught by
    /// TestFlight cohort 2026-04-19.
    @State private var autoSaveTask: Task<Void, Never>?
    private static let autoSaveDebounce: Duration = .seconds(1)

    // Timer state
    @State private var timerDisplayString = "00:00:00"
    @State private var timerSessionStart: Date?
    @State private var timerTimer: Timer?

    private var jobId: UUID {
        UUID(uuidString: draft.inspection.inspectionId) ?? version.id
    }

    var body: some View {
        ZStack {
            if sizeClass == .regular {
                iPadSplitLayout
            } else {
                sectionSidebar
            }
            VoiceCommandOverlay(voiceManager: voiceManager)
        }
        .navigationTitle(draft.inspection.clientName.isEmpty ? "Inspection \(draft.versionNumber)" : draft.inspection.clientName)
        .toolbar {
            // Save-state indicator. Visible in the toolbar at all times
            // so inspectors can trust the app isn't silently losing
            // their work — the #1 complaint from the first TestFlight
            // cohort.
            ToolbarItem(placement: .navigation) {
                saveStatusLabel
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Label("Timer: \(timerDisplayString)", systemImage: "timer")
                        .disabled(true)
                    if let w = draft.inspection.weather {
                        Label("\(w.temperatureString) \(w.conditions)", systemImage: "cloud.sun")
                            .disabled(true)
                    } else if weatherService.isFetching {
                        Label("Fetching weather…", systemImage: "cloud")
                            .disabled(true)
                    } else {
                        // Surface the underlying reason (location denied, simulator
                        // with no set location, WeatherKit entitlement missing, etc.)
                        // so the user can fix whichever is the real problem.
                        Label(weatherService.errorMessage ?? "Weather unavailable",
                              systemImage: "cloud.slash")
                            .disabled(true)
                        Button {
                            weatherService.retry { data in
                                if let data { draft.inspection.weather = data }
                            }
                        } label: {
                            Label("Retry weather", systemImage: "arrow.clockwise")
                        }
                    }
                    Divider()
                    if store.isSaving {
                        Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                            .disabled(true)
                    } else if let t = store.lastSavedAt {
                        Label("Last saved at \(t, style: .time)", systemImage: "clock")
                            .disabled(true)
                    }
                    Divider()
                    Button("Save") { store.saveNow() }
                        .keyboardShortcut("s", modifiers: .command)
                    Button("Previous Section") { selectPreviousSection() }
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                    Button("Next Section") { selectNextSection() }
                        .keyboardShortcut(.rightArrow, modifiers: .command)
                    Button("Finalize") { selectedPane = .finalize }
                        .keyboardShortcut("f", modifiers: .command)
                    Button("Preview Report") { showReportPreview = true }
                        .keyboardShortcut("p", modifiers: [.command, .shift])
                    if draft.locked {
                        Button("Invoice & Send") { selectedPane = .invoice }
                            .keyboardShortcut("i", modifiers: .command)
                    }
                    Divider()
                    Button("Keyboard Shortcuts") { showShortcutsHelp = true }
                        .keyboardShortcut("?", modifiers: .command)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showShortcutsHelp) {
            ShortcutsHelpView()
        }
        .fullScreenCover(isPresented: $showReportPreview) {
            ReportPreviewView(version: draft)
        }
        .onAppear {
            draft = version
            if draft.inspection.sections.isEmpty { selectedPane = .overview }
            voiceManager.onCommand = { action in
                handleVoiceCommand(action)
            }
            // Start timer
            startTimer()
            // Fetch weather if not already captured
            if draft.inspection.weather == nil {
                weatherService.fetchCurrentWeather { data in
                    if let data {
                        draft.inspection.weather = data
                    }
                }
            }
        }
        .onDisappear {
            pauseTimer()
            // Cancel any pending debounce; force-save immediately as a
            // backstop. Covers the normal "user navigates back to
            // dashboard" flow AND the rare case where the app is torn
            // down before the debounced save fires.
            autoSaveTask?.cancel()
            autoSaveTask = nil
            updated(draft)
            store.saveNow()
        }
        // ---- PRIMARY AUTO-SAVE PATH ----
        // Fires on every mutation of `draft` (every keystroke, every
        // photo append, every checkbox tap). We debounce ~1s so rapid
        // typing coalesces into a single disk write.
        //
        // Crucial for iPad inspectors in the field: if the app is
        // force-quit, battery dies, or crashes mid-inspection, no more
        // than ~1 second of work is at risk.
        .onChange(of: draft) { _, newDraft in
            autoSaveTask?.cancel()
            autoSaveTask = Task { @MainActor in
                try? await Task.sleep(for: Self.autoSaveDebounce)
                guard !Task.isCancelled else { return }
                updated(newDraft)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            pauseTimer()
            // App is about to background or be killed. Flush any
            // pending debounced save immediately — iOS gives us
            // seconds, not minutes, before suspending.
            autoSaveTask?.cancel()
            autoSaveTask = nil
            updated(draft)
            store.saveNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            startTimer()
        }
    }

    /// Compact indicator shown in the navigation toolbar so inspectors
    /// always know whether their work is on disk. Three states:
    ///   • Saving spinner + text while a write is in flight
    ///   • "Unsaved" pill (amber) if a debounced save is pending
    ///   • "Saved HH:MM" (green) otherwise — empty until first save
    @ViewBuilder
    private var saveStatusLabel: some View {
        if store.isSaving {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Saving…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        } else if autoSaveTask != nil {
            HStack(spacing: 4) {
                Image(systemName: "circle.dotted")
                Text("Unsaved")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
        } else if let t = store.lastSavedAt {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text("Saved \(t, style: .time)")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
        } else {
            EmptyView()
        }
    }

    private func handleVoiceCommand(_ action: VoiceCommandManager.CommandAction) {
        switch action {
        case .nextSection:
            selectNextSection()
        case .previousSection:
            selectPreviousSection()
        case .goToSummary:
            selectedPane = .summary
        case .goToFinalize:
            selectedPane = .finalize
        case .addNote(let text):
            // Add note to the current item's inspector comments if viewing a section
            if case .section(let sectionID) = selectedPane,
               let sIdx = draft.inspection.sections.firstIndex(where: { $0.id == sectionID }),
               !draft.inspection.sections[sIdx].items.isEmpty {
                let iIdx = draft.inspection.sections[sIdx].items.count - 1
                let existing = draft.inspection.sections[sIdx].items[iIdx].inspectorComments
                draft.inspection.sections[sIdx].items[iIdx].inspectorComments = existing.isEmpty ? text : "\(existing)\n\(text)"
            }
        case .defect(let description):
            // Add a new defect item to the current section
            if case .section(let sectionID) = selectedPane,
               let sIdx = draft.inspection.sections.firstIndex(where: { $0.id == sectionID }) {
                let newItem = InspectionItem(
                    templateItemId: "voice-\(UUID().uuidString)",
                    title: description,
                    includeInReport: true,
                    status: .inspected,
                    defectSeverity: .minor
                )
                draft.inspection.sections[sIdx].items.append(newItem)
            }
        case .capturePhoto:
            // Navigate to camera — for now, ensure we're in a section view
            // The actual camera trigger happens from ItemDetailView
            break
        case .goToCalendar:
            // Cross-tab navigation from deep inside an inspection. Post
            // a notification; MainTabView observes and switches the tab.
            NotificationCenter.default.post(name: .nexGenSpecRequestCalendarTab, object: nil)
        }
    }

    private func selectNextSection() {
        let sections = draft.inspection.sections
        guard !sections.isEmpty else { return }
        switch selectedPane {
        case .section(let id):
            if let idx = sections.firstIndex(where: { $0.id == id }), idx + 1 < sections.count {
                selectedPane = .section(sections[idx + 1].id)
            }
        default:
            selectedPane = .section(sections[0].id)
        }
    }

    private func selectPreviousSection() {
        let sections = draft.inspection.sections
        guard !sections.isEmpty else { return }
        switch selectedPane {
        case .section(let id):
            if let idx = sections.firstIndex(where: { $0.id == id }), idx > 0 {
                selectedPane = .section(sections[idx - 1].id)
            }
        default:
            selectedPane = .section(sections[sections.count - 1].id)
        }
    }

    // MARK: - Timer

    private func startTimer() {
        if draft.inspection.timerStartDate == nil {
            draft.inspection.timerStartDate = Date()
        }
        timerSessionStart = Date()
        updateTimerDisplay()
        timerTimer?.invalidate()
        timerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                updateTimerDisplay()
            }
        }
    }

    private func pauseTimer() {
        timerTimer?.invalidate()
        timerTimer = nil
        if let sessionStart = timerSessionStart {
            draft.inspection.timerElapsedSeconds += Date().timeIntervalSince(sessionStart)
            timerSessionStart = nil
        }
    }

    private func updateTimerDisplay() {
        var total = draft.inspection.timerElapsedSeconds
        if let sessionStart = timerSessionStart {
            total += Date().timeIntervalSince(sessionStart)
        }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let seconds = Int(total) % 60
        timerDisplayString = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private var sectionSidebar: some View {
        List {
            Section("Inspection") {
                NavigationLink {
                    paneContent(for: .overview)
                } label: {
                    Label("Overview", systemImage: "doc.text")
                }
                .accessibilityLabel("Overview")
                .accessibilityHint("Cover page, export report, capture room")
            }
            Section("Sections") {
                ForEach(draft.inspection.sections) { section in
                    NavigationLink {
                        paneContent(for: .section(section.id))
                    } label: {
                        SectionRowView(section: section)
                    }
                    .accessibilityLabel(section.title)
                    .accessibilityHint("\(section.items.count) items")
                }
            }
            Section("Actions") {
                NavigationLink {
                    paneContent(for: .summary)
                } label: {
                    Label("Summary", systemImage: "list.bullet.rectangle")
                }
                .accessibilityLabel("Summary")
                .accessibilityHint("Findings by severity")
                NavigationLink {
                    paneContent(for: .finalize)
                } label: {
                    Label("Finalize", systemImage: "lock.shield")
                }
                .accessibilityLabel("Finalize")
                .accessibilityHint("Signatures and lock report")
                if draft.locked {
                    NavigationLink {
                        paneContent(for: .invoice)
                    } label: {
                        Label("Invoice & Send", systemImage: "envelope.badge")
                    }
                    .accessibilityLabel("Invoice and send")
                    .accessibilityHint("Customer contact, invoice form, send to client and NexGenSpec")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Sections")
    }

    /// iPad-only: uses a NavigationSplitView for sidebar/detail layout.
    /// This is NOT nested inside a parent NavigationStack — the DashboardView's
    /// NavigationStack pushes to InspectionRootView, which renders InspectionView.
    /// On iPad (regular width), we break out of the parent stack's push and render
    /// a local split view for a better wide-screen experience.
    private var iPadSplitLayout: some View {
        NavigationSplitView {
            List(selection: Binding<InspectionPane?>(
                get: { selectedPane },
                set: { if let p = $0 { selectedPane = p } }
            )) {
                Section("Inspection") {
                    Label("Overview", systemImage: "doc.text")
                        .tag(InspectionPane.overview)
                }
                Section("Sections") {
                    ForEach(draft.inspection.sections) { section in
                        SectionRowView(section: section)
                            .tag(InspectionPane.section(section.id))
                    }
                }
                Section("Actions") {
                    Label("Summary", systemImage: "list.bullet.rectangle")
                        .tag(InspectionPane.summary)
                    Label("Finalize", systemImage: "lock.shield")
                        .tag(InspectionPane.finalize)
                    if draft.locked {
                        Label("Invoice & Send", systemImage: "envelope.badge")
                            .tag(InspectionPane.invoice)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Sections")
        } detail: {
            paneDetailContent
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var paneDetailContent: some View {
        paneContent(for: selectedPane)
    }

    @ViewBuilder
    private func paneContent(for pane: InspectionPane) -> some View {
        switch pane {
        case .overview:
            InspectionOverviewView(version: $draft)
        case .section(let sectionID):
            if let sectionIndex = draft.inspection.sections.firstIndex(where: { $0.id == sectionID }) {
                SectionItemsListView(
                    draft: $draft,
                    sectionIndex: sectionIndex,
                    jobId: jobId
                )
                .id(sectionID)
            } else {
                if #available(iOS 17.0, *) {
                    ContentUnavailableView("Section not found", systemImage: "list.bullet")
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "list.bullet")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Section not found")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .summary:
            SummaryView(viewModel: InspectionViewModel(version: draft))
        case .finalize:
            FinalizeView(version: $draft) { v in
                store.finalize(version: v)
                if let updatedVersion = store.loadFullVersion(id: v.id) {
                    draft = updatedVersion
                    selectedPane = .invoice
                }
            }
        case .invoice:
            InvoiceAndSendView(version: draft)
        }
    }
}

// MARK: - Section items list (sheet for item detail to avoid push + keyboard constraint timeout)
private struct SectionItemsListView: View {
    @Binding var draft: InspectionVersion
    let sectionIndex: Int
    let jobId: UUID

    @State private var selectedRef: SectionItemRef?

    var body: some View {
        let section = draft.inspection.sections[sectionIndex]
        List {
            ForEach(Array(section.items.enumerated()), id: \.element.id) { itemIndex, item in
                Button {
                    // Dismiss keyboard before presenting sheet to reduce "System gesture gate timed out"
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    selectedRef = SectionItemRef(sectionIndex: sectionIndex, itemIndex: itemIndex)
                } label: {
                    InspectionItemRowLabel(item: item)
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(section.title)
        .sheet(item: $selectedRef) { ref in
            NavigationStack {
                itemDetailView(for: ref)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { selectedRef = nil }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func itemDetailView(for ref: SectionItemRef) -> some View {
        ItemDetailView(
            item: Binding(
                get: { draft.inspection.sections[ref.sectionIndex].items[ref.itemIndex] },
                set: { draft.inspection.sections[ref.sectionIndex].items[ref.itemIndex] = $0 }
            ),
            jobId: jobId,
            isLocked: !draft.isEditable
        )
    }
}

// Condensed section row for sidebar (title + optional issue counts).
private struct SectionRowView: View {
    let section: InspectionSection

    var body: some View {
        HStack {
            Text(section.title)
                .lineLimit(1)
            Spacer()
            if section.safetyCount + section.majorCount + section.marginalCount + section.minorCount > 0 {
                Text("\(section.safetyCount + section.majorCount + section.marginalCount + section.minorCount)")
                    .font(.caption2)
                    .padding(4)
                    .background(AppColor.warning.opacity(0.2))
                    .foregroundStyle(AppColor.warning)
                    .clipShape(Circle())
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Keyboard shortcuts help
private struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Inspection") {
                    shortcutRow("⌘S", "Save")
                    shortcutRow("⌘←", "Previous section")
                    shortcutRow("⌘→", "Next section")
                    shortcutRow("⌘F", "Finalize")
                    shortcutRow("⇧⌘P", "Preview Report")
                    shortcutRow("⌘I", "Invoice & Send (when finalized)")
                    shortcutRow("⌘?", "This shortcuts list")
                }
                Section("Dashboard") {
                    shortcutRow("⌘N", "New Inspection")
                }
            }
            .navigationTitle("Keyboard Shortcuts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    private func shortcutRow(_ keys: String, _ action: String) -> some View {
        HStack {
            Text(action)
            Spacer()
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

// Label for an item in the section list (title, status, severity badge).
private struct InspectionItemRowLabel: View {
    let item: InspectionItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline)
                Text(item.status.displayName)
                    .font(.caption)
                    .foregroundStyle(item.isDefect ? AppColor.critical : Color.secondary)
            }
            Spacer()
            if let sev = item.defectSeverity {
                Text(sev.displayName)
                    .font(.caption)
                    .padding(4)
                    .background(sev.badgeColor.opacity(0.2))
                    .foregroundStyle(sev.badgeColor)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}
