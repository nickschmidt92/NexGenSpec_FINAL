//
//  DashboardView.swift
//  NexGenSpec
//
//  Re-written 2026-02-17
//

import SwiftUI

/// Landing screen – lists all inspection versions and lets the user create a new one.
struct DashboardView: View {

    // MARK: - Dependencies
    @EnvironmentObject private var store: InspectionStore
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    // MARK: - Local state
    @State private var showNewInspectionSheet = false
    @State private var showPaywall = false
    @State private var newClientName       = ""
    @State private var newClientEmail     = ""
    @State private var newClientPhone     = ""
    @State private var newPropertyAddress = ""
    @State private var newInspectorName   = ""
    @State private var newInspectionDate: Date = Self.defaultInspectionDate()
    @State private var versionToDeleteID: UUID?
    @State private var showTemplateError = false
    @StateObject private var locationService = LocationService()
    @State private var showTemplatePicker = false
    @State private var selectedTemplateId: String?
    @EnvironmentObject private var router: TabRouter

    // MARK: - Derived state
    //
    // Hoisted out of the List body so the UserDefaults reads behind
    // `isArchived` and `badge` happen ONCE per body render rather than
    // N+1 times (once per row + once for the section header count).
    // Each `metadata.badge` does up to 2 UserDefaults reads, and every
    // `store.objectWillChange.send()` rebuilds the whole dashboard, so
    // this materially cuts the cost of marking an inspection paid /
    // invoiced / finalized.
    private var visibleList: [VersionMetadata] {
        store.metadataList.filter { !$0.isArchived }
    }
    private var badgeMap: [UUID: InspectionBadge] {
        Dictionary(uniqueKeysWithValues: store.metadataList.map { ($0.id, $0.badge) })
    }

