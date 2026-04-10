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
    @StateObject private var voiceManager = VoiceCommandManager()

    private var jobId: UUID {
        UUID(uuidString: draft.inspection.inspectionId) ?? version.id
    }

    var body: some View {
        ZStack {
        NavigationSplitView {
            sectionSidebar
        } detail: {
            paneDetailContent
        }

        VoiceCommandOverlay(voiceManager: voiceManager)
        }
        .navigationTitle(draft.inspection.clientName.isEmpty ? "Inspection \(draft.versionNumber)" : draft.inspection.clientName)
        .toolbar {
            ToolbarItem(placement: .status) {
                if store.isSaving {
                    Text("Saving…").font(.caption).foregroundColor(.secondary)
                } else if let t = store.lastSavedAt {
                    Text("Saved \(t, style: .time)").font(.caption).foregroundColor(.secondary)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Save") { store.saveNow() }
                    .keyboardShortcut("s", modifiers: .command)
                    .accessibilityLabel("Save now")
                Button("Previous section") { selectPreviousSection() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .accessibilityLabel("Previous section")
                Button("Next section") { selectNextSection() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .accessibilityLabel("Next section")
                Button("Finalize") { selectedPane = .finalize }
                    .keyboardShortcut("f", modifiers: .command)
                    .accessibilityLabel("Go to Finalize")
                if draft.locked {
                    Button("Invoice & Send") { selectedPane = .invoice }
                        .keyboardShortcut("i", modifiers: .command)
                        .accessibilityLabel("Invoice and send")
                }
                Button("Keyboard Shortcuts") { showShortcutsHelp = true }
                    .keyboardShortcut("?", modifiers: .command)
                    .accessibilityLabel("Show keyboard shortcuts")
            }
        }
        .sheet(isPresented: $showShortcutsHelp) {
            ShortcutsHelpView()
        }
        .onAppear {
            draft = version
            if draft.inspection.sections.isEmpty { selectedPane = .overview }
            voiceManager.onCommand = { action in
                handleVoiceCommand(action)
            }
        }
        .onDisappear { updated(draft) }
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

    private var sectionSidebar: some View {
        List {
            Section("Inspection") {
                Button { selectedPane = .overview } label: {
                    Label("Overview", systemImage: "doc.text")
                }
                .accessibilityLabel("Overview")
                .accessibilityHint("Cover page, export report, capture room")
                .listRowBackground(selectedPane == .overview ? AppColor.accent.opacity(0.10) : Color.clear)
            }
            Section("Sections") {
                ForEach(draft.inspection.sections) { section in
                    Button { selectedPane = .section(section.id) } label: {
                        SectionRowView(section: section)
                    }
                    .accessibilityLabel(section.title)
                    .accessibilityHint("\(section.items.count) items")
                    .listRowBackground(selectedPane == .section(section.id) ? AppColor.accent.opacity(0.10) : Color.clear)
                }
            }
            Section("Actions") {
                Button { selectedPane = .summary } label: {
                    Label("Summary", systemImage: "list.bullet.rectangle")
                }
                .accessibilityLabel("Summary")
                .accessibilityHint("Findings by severity")
                .listRowBackground(selectedPane == .summary ? AppColor.accent.opacity(0.10) : Color.clear)
                Button { selectedPane = .finalize } label: {
                    Label("Finalize", systemImage: "lock.shield")
                }
                .accessibilityLabel("Finalize")
                .accessibilityHint("Signatures and lock report")
                .listRowBackground(selectedPane == .finalize ? AppColor.accent.opacity(0.10) : Color.clear)
                if draft.locked {
                    Button { selectedPane = .invoice } label: {
                        Label("Invoice & Send", systemImage: "envelope.badge")
                    }
                    .accessibilityLabel("Invoice and send")
                    .accessibilityHint("Customer contact, invoice form, send to client and NexGenSpec")
                    .listRowBackground(selectedPane == .invoice ? AppColor.accent.opacity(0.10) : Color.clear)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Sections")
    }

    @ViewBuilder
    private var paneDetailContent: some View {
        switch selectedPane {
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
                    .foregroundColor(AppColor.warning)
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
                .foregroundColor(.secondary)
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
                    .foregroundColor(item.isDefect ? AppColor.critical : .secondary)
            }
            Spacer()
            if let sev = item.defectSeverity {
                Text(sev.displayName)
                    .font(.caption)
                    .padding(4)
                    .background(sev.badgeColor.opacity(0.2))
                    .foregroundColor(sev.badgeColor)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}
