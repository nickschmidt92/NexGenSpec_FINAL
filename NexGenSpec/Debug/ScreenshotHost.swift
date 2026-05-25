//
//  ScreenshotHost.swift
//  NexGenSpec
//
//  Debug-only launch routing for App Store screenshot capture. Activated by the
//  `-screenshotMode` launch argument; `-screenshotRoute <name>` picks the screen.
//  Seeds DemoModeFixture and presents the target view directly, so screenshots
//  can be captured headlessly via `simctl` with no login and no UI taps.
//
//  This entire file is `#if DEBUG` and is NEVER compiled into a Release /
//  App Store build — same guarantee as DemoModeFixture. It does not touch the
//  real auth path: when -screenshotMode is absent the app launches through
//  RootView exactly as in production.
//
//  Usage:
//    xcrun simctl launch <udid> com.nexgenspec.app \
//        --args -screenshotMode -screenshotRoute dashboard|inspection|pdf|paywall
//

#if DEBUG
import SwiftUI
import UIKit

enum ScreenshotMode {
    static var isActive: Bool { CommandLine.arguments.contains("-screenshotMode") }

    static var route: String {
        guard let i = CommandLine.arguments.firstIndex(of: "-screenshotRoute"),
              i + 1 < CommandLine.arguments.count else { return "dashboard" }
        return CommandLine.arguments[i + 1]
    }
}

struct ScreenshotHost: View {
    @EnvironmentObject private var store: InspectionStore
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @State private var seeded = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            if seeded { routed }
        }
        .task {
            if store.metadataList.isEmpty {
                DemoModeFixture.populate(store: store)
            }
            // Let disk writes + thumbnail generation settle before we render
            // so cover photos and item thumbnails are present in the capture.
            try? await Task.sleep(nanoseconds: 600_000_000)
            seeded = true
        }
    }

    /// First seeded inspection is the "ready to finalize" Chen job (full
    /// sections, photos, and defects) — the richest one for screenshots.
    private var primaryVersionID: UUID? { store.metadataList.first?.id }

    @ViewBuilder private var routed: some View {
        switch ScreenshotMode.route {
        case "paywall":
            PaywallView()
        case "inspection":
            if let id = primaryVersionID {
                InspectionRootView(versionID: id)
            } else {
                Text("No demo inspection seeded")
            }
        case "pdf":
            if let id = primaryVersionID, let version = store.loadFullVersion(id: id) {
                NavigationStack { ReportPreviewView(version: version) }
            } else {
                Text("No demo inspection seeded")
            }
        case "annotation":
            if let image = firstDefectPhoto() {
                NavigationStack {
                    PencilKitPhotoAnnotationView(
                        baseImage: image,
                        initialOverlay: nil,
                        onSave: { _ in }
                    )
                }
            } else {
                Text("No demo photo available")
            }
        default: // "dashboard"
            MainTabView()
        }
    }

    /// Loads a UIImage from the first seeded inspection photo on disk, for the
    /// photo-annotation screen. Walks sections so it finds a defect photo even
    /// if the first item has none.
    private func firstDefectPhoto() -> UIImage? {
        for meta in store.metadataList {
            guard let version = store.loadFullVersion(id: meta.id) else { continue }
            let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
            for section in version.inspection.sections {
                for item in section.items where !item.photos.isEmpty {
                    let url = FilePaths.photosFolder(jobId: jobId)
                        .appendingPathComponent(item.photos[0].fileName)
                    if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                        return img
                    }
                }
            }
        }
        return nil
    }
}
#endif