    // MARK: - View
    var body: some View {
        AppScreenBackground {
                List {
                    // Offline banner
                    if !networkMonitor.isConnected {
                        Section {
                            HStack(spacing: Spacing.sm) {
                                Image(systemName: "wifi.slash")
                                    .foregroundStyle(.white)
                                Text("You're offline — data saved locally")
                                    .font(AppFont.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, Spacing.sm)
                            .padding(.horizontal, Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.orange)
                            )
                        }
                        .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.md, bottom: Spacing.xs, trailing: Spacing.md))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Section {
                        DashboardHero(
                            username: authManager.currentUsername,
                            totalCount: store.metadataList.count,
                            draftCount: draftCount,
                            finalCount: finalCount
                        )
                    }
                    .listRowInsets(EdgeInsets(top: Spacing.md, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section {
                        DashboardActionDeck(
                            newInspectionAction: prepareForNewInspection,
                            calendarAction: { router.show(.calendar) }
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                    Section {
                        if visibleList.isEmpty {
                            EmptyDashboardState {
                                prepareForNewInspection()
                            }
                            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.md, bottom: Spacing.md, trailing: Spacing.md))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }

                        ForEach(visibleList) { meta in
                            NavigationLink {
                                InspectionRootView(versionID: meta.id)
                                    .environmentObject(store)
                            } label: {
                                VersionRow(metadata: meta, badge: badgeMap[meta.id] ?? meta.badge)
                            }
                            .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.md, bottom: Spacing.xs, trailing: Spacing.md))
                            .listRowBackground(Color.clear)
                            .hoverEffect(.lift)
                            // Swipe-trailing actions:
                            // • Archive — always available (works for finalized
                            //   records too, which can't be deleted for legal
                            //   retention but should still be hideable).
                            // • Delete — only on editable drafts. Finalized
                            //   records stay on disk per the 5-year retention
                            //   policy.
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button {
                                    InspectionFlags.setArchived(true, inspectionId: meta.inspectionId.uuidString)
                                    store.objectWillChange.send()
                                } label: {
                                    Label("Archive", systemImage: "archivebox.fill")
                                }
                                .tint(.gray)

                                if meta.isEditable {
                                    Button(role: .destructive) {
                                        versionToDeleteID = meta.id
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                            .contextMenu {
                                Button {
                                    InspectionFlags.setArchived(true, inspectionId: meta.inspectionId.uuidString)
                                    store.objectWillChange.send()
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                if meta.isEditable {
                                    Button("Delete inspection", role: .destructive) {
                                        versionToDeleteID = meta.id
                                    }
                                } else {
                                    Button {} label: {
                                        Label("Finalized — kept for 5-year retention", systemImage: "lock.fill")
                                    }
                                    .disabled(true)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Inspections")
                            Spacer()
                            Text("\(visibleList.count) total")
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .listSectionSpacing(Spacing.sm)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .refreshable {
                    store.reloadFromDisk()
                }
                // Reconcile any finalize that happened while an inspection was
                // pushed: finalize defers its metadata publish to avoid popping
                // the pushed view (the finalize→Invoice bug), so the row badge
                // flips to Finalized here, once the user is back on the list.
                .onAppear {
                    store.flushPendingMetadata()
                }
                .navigationTitle("Workspace")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            prepareForNewInspection()
                        } label: {
                            Label("New Inspection", systemImage: "plus")
                        }
                        .accessibilityLabel("New Inspection")
                        .accessibilityHint("Opens a form to create a new inspection")
                    }
                    // Log Out action in the Dashboard toolbar — testers
                    // said the button in Settings wasn't easy enough to
                    // find. Account menu keeps it one tap away from
                    // anywhere the inspector lives most of the time.
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
                            if let user = authManager.currentUsername {
                                Text(user).disabled(true)
                                Divider()
                            }
                            Button(role: .destructive) {
                                // Flush any pending save before tearing
                                // down the session (same guard as in
                                // Settings > Log Out).
                                store.saveNow()
                                authManager.logout()
                            } label: {
                                Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } label: {
                            Image(systemName: "person.crop.circle")
                                .accessibilityLabel("Account menu")
                        }
                    }
                }
                .sheet(isPresented: $showNewInspectionSheet) { newInspectionSheet }
                .sheet(isPresented: $showPaywall) { PaywallView() }
                .sheet(isPresented: $showTemplatePicker) {
                    NavigationStack {
                        TemplatePickerSheet(selectedTemplateId: $selectedTemplateId) {
                            showTemplatePicker = false
                            showNewInspectionSheet = true
                        } onCancel: {
                            showTemplatePicker = false
                        }
                    }
                }
                .alert("Save failed", isPresented: Binding(
                    get: { store.saveError != nil },
                    set: { if !$0 { store.clearSaveError() } }
                )) {
                    Button("Retry") { store.clearSaveError(); store.saveNow() }
                    Button("OK") { store.clearSaveError() }
                } message: {
                    if let err = store.saveError {
                        Text(err)
                    }
                }
                .alert("Load failed", isPresented: Binding(
                    get: { store.loadError != nil },
                    set: { if !$0 { store.clearLoadError() } }
                )) {
                    Button("Retry") { store.clearLoadError(); store.reloadFromDisk() }
                    Button("OK") { store.clearLoadError() }
                } message: {
                    if let err = store.loadError {
                        Text(err)
                    }
                }
                .confirmationDialog("Delete inspection?", isPresented: Binding(
                    get: { versionToDeleteID != nil },
                    set: { if !$0 { versionToDeleteID = nil } }
                ), titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        if let id = versionToDeleteID {
                            _ = store.deleteVersion(id: id)
                            versionToDeleteID = nil
                        }
                    }
                    Button("Cancel", role: .cancel) { versionToDeleteID = nil }
                } message: {
                    if let id = versionToDeleteID, let meta = store.metadataList.first(where: { $0.id == id }) {
                        Text("“\(meta.clientName)” will be permanently removed. This cannot be undone.")
                    }
                }
                .alert("Cannot create inspection", isPresented: $showTemplateError) {
                    Button("OK") { showTemplateError = false }
                } message: {
                    Text("The inspection template could not be loaded. Please restart the app or reinstall.")
                }
        }
    }

    private var draftCount: Int {
        store.metadataList.filter { $0.status == .draft }.count
    }

    private var finalCount: Int {
        store.metadataList.filter { $0.status == .final }.count
    }

    private func prepareForNewInspection() {
        guard subscriptions.canCreateInspection else {
            showPaywall = true
            return
        }
        newClientName = ""
        newClientEmail = ""
        newClientPhone = ""
        newPropertyAddress = ""
        newInspectorName = InspectorProfile.shared.inspectorName
        newInspectionDate = Self.defaultInspectionDate()
        inspectorConfirmed = false
        selectedTemplateId = nil

        let customTemplates = CustomTemplateStore.shared.templates
        if customTemplates.isEmpty {
            // Only built-in template, skip picker
            showNewInspectionSheet = true
        } else {
            showTemplatePicker = true
        }
    }

    // MARK: - Sheet
    @State private var inspectorConfirmed = false

    @ViewBuilder private var newInspectionSheet: some View {
        NavigationStack {
            Form {
                Section("Client") {
                    TextField("Client Name",        text: $newClientName)
                    TextField("Email",              text: $newClientEmail)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                    TextField("Phone",              text: $newClientPhone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                        .phoneFormatted($newClientPhone)
                }
                Section("Property & Inspector") {
                    TextField("Property Address",   text: $newPropertyAddress)
                    // Location auto-fill needs GPS — hidden on Mac (Designed-for-iPad
                    // has no GPS and would return a wrong coarse Wi-Fi/IP fix). Mac
                    // users type the property address directly.
                    if !Platform.isMac {
                        Button {
                            locationService.fetchCurrentAddress { address in
                                if let address {
                                    newPropertyAddress = address
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if locationService.isLocating {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Locating…")
                                } else {
                                    Image(systemName: "location.fill")
                                    Text("Use Current Location")
                                }
                            }
                            .font(.subheadline)
                        }
                        .disabled(locationService.isLocating)
                        .accessibilityLabel("Use current location for property address")
                        if let error = locationService.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    TextField("Inspector Name",     text: $newInspectorName)
                }
                Section("Schedule") {
                    DatePicker(
                        "Start Date & Time",
                        selection: $newInspectionDate,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    // .compact style pops a popover on tap instead of
                    // expanding inline. Inline expansion inside a Form
                    // on iOS 26 triggers UICollectionView batch-update
                    // assertion on "Done" — the crash caught by the
                    // first TestFlight cohort (2026-04-19).
                    .datePickerStyle(.compact)
                }
                Section {
                    Toggle(isOn: $inspectorConfirmed) {
                        Text("I confirm I am a licensed or authorized inspector and responsible for this report.")
                            .font(.subheadline)
                    }
                } footer: {
                    Text("NexGenSpec is reporting software only. You are responsible for licensing, insurance, compliance, and report content.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("New Inspection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNewInspectionSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        if store.templateLoadFailed && selectedTemplateId == nil {
                            showNewInspectionSheet = false
                            showTemplateError = true
                        } else {
                            let created = store.createNewInspection(
                                clientName:      newClientName,
                                clientEmail:    newClientEmail,
                                clientPhone:    newClientPhone,
                                propertyAddress: newPropertyAddress,
                                inspectorName:   newInspectorName,
                                inspectorConfirmed: inspectorConfirmed,
                                inspectionDate:  newInspectionDate,
                                customTemplateId: selectedTemplateId
                            )
                            // Only burn a free-trial slot when an inspection was
                            // actually created — a silent failure (template load,
                            // locked device) must not advance the counter (audit finding).
                            if created {
                                subscriptions.recordInspectionCreated()
                            }
                            showNewInspectionSheet = false
                        }
                    }
                    .disabled(newClientName.isEmpty ||
                              newPropertyAddress.isEmpty ||
                              newInspectorName.isEmpty ||
                              !inspectorConfirmed)
                }
            }
        }
    }

    /// Default start time for a freshly-opened new-inspection sheet:
    /// today at the next top-of-hour, clamped to 9am if earlier.
    /// Using a real time (instead of local midnight) means the
    /// scheduled inspection shows in the calendar grid as a scheduled
    /// event rather than an "all-day" placeholder.
    private static func defaultInspectionDate() -> Date {
        let now = Date()
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        comps.hour = max(9, (comps.hour ?? 9) + 1)
        comps.minute = 0
        comps.second = 0
        return cal.date(from: comps) ?? now
    }
}

// MARK: - Single row helper (uses metadata for list; full version loaded on open)
private struct VersionRow: View {
    let metadata: VersionMetadata
    /// Pre-computed by the parent so the row doesn't repeat UserDefaults
    /// reads on every diff. See DashboardView.badgeMap.
    let badge: InspectionBadge

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            VersionRowLeading(metadata: metadata)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(metadata.clientName)
                            .font(AppFont.headline)
                            .foregroundStyle(.primary)

                        Text(metadata.propertyAddress)
                            .font(AppFont.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: Spacing.sm) {
                    InspectionInfoPill(
                        title: dateFormatter.string(from: metadata.inspectionDate),
                        systemImage: "calendar"
                    )

                    InspectionInfoPill(
                        title: badge.label,
                        systemImage: badge.systemImage,
                        foregroundStyle: badge.color,
                        background: badge.color.opacity(0.14)
                    )
                }
            }
        }
        .padding(Spacing.md)
        .background {
            if #available(iOS 26.0, *) {
                Color.clear
            } else {
                AppColor.softPanelGradient
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .adaptiveGlass(cornerRadius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metadata.clientName), \(metadata.propertyAddress), \(metadata.status.rawValue)")
        .accessibilityHint("Opens this inspection")
    }
}

// MARK: - Cover thumbnail (with in-memory cache)

/// Process-wide cache for decoded cover thumbnails. Keyed by the
/// inspection's `inspectionId` (UUID string). Invalidated entries are
/// removed when `Notification.Name.coverPhotoDidUpdate` fires.
private final class CoverThumbnailCache {
    static let shared = CoverThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 64
        // Coalesce to the main actor — the notification carries a `jobId` UUID
        // in userInfo and can be posted from any context.
        NotificationCenter.default.addObserver(
            forName: .coverPhotoDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["jobId"] as? UUID else { return }
            self?.invalidate(jobId: id)
        }
    }

    func image(for jobId: UUID) -> UIImage? {
        cache.object(forKey: jobId.uuidString as NSString)
    }

    func store(_ image: UIImage, for jobId: UUID) {
        cache.setObject(image, forKey: jobId.uuidString as NSString)
    }

    func invalidate(jobId: UUID) {
        cache.removeObject(forKey: jobId.uuidString as NSString)
    }
}

/// Leading visual for a dashboard row: either the inspection's cover
/// photo thumbnail (when present) or the status badge fallback.
private struct VersionRowLeading: View {
    let metadata: VersionMetadata

    var body: some View {
        if let fileName = metadata.coverPhotoFileName {
            CoverThumbnailView(
                jobId: metadata.inspectionId,
                fileName: fileName,
                badgeColor: metadata.status.badgeColor
            )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(metadata.status.badgeColor.opacity(0.14))
                    .frame(width: 50, height: 50)

                Image(systemName: metadata.status == .draft ? "square.and.pencil" : "checkmark.seal.fill")
                    .foregroundStyle(metadata.status.badgeColor)
            }
        }
    }
}

/// Async-loading thumbnail for a single inspection's cover photo.
/// Reads from disk on background queue, caches in
/// `CoverThumbnailCache.shared`, and listens for invalidation
/// notifications so the picker → row update is immediate.
private struct CoverThumbnailView: View {
    let jobId: UUID
    let fileName: String
    let badgeColor: Color

    @State private var image: UIImage?
    @State private var tick: Int = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(badgeColor.opacity(0.14))
                .frame(width: 50, height: 50)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                Image(systemName: "house.fill")
                    .foregroundStyle(badgeColor)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(badgeColor.opacity(0.25), lineWidth: 1)
        )
        .task(id: tick) { await loadIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .coverPhotoDidUpdate)) { note in
            guard let updatedId = note.userInfo?["jobId"] as? UUID,
                  updatedId == jobId else { return }
            // Invalidate ourselves so we don't race the global cache
            // observer's ordering relative to ours.
            CoverThumbnailCache.shared.invalidate(jobId: jobId)
            image = nil
            tick &+= 1
        }
    }

    private func loadIfNeeded() async {
        if let cached = CoverThumbnailCache.shared.image(for: jobId) {
            await MainActor.run { self.image = cached }
            return
        }
        let url = FilePaths.coverPhotoFile(jobId: jobId, fileName: fileName)
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        if let loaded {
            CoverThumbnailCache.shared.store(loaded, for: jobId)
        }
        await MainActor.run { self.image = loaded }
    }
}

