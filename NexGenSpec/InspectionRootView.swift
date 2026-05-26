//
//  InspectionRootView.swift
//  NexGenSpec
//
//  Re-written 2026-02-17
//

import SwiftUI

/// Displays and edits a single inspection. Loads full version from disk when opened.
struct InspectionRootView: View {

    @EnvironmentObject private var store: InspectionStore
    private let versionID: UUID
    @State private var loadedVersion: InspectionVersion?

    init(versionID: UUID) {
        self.versionID = versionID
    }

    var body: some View {
        Group {
            if let version = loadedVersion {
                InspectionView(version: version) { updated in
                    store.update(version: updated)
                }
            } else if store.metadataList.contains(where: { $0.id == versionID }) {
                ProgressView("Loading…")
            } else {
                if #available(iOS 17.0, *) {
                    ContentUnavailableView(
                        "Version not found",
                        systemImage: "exclamationmark.triangle"
                    )
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Version not found")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // Load off the main thread so opening a large inspection shows the
        // "Loading…" placeholder for a beat instead of freezing the UI while
        // the full version JSON decodes. `.task(id:)` re-runs if the row changes.
        .task(id: versionID) {
            if loadedVersion?.id != versionID {
                loadedVersion = await store.loadFullVersionAsync(id: versionID)
            }
        }
    }
}

#if DEBUG
// MARK: – Preview support -----------------------------------------------------

/// Convenience overlay that just returns its `content`
/// after injecting `store` into the environment.


/// A helper namespace for sample data that compiles on every device.
@MainActor
private enum PreviewSamples {

    /// iPhone layout with two sections and one FINAL version
    static let iphoneSampleStore: InspectionStore = {
        let store = InspectionStore()
        if store.metadataList.isEmpty {
            let id = UUID()
            var dummy = Inspection(clientName: "Preview", propertyAddress: "123 Main", inspectionDate: .now, inspectorName: "Inspector", sections: [], inspectorConfirmed: true)
            let s1 = InspectionSection(id: .init(), title: "Electrical", items: [])
            let s2 = InspectionSection(id: .init(), title: "Plumbing", items: [])
            dummy.sections = [s1, s2]
            let version = InspectionVersion(id: id, versionNumber: 1, status: .final, finalizedAt: Date(), locked: true, inspection: dummy)
            store.insert(version: version)
        }
        guard var first = store.metadataList.first.flatMap({ store.loadFullVersion(id: $0.id) }) else { return store }
        var i = first.inspection
        i.sections = [InspectionSection(id: .init(), title: "Electrical", items: []), InspectionSection(id: .init(), title: "Plumbing", items: [])]
        first.inspection = i
        first.status = .final
        first.locked = true
        store.update(version: first)
        return store
    }()
}

struct InspectionRootView_Previews: PreviewProvider {
    static var previews: some View {
        WithStore { store in
            InspectionRootView(versionID: store.metadataList.first?.id ?? UUID())
        }
    }
}
#endif
