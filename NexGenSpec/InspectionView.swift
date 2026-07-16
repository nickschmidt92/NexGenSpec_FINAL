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
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @State var version: InspectionVersion
    var updated: (InspectionVersion) -> Void
    @State private var draft: InspectionVersion = .empty
    @State private var selectedPane: InspectionPane = .overview
    @State private var showReportPreview = false
    /// Drives the post-finalize Invoice & Send presentation. Shown as a
    /// fullScreenCover so the redirect lands reliably on BOTH iPhone (whose
    /// sidebar uses push navigation and ignores `selectedPane`) and iPad
    /// (split view). The store no longer pops this view on finalize (the
    /// metadata publish is deferred — see InspectionStore.finalize), so the
    /// cover, presented by this still-alive view, survives the finalize.
    @State private var showInvoiceCover = false
    /// One-shot: after finalize we defer the ZIP-backup prompt and the App
    /// Store review request until the Invoice cover is dismissed, so they don't
    /// collide with presenting the cover (only one modal can present at a time).
    @State private var pendingPostInvoicePrompts = false

    // T-01213: Auto-export ZIP backup prompt that fires once a version is
    // finalized. The bundle lands in the per-UID private store
    // (FilePaths.exportsFolder, under appRoot — not the file-shared Documents
    // directory) and is surfaced via the share sheet so the inspector can drop it
    // into Files, iCloud Drive, email, or AirDrop on demand.
    @State private var showExportZIPPrompt = false
    @State private var isExportingZIP = false
    @State private var exportZIPURL: URL?
    @State private var showExportShareSheet = false
    @State private var exportZIPError: String?
    @State private var showExportZIPError = false
    /// Long-lived view model for the Summary pane. Previously this was
    /// created ad-hoc inside `paneContent(for: .summary)`, which meant
    /// every parent re-render (e.g. the 2s auto-save tick) installed a
    /// fresh VM with an empty severityFilter — so filter-chip taps
    /// looked like they did nothing. Hoisting to a `@StateObject`
    /// keeps the filter state alive across re-renders.
    @StateObject private var summaryVM = InspectionViewModel(version: .empty)
    @StateObject private var weatherService = WeatherService()
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Auto-save debounce task. Cancelled + recreated on every `draft`
    /// change so rapid edits coalesce into one write ~2s after the
    /// user stops typing.
    ///
    /// V1 only saved on `.onDisappear` → all in-flight work lost on
    /// crash/force-quit/log-out. The first auto-save fix published
    /// `metadataList` on every keystroke, which crashed iOS 26's
    /// UICollectionView list differ (seen 2026-04-19). This version
    /// writes just the version JSON to disk without publishing any
    /// `@Published` changes, avoiding SwiftUI-wide re-renders mid-edit.
    // Retained only so the teardown hooks (onDisappear / willResignActive)
    // can cancel any stray task; per-edit auto-save no longer debounces
    // (writes are immediate — see `.onChange(of: draft)`).
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var localLastSavedAt: Date?
    /// Guards one-time seeding of `draft` from the immutable `version` prop.
    /// SwiftUI fires `onAppear` AGAIN every time a full-screen picker
    /// (cover photo / video) dismisses; without this, re-seeding `draft =
    /// version` would reset the draft to the original (pre-media) version
    /// and clobber the media the user just added — the B-0059 data-loss bug.
    @State private var didSeedDraft = false
    /// Snapshot of `draft` as seeded / as last flushed through `updated(_:)`.
    /// Teardown persists ONLY when `draft` differs from it: an untouched open
    /// copy is stale by definition once a remote apply lands while this view
    /// is on screen, and unconditionally re-saving it re-stamped the LWW clock
    /// and echo-pushed the stale copy back over the remote edit (B-0122).
    @State private var lastPersistedDraft: InspectionVersion?

    // Timer state
    //
    // Previously used a Timer.scheduledTimer + @State string to drive the
    // "Timer: HH:MM:SS" label. That invalidated InspectionView's body
    // every second and caused the ellipsis.circle toolbar icon to blink.
    // Now the toolbar menu renders the timer via TimelineView, so all we
    // need here is the session-start marker; display is computed on demand
    // by `formattedTimer(at:)`.
    @State private var timerSessionStart: Date?

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
            // Floating save-state indicator at bottom-center. Visible
            // on every inspection pane (Overview, Section items,
            // Summary, Finalize, Invoice) so the inspector always
            // knows whether their work is safely on disk. Moved out
            // of the toolbar after testers asked for it globally
            // rather than just on the title bar.
            VStack {
                Spacer()
                saveStatusLabel
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(draft.inspection.clientName.isEmpty ? "Inspection \(draft.versionNumber)" : draft.inspection.clientName)
        .toolbar {
            // Preview Report surfaced as its own toolbar button so inspectors
            // don't have to dig into the three-dot menu to see a quick
            // preview of what the client will get. Beta feedback pass
            // 2026-04-22: "surface Preview Report."
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showReportPreview = true
                } label: {
                    Label("Preview", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("Preview report")
                .accessibilityHint("Opens a full-screen preview of the current inspection report")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    // Self-updating timer display. A TimelineView ticks the
                    // label at 1Hz so the elapsed time keeps counting while the
                    // menu is open. It re-renders ONLY this label's subtree, not
                    // InspectionView's body, so the ellipsis.circle toolbar icon
                    // does not blink (the old Timer.scheduledTimer + @State
                    // approach invalidated the whole body and did blink).
                    //
                    // Do NOT collapse this back to a static
                    // `formattedTimer(at: Date())` snapshot: a Menu's content is
                    // built only when the parent body renders — not when the
                    // menu is reopened — so the captured Date() froze and the
                    // timer appeared to stop counting (regression in f42a831e).
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Label("Timer: \(formattedTimer(at: context.date))",
                              systemImage: "timer")
                            .disabled(true)
                    }
                    // Weather menu items are gated behind
                    // AppCapabilities.weatherLoggingEnabled (currently enabled).
                    // The underlying reason (location denied, no fix, Open-Meteo
                    // request failure) is surfaced below and logged via
                    // os_log (category "Weather") so on-device failures are
                    // diagnosable rather than silently swallowed.
                    if AppCapabilities.weatherLoggingEnabled {
                        if let w = draft.inspection.weather {
                            Label("\(w.temperatureString) \(w.conditions)", systemImage: "cloud.sun")
                                .disabled(true)
                        } else if weatherService.isFetching {
                            Label("Fetching weather…", systemImage: "cloud")
                                .disabled(true)
                        } else {
                            // Surface the underlying reason (location denied, simulator
                            // with no set location, network/Open-Meteo failure, etc.)
                            // so the user can fix whichever is the real problem.
                            Label(weatherService.errorMessage ?? "Weather unavailable",
                                  systemImage: "icloud.slash")
                                .disabled(true)
                            Button {
                                weatherService.retry { data in
                                    if let data, draft.isEditable { draft.inspection.weather = data }
                                }
                            } label: {
                                Label("Retry weather", systemImage: "arrow.clockwise")
                            }
                        }
                        Divider()
                    }
                    if store.isSaving {
                        Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                            .disabled(true)
                    } else if let t = store.lastSavedAt {
                        Label("Last saved at \(t, style: .time)", systemImage: "clock")
                            .disabled(true)
                    }
                    Divider()
                    Button("Save") { store.saveNow() }
                    Button("Previous Section") { selectPreviousSection() }
                    Button("Next Section") { selectNextSection() }
                    Button("Finalize") { selectedPane = .finalize }
                    Button("Preview Report") { showReportPreview = true }
                    if draft.locked {
                        Button("Invoice & Send") { selectedPane = .invoice }
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .fullScreenCover(isPresented: $showReportPreview) {
            // Watermark the preview for free users so it mirrors the export
            // they'd produce and can't serve as a clean paywall bypass (B-0074).
            ReportPreviewView(version: draft, watermark: !subscriptions.hasFeatureAccess)
        }
        // Post-finalize Invoice & Send. Presented as a cover (not a pushed pane)
        // so the redirect is reliable on iPhone push-nav AND iPad split-view, and
        // so InvoiceAndSendView's mail/share/export sheets present from a clean
        // modal context. Environment objects are injected explicitly because a
        // cover does not always inherit the presenter's environment across the
        // modal boundary. On dismiss, fire the one-shot ZIP-backup prompt and the
        // App Store review request that we deferred to avoid a present-collision.
        .fullScreenCover(isPresented: $showInvoiceCover, onDismiss: {
            if pendingPostInvoicePrompts {
                pendingPostInvoicePrompts = false
                showExportZIPPrompt = true
                // Ask for an App Store review at the 2nd successful finalization
                // (one-shot, production-only).
                ReviewPromptService.recordFinalizationAndMaybeRequestReview()
            }
        }) {
            NavigationStack {
                InvoiceAndSendView(version: draft)
                    .environmentObject(store)
                    .environmentObject(subscriptions)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showInvoiceCover = false }
                        }
                    }
            }
        }
        .confirmationDialog(
            "Save a backup ZIP to Files?",
            isPresented: $showExportZIPPrompt,
            titleVisibility: .visible
        ) {
            Button("Save ZIP Backup") {
                Task { await runZIPExport() }
            }
            Button("Skip", role: .cancel) { }
        } message: {
            Text("Bundles the report PDF, HTML, photos, and integrity hash into one file in your Files app. Recommended for client delivery and your 5-year record-retention obligation.")
        }
        .sheet(isPresented: $showExportShareSheet) {
            if let url = exportZIPURL {
                ShareSheet(activityItems: [url])
            }
        }
        .alert("Export Failed", isPresented: $showExportZIPError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(exportZIPError ?? "Could not create ZIP backup.")
        }
        .overlay {
            if isExportingZIP {
                Color.black.opacity(0.4).ignoresSafeArea()
                ProgressView("Bundling ZIP…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear {
            // Seed the editable draft from the immutable `version` ONLY ONCE.
            // A full-screen picker (cover photo / video) re-fires onAppear on
            // dismiss; re-seeding here would overwrite the just-added media
            // with the original version (B-0059). Edits live in `draft`.
            if !didSeedDraft {
                didSeedDraft = true
                draft = version
                lastPersistedDraft = version
                // Seed the long-lived Summary VM with the inspection data
                // so the first visit to Summary already has the right
                // sections/items even if no edit has happened yet.
                summaryVM.version = version
                if draft.inspection.sections.isEmpty { selectedPane = .overview }
            }
            // Seed the save indicator from the version file's on-disk
            // modification time so the inspector sees a real "Saved
            // HH:MM" the moment they open an inspection, not a blank
            // indicator until their first edit.
            if localLastSavedAt == nil {
                let fileURL = FilePaths.currentVersionFile(jobId: version.id)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let modified = attrs[.modificationDate] as? Date {
                    localLastSavedAt = modified
                }
            }
            // Start timer
            startTimer()
            // Fetch weather if not already captured. The fetch path is
            // instrumented (see WeatherService) so the on-device failure can
            // be diagnosed from Console.app / the diagnostics log.
            // Only fetch/seed weather on an EDITABLE draft. A finalized version is
            // immutable; its in-memory copy must stay byte-identical to its sealed
            // snapshot or the per-render integrity check (H1) false-positives a valid
            // report. Mirrors the startTimer() draft.isEditable guard.
            if AppCapabilities.weatherLoggingEnabled, draft.isEditable, draft.inspection.weather == nil {
                weatherService.fetchCurrentWeather { data in
                    if let data {
                        draft.inspection.weather = data
                    }
                }
            }
        }
        .onDisappear {
            pauseTimer()
            // Full flush on view teardown: write version file AND
            // publish the metadata list update so Dashboard/Calendar
            // pick up the latest client name, date, etc.
            autoSaveTask?.cancel()
            autoSaveTask = nil
            // Flush gated on a REAL content change (B-0122 round 3);
            // see flushDraftOnTeardown.
            flushDraftOnTeardown()
            store.saveNow()
        }
        // ---- PRIMARY AUTO-SAVE PATH ----
        // Fires on every mutation of `draft` — writes the version
        // file to disk directly WITHOUT touching `@Published`
        // metadataList. That avoids cascade re-renders of any view
        // still alive behind the nav stack (Dashboard List,
        // Calendar grid) which would otherwise race UIKit batch
        // updates and crash on iOS 26.
        //
        // The metadata index + @Published mutation still happens on
        // teardown (onDisappear / willResignActive / Log Out), so
        // Dashboard always shows fresh info when the user returns.
        .onChange(of: draft) { _, newDraft in
            // Keep the Summary VM's `version` in lockstep with the
            // draft so Summary always reflects the live edits. Filter
            // state on the VM is preserved because we only mutate
            // `.version`, not the whole object.
            summaryVM.version = newDraft
            // Durable auto-save (B-0059): persist the version JSON to disk
            // IMMEDIATELY on every edit — no debounce. Every in-inspection
            // mutation (media/cover, item text+photos, signatures, scheduling,
            // reminders/todos, weather, timer) flows into `draft`, so this one
            // hook covers them all. The version JSON holds only text + media
            // file *references* (never media bytes), so it is small and cheap;
            // writeVersionFileOnlyForAutoSave dispatches the encode+write off
            // the main thread on the serial ioQueue, so writing per-edit never
            // hitches the UI. Previously this waited 2s and was CANCELLED on
            // exit (autoSaveTask cancel in onDisappear), so a discrete action
            // (add cover/video) followed by a quick back-swipe or a crash
            // dropped the write before it ever reached disk — the reported
            // data-loss bug. Writing now closes that window for fast-exit,
            // crash, force-quit, and OOM alike. Still FILE-ONLY (no
            // metadataList publish) to preserve the iOS 26 UICollectionView
            // fix; the index/dashboard publish stays on teardown.
            autoSaveTask?.cancel()
            autoSaveTask = nil
            store.writeVersionFileOnlyForAutoSave(newDraft)
            localLastSavedAt = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            pauseTimer()
            // App is about to background or be killed. Full flush
            // including metadata publish — the user is leaving, so
            // the UICollectionView diff risk is zero.
            autoSaveTask?.cancel()
            autoSaveTask = nil
            // Flush gated on a REAL content change (B-0122 round 3);
            // see flushDraftOnTeardown.
            flushDraftOnTeardown()
            store.saveNow()
            localLastSavedAt = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            startTimer()
        }
    }

    /// Compact indicator shown in the navigation toolbar so inspectors
    /// always know whether their work is on disk. Two states:
    ///   • "Saved HH:MM" (green) once the last save landed
    ///   • Empty until first save of this session
    ///
    /// Edits write synchronously (no debounce), so there is no pending
    /// "Unsaved" state to show. The previous amber branch keyed off
    /// `autoSaveTask != nil`, but that task is never assigned a running task
    /// (only cancelled), so it could never render — removed as dead UI.
    ///
    /// Uses local `@State` timestamp (not `store.lastSavedAt`) so this
    /// indicator updating does not trigger SwiftUI-wide re-renders of
    /// every view observing the store — see the UICollectionView
    /// crash note on the auto-save path.
    @ViewBuilder
    private var saveStatusLabel: some View {
        if let t = localLastSavedAt {
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

    // MARK: - Teardown flush (B-0122 round 3)

    /// Authoritative flush shared by `onDisappear` and `willResignActive`.
    ///
    /// The build-38 dirty check (`draft != lastPersistedDraft`) alone could not
    /// stop the phantom-edit echo: both teardown paths call `pauseTimer()` FIRST,
    /// which folds the session into `timerElapsedSeconds`, so the check passed on
    /// EVERY open→close of an editable draft — even with zero user edits. The
    /// unconditional `updated(draft)` then re-stamped the LWW clock
    /// (`InspectionStore.update` → fresh `updatedAt`) and pushed, so merely
    /// viewing an inspection claimed authorship: on receivers holding a stale
    /// copy, closing it echoed that stale content over the zone with a NEWER
    /// clock, overwriting the real editor's work ("whoever closes last wins").
    /// The weather auto-fetch on open was a second phantom-edit source.
    ///
    /// Rule: only a REAL content change (anything `syncContentEquals` compares)
    /// re-stamps + publishes + pushes. Timer/weather-only diffs persist through
    /// the FILE-ONLY autosave path — locally durable (reopening resumes the
    /// timer; the report keeps the captured weather), but with NO `updatedAt`
    /// stamp, NO metadata publish, and NO push: this device never claims
    /// authorship of a document it merely displayed.
    private func flushDraftOnTeardown() {
        guard let last = lastPersistedDraft else {
            // No baseline (draft never seeded — shouldn't happen after
            // onAppear). Preserve the pre-round-3 behavior: full flush.
            updated(draft)
            lastPersistedDraft = draft
            return
        }
        if draft.syncContentEquals(last) {
            // Bookkeeping-only close (timer fold / weather seed).
            if draft != last {
                store.writeVersionFileOnlyForAutoSave(draft)
            }
            lastPersistedDraft = draft
        } else {
            // Genuine local edit: the LWW re-stamp is correct and the push is
            // wanted — exactly the pre-round-3 behavior.
            updated(draft)
            // update() stamped a fresh `updatedAt` onto the row + disk, but this
            // open draft still carries the pre-flush stamp. Re-sync it: this
            // handler also runs with the view STILL ALIVE (willResignActive, and
            // onDisappear fired by a full-screen picker/cover presentation), and
            // the store's clock backstop refuses file-only writes whose clock is
            // OLDER than the row's — without the re-sync it would silently
            // refuse every subsequent per-keystroke autosave of this session,
            // regressing B-0059 crash-durability (e.g. a cover photo added right
            // after the picker dismisses).
            if let rowClock = store.metadataList.first(where: { $0.id == draft.id })?.updatedAt {
                draft.updatedAt = rowClock
            }
            lastPersistedDraft = draft
        }
    }

    // MARK: - Timer

    private func startTimer() {
        // A finalized/locked inspection is done — never start or resume the
        // timer. onAppear (reopening the report) and app-foreground both call
        // this; without the guard, reopening a finalized inspection resumed the
        // clock and pauseTimer() then wrote the inflated duration back onto the
        // finalized record (which prints on the report).
        guard draft.isEditable else { return }
        if draft.inspection.timerStartDate == nil {
            draft.inspection.timerStartDate = Date()
        }
        timerSessionStart = Date()
        // No more scheduledTimer driving @State — the TimelineView in
        // the toolbar menu now ticks itself at 1Hz without triggering
        // body re-renders. We just record the session-start marker here
        // and let `formattedTimer(at:)` compute the display each tick.
    }

    private func pauseTimer() {
        if let sessionStart = timerSessionStart {
            draft.inspection.timerElapsedSeconds += Date().timeIntervalSince(sessionStart)
            timerSessionStart = nil
        }
    }

    /// Computes the timer display at a given render date. Called by the
    /// TimelineView in the toolbar menu so this function owns no state.
    private func formattedTimer(at date: Date) -> String {
        var total = draft.inspection.timerElapsedSeconds
        if let sessionStart = timerSessionStart {
            total += date.timeIntervalSince(sessionStart)
        }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let seconds = Int(total) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    @MainActor
    private func runZIPExport() async {
        guard !isExportingZIP else { return }
        isExportingZIP = true
        defer { isExportingZIP = false }
        do {
            let url = try await InspectionZIPExportService.exportZIP(for: draft, watermark: !subscriptions.hasFeatureAccess)
            exportZIPURL = url
            showExportShareSheet = true
            Haptics.success()
        } catch {
            Diagnostics.logError(context: "Inspection ZIP export failed", error: error)
            exportZIPError = error.localizedDescription
            showExportZIPError = true
        }
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
                .hoverEffect(.lift)
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
                    .accessibilityIdentifier("sectionRow")   // UI-test hook (autosave E2E)
                    .hoverEffect(.lift)
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
                .hoverEffect(.lift)
                NavigationLink {
                    paneContent(for: .finalize)
                } label: {
                    Label("Finalize", systemImage: "lock.shield")
                }
                .accessibilityLabel("Finalize")
                .accessibilityHint("Signatures and lock report")
                .hoverEffect(.lift)
                if draft.locked {
                    NavigationLink {
                        paneContent(for: .invoice)
                    } label: {
                        Label("Invoice & Send", systemImage: "envelope.badge")
                    }
                    .accessibilityLabel("Invoice and send")
                    .accessibilityHint("Customer contact, invoice form, send to client and NexGenSpec")
                    .hoverEffect(.lift)
                }
            }
        }
        .listStyle(.sidebar)
        .listSectionSpacing(.compact)
        .environment(\.defaultMinListRowHeight, 36)
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
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 36)
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
            InspectionOverviewView(version: $draft, onShowSummary: { sev in
                // Mutate the persistent VM directly — no pending
                // handoff state needed now that it's @StateObject.
                summaryVM.severityFilter = [sev]
                selectedPane = .summary
            })
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
            // Use the long-lived Summary VM so filter-chip taps and
            // search text persist across auto-save re-renders.
            SummaryView(viewModel: summaryVM) { sectionID in
                selectedPane = .section(sectionID)
            }
        case .finalize:
            FinalizeView(version: $draft) { _ in
                // Stop the timer and fold the active session into the recorded
                // duration BEFORE locking, so the report shows the real elapsed
                // time and the finalized inspection never keeps counting. v is
                // just the bound draft echoed back, so finalize `draft` (now
                // carrying the folded time), not the pre-pause copy.
                pauseTimer()
                store.finalize(version: draft)
                if let updatedVersion = store.loadFullVersion(id: draft.id) {
                    draft = updatedVersion
                    // Only advance to Invoice & Send if finalize actually locked
                    // the version. If it failed (e.g. integrity snapshot couldn't
                    // be written/verified — store surfaces saveError), the version
                    // is still a draft; don't present the Invoice flow over it.
                    if updatedVersion.state.isFinalized {
                        // Drive the redirect via a fullScreenCover so it works on
                        // iPhone (push nav, no selectedPane) AND iPad. The store
                        // deferred its metadata publish, so THIS view is still on
                        // the stack to present from. Keep selectedPane in sync for
                        // the iPad split view behind the cover.
                        selectedPane = .invoice
                        pendingPostInvoicePrompts = true
                        showInvoiceCover = true
                    }
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
    @State private var showLiDARCapture = false

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
                .buttonStyle(.plain).hoverEffect(.lift)
                .accessibilityIdentifier("itemRow")   // UI-test hook (autosave E2E)
            }
            // Beta-requested (2026-04-22): let the inspector add a custom
            // item on the fly rather than only editing the pre-loaded
            // template list. Keeps the template checklist intact but
            // removes the friction of "my property has X, which isn't
            // in the canned list."
            if draft.state.isEditable {
                Section {
                    Button {
                        addCustomItem()
                    } label: {
                        Label("Add Custom Item", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            // Per-section LiDAR capture: pre-links the scan to this section so the
            // report renders its floor plan inside the section block. Hidden on
            // non-LiDAR devices (LiDARCapability gate, false on Mac).
            if draft.state.isEditable && LiDARCapability.isSupported {
                Section {
                    Button {
                        showLiDARCapture = true
                    } label: {
                        Label("Scan Room (LiDAR)", systemImage: "dot.viewfinder")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .accessibilityLabel("Scan room with LiDAR")
                    .accessibilityHint("Captures a 3D scan and floor plan linked to this section")
                } footer: {
                    Text("The scan's floor plan will appear in this section of the report.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(section.title)
        .sheet(isPresented: $showLiDARCapture) {
            LiDARCaptureView(
                jobId: jobId,
                sectionId: draft.inspection.sections[sectionIndex].id,
                defaultName: draft.inspection.sections[sectionIndex].title
            )
        }
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

    /// Appends a blank inspector-authored item to the current section and
    /// immediately opens the detail sheet so the inspector can fill in
    /// the title + fields. templateItemId is a per-inspection UUID so the
    /// item stays identifiable without colliding with the template library.
    private func addCustomItem() {
        let newItem = InspectionItem(
            templateItemId: "custom-\(UUID().uuidString)",
            title: "New Item",
            status: .notInspected
        )
        var updated = draft
        updated.inspection.sections[sectionIndex].items.append(newItem)
        draft = updated
        let newIndex = updated.inspection.sections[sectionIndex].items.count - 1
        // Slight delay so the List commits the insertion before the sheet
        // tries to bind into the new index.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            selectedRef = SectionItemRef(sectionIndex: sectionIndex, itemIndex: newIndex)
        }
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
                // Neutral "total items" badge — uses the brand blue so
                // it reads as a count, not a severity signal. The per-
                // severity red/orange/yellow/blue chips still appear on
                // each individual item inside the section.
                Text("\(section.safetyCount + section.majorCount + section.marginalCount + section.minorCount)")
                    .font(.caption2)
                    .padding(4)
                    .background(AppColor.brandBlue.opacity(0.2))
                    .foregroundStyle(AppColor.brandBlue)
                    .clipShape(Circle())
            }
        }
        .padding(.vertical, 2)
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
                // A severity capsule alone reads as "this will be in the
                // report" — but the report body gates on
                // isDefect && includeInReport. When this item fails those
                // gates, say so right next to the capsule instead of letting
                // the report silently drop it.
                if !item.isDefect || !item.includeInReport {
                    Text("Not in report")
                        .font(.caption2)
                        .padding(4)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }
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