struct InspectionInfoPill: View {
    let title: String
    let systemImage: String
    var foregroundStyle: Color = .secondary
    var background: Color = AppColor.surface

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(AppFont.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(background)
            .foregroundStyle(foregroundStyle)
            .clipShape(Capsule())
    }
}

private struct DashboardHero: View {
    let username: String?
    let totalCount: Int
    let draftCount: Int
    let finalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                BrandMark(size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("NexGenSpec")
                        .font(AppFont.headline)
                        .foregroundStyle(.primary)

                    Text(username ?? "Inspector")
                        .font(AppFont.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()
            }

            HStack(spacing: Spacing.sm) {
                DashboardMetric(title: "Total", value: "\(totalCount)", systemImage: "tray.full.fill")
                DashboardMetric(title: "Drafts", value: "\(draftCount)", systemImage: "square.and.pencil")
                DashboardMetric(title: "Final", value: "\(finalCount)", systemImage: "checkmark.seal.fill")
            }
        }
        .inspectionCard()
    }
}

private struct DashboardActionDeck: View {
    let newInspectionAction: () -> Void
    let calendarAction: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            DashboardActionButton(
                title: "Start New",
                subtitle: "Open a fresh inspection shell",
                systemImage: "plus.circle.fill",
                action: newInspectionAction
            )

            DashboardActionButton(
                title: "Open Calendar",
                subtitle: "Schedule inspections and check conflicts",
                systemImage: "calendar",
                action: calendarAction
            )
        }
    }
}

private struct DashboardActionButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(AppColor.accent)

                Text(title)
                    .font(AppFont.headline)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(AppFont.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
            .padding(Spacing.md)
            .background {
                if #available(iOS 26.0, *) {
                    Color.clear
                } else {
                    AppColor.softPanelGradient
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppColor.border, lineWidth: 1)
            )
            .adaptiveGlass(cornerRadius: 22)
        }
        .buttonStyle(.plain).hoverEffect(.lift)
    }
}

private struct DashboardMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Label(title, systemImage: systemImage)
                .font(AppFont.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(value)
                .font(AppFont.title2)
                .foregroundStyle(AppColor.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.md)
        .background {
            if #available(iOS 26.0, *) {
                Color.clear
            } else {
                AppColor.surface
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .adaptiveGlass(cornerRadius: 18)
    }
}

private struct EmptyDashboardState: View {
    let createAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .fill(AppColor.accent.opacity(0.12))
                        .frame(width: 52, height: 52)

                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AppColor.accent)
                }

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("No inspections yet")
                        .font(AppFont.title3)
                    Text("Create your first inspection to start capturing photos, notes, and finalized reports.")
                        .font(AppFont.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Create First Inspection", action: createAction)
                .buttonStyle(AppPrimaryButtonStyle())

            HStack(spacing: Spacing.sm) {
                EmptyStatePromise(title: "Capture", systemImage: "camera.aperture")
                EmptyStatePromise(title: "Annotate", systemImage: "highlighter")
                EmptyStatePromise(title: "Export", systemImage: "square.and.arrow.up")
            }
        }
        .inspectionCard()
    }
}

private struct EmptyStatePromise: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(AppFont.caption.weight(.semibold))
            .foregroundStyle(AppColor.accent)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(AppColor.accent.opacity(0.12))
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Template Picker Sheet

private struct TemplatePickerSheet: View {
    @Binding var selectedTemplateId: String?
    let onSelect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        List {
            Section("Choose a Template") {
                // Built-in template
                Button {
                    selectedTemplateId = nil
                    onSelect()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text("Comprehensive Home Inspection")
                                .font(AppFont.headline)
                            Text("Built-in template")
                                .font(AppFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(AppColor.accent)
                    }
                    .padding(.vertical, Spacing.xs)
                }

                // Custom templates
                ForEach(CustomTemplateStore.shared.templates) { template in
                    Button {
                        selectedTemplateId = template.templateId
                        onSelect()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(template.name)
                                    .font(AppFont.headline)
                                Text("\(template.sections.count) sections")
                                    .font(AppFont.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "doc.badge.gearshape")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, Spacing.xs)
                    }
                }
            }
        }
        .navigationTitle("Template")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onCancel() }
            }
        }
    }
}

// Shared date formatter
private let dateFormatter = DateFormatters.mediumDateTime

// MARK: - Preview
#if DEBUG
struct DashboardView_Previews: PreviewProvider {
    static var previews: some View {
        let store = InspectionStore()
        let auth = AuthManager()
        DashboardView()
            .environmentObject(store)
            .environmentObject(auth)
    }
}
#endif
