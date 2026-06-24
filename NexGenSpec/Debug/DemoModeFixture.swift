//
//  DemoModeFixture.swift
//  NexGenSpec
//
//  Debug-only screenshot fixture. Seeds two inspections (one draft, one
//  ready-to-finalize) populated with realistic items + photos sourced
//  from marketing/screenshot-assets/. Wired to a button in AppSettingsView
//  that only appears in Debug builds.
//
//  Workflow during a screenshot session:
//  1. Boot Simulator, install Debug build, open Settings, tap "Load Demo
//     Inspection Data".
//  2. Screenshot the dashboard, the draft inspection (overview, item
//     detail w/ live PencilKit annotation), the ready-to-finalize one
//     (finalize the signatures live, then capture invoice/PDF/locked).
//

#if DEBUG
import Foundation
import UIKit

enum DemoModeFixture {
    /// Absolute path to the AI-generated photos on the dev's machine.
    /// This file is `#if DEBUG`, never ships, and only runs in the
    /// Simulator (which has filesystem access to the host).
    private static let assetsPath = "/Users/nicholasschmidt/Developer/NexGenSpec_FINAL/marketing/screenshot-assets"

    @MainActor
    static func populate(store: InspectionStore) {
        createDraftInspection(store: store)
        createReadyToFinalizeInspection(store: store)
    }

    // MARK: - Draft (for live-annotation screenshots)

    @MainActor
    private static func createDraftInspection(store: InspectionStore) {
        store.createNewInspection(
            clientName: "Marcus & Elena Reyes",
            clientEmail: "mreyes@example.com",
            clientPhone: "(720) 555-0142",
            propertyAddress: "9884 Telluride Street, Commerce City, CO 80603",
            inspectorName: "Jordan Reed",
            inspectorConfirmed: true,
            inspectionDate: Date().addingTimeInterval(-3600 * 2)
        )

        guard let metadata = store.metadataList.first,
              var version = store.loadFullVersion(id: metadata.id) else { return }

        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id

        if let coverName = loadPhoto(named: "01-exterior.jpg", jobId: jobId) {
            version.inspection.coverPhotoFileName = coverName
        }
        version.inspection.weather = sampleWeather()

        populateSections(&version, jobId: jobId, mode: .partial)
        store.update(version: version)
    }

    // MARK: - Ready-to-finalize (for invoice / PDF / finalize screenshots)

    @MainActor
    private static func createReadyToFinalizeInspection(store: InspectionStore) {
        store.createNewInspection(
            clientName: "Daniel & Megan Whitaker",
            clientEmail: "dwhitaker@example.com",
            clientPhone: "(303) 555-0188",
            propertyAddress: "10925 Wheeling Street, Commerce City, CO 80603",
            inspectorName: "Jordan Reed",
            inspectorConfirmed: true,
            inspectionDate: Date().addingTimeInterval(-3600 * 26)
        )

        guard let metadata = store.metadataList.first,
              var version = store.loadFullVersion(id: metadata.id) else { return }

        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id

        if let coverName = loadPhoto(named: "11-aerial-drone.jpg", jobId: jobId) {
            version.inspection.coverPhotoFileName = coverName
        }
        version.inspection.weather = sampleWeather()

        populateSections(&version, jobId: jobId, mode: .full)
        version.inspection.signatures = [
            InspectionSignature(name: "Jordan Reed", imageData: Data(), date: Date()),
            InspectionSignature(name: "D. Whitaker", imageData: Data(), date: Date())
        ]
        store.update(version: version)
        store.finalize(version: version)   // screenshot demo: 2 sigs -> real finalize -> client-ready report (no DRAFT)
        // Finalize is intentionally left to the user — they draw the two
        // signatures live so the screenshot of the locked Finalize view
        // shows realistic PKDrawing strokes, not stub data.
    }

    // MARK: - Section populator

    private enum PopulateMode { case partial, full }

    @MainActor
    private static func populateSections(_ version: inout InspectionVersion, jobId: UUID, mode: PopulateMode) {
        // Section title → list of photo filenames (in marketing/screenshot-assets/).
        // Matched on section.title to survive future template additions.
        let photoMap: [String: [String]] = [
            "Roof Structure":  ["06-defect-roof-shingle.jpg"],
            "Exterior":        ["01-exterior.jpg", "14-defect-foundation-crack.jpg"],
            "Foundation":      ["14-defect-foundation-crack.jpg"],
            "Plumbing":        ["08-defect-plumbing-leak.jpg", "03-bathroom.jpg"],
            "Electrical":      ["07-defect-electrical-outlet.jpg", "12-thermal-electrical.jpg"],
            "Heating/Cooling": ["15-hvac-unit.jpg", "10-defect-hvac-filter.jpg", "13-thermal-wall.jpg"],
            "Attic":           ["13-thermal-wall.jpg"],
            "Water Heater":    ["08-defect-plumbing-leak.jpg"],
            "Appliances":      ["02-kitchen.jpg"],
            "Crawl Space":     ["05-defect-ceiling-stain.jpg"]
        ]

        // Defect tagging: (item-index, severity) pairs per section.
        let defectMap: [String: [(itemIndex: Int, severity: Severity)]] = [
            "Roof Structure":  [(0, .marginal)],
            "Exterior":        [(1, .minor)],
            "Foundation":      [(0, .major)],
            "Plumbing":        [(0, .marginal)],
            "Electrical":      [(0, .safety)],
            "Heating/Cooling": [(1, .marginal)]
        ]

        for sIdx in version.inspection.sections.indices {
            let section = version.inspection.sections[sIdx]
            guard !section.items.isEmpty else { continue }

            for iIdx in section.items.indices {
                version.inspection.sections[sIdx].items[iIdx].status = .inspected
                version.inspection.sections[sIdx].items[iIdx].includeInReport = true
            }

            if let defects = defectMap[section.title] {
                for d in defects where d.itemIndex < section.items.count {
                    version.inspection.sections[sIdx].items[d.itemIndex].defectSeverity = d.severity
                    version.inspection.sections[sIdx].items[d.itemIndex].inspectorComments =
                        sampleComment(for: d.severity)
                }
            }

            let photoFiles = photoMap[section.title] ?? []
            let limit = (mode == .partial) ? min(1, photoFiles.count) : photoFiles.count
            for (offset, photoFile) in photoFiles.prefix(limit).enumerated() {
                guard offset < section.items.count else { break }
                if let fileName = loadPhoto(named: photoFile, jobId: jobId) {
                    let photo = InspectionPhoto(
                        fileName: fileName,
                        caption: "",
                        sortOrder: version.inspection.sections[sIdx].items[offset].photos.count
                    )
                    version.inspection.sections[sIdx].items[offset].photos.append(photo)
                }
            }
        }
    }

    // MARK: - Helpers

    private static func sampleComment(for severity: Severity) -> String {
        switch severity {
        case .safety:
            return "Open ground detected on the kitchen GFCI outlet. Recommend evaluation by a licensed electrician before close."
        case .major:
            return "Vertical foundation crack greater than 1/8\" wide. Consult a licensed structural engineer."
        case .marginal:
            return "Visible wear consistent with age. Monitor and budget for replacement within the next 3-5 years."
        case .minor:
            return "Cosmetic only. Not affecting function."
        }
    }

    private static func sampleWeather() -> WeatherData {
        WeatherData(
            temperature: 64.0,
            conditions: "Overcast",
            humidity: 58.0,
            windSpeed: 5.2,
            capturedAt: Date().addingTimeInterval(-3600)
        )
    }

    private static func loadPhoto(named: String, jobId: UUID) -> String? {
        let srcURL = URL(fileURLWithPath: "\(assetsPath)/\(named)")
        guard let data = try? Data(contentsOf: srcURL),
              let img = UIImage(data: data) else {
            print("DemoModeFixture: failed to load \(named) from \(assetsPath)")
            return nil
        }
        return savePhotoToInspection(img, jobId: jobId)
    }

    private static func savePhotoToInspection(_ image: UIImage, jobId: UUID) -> String? {
        let fileName = UUID().uuidString + ".png"
        let folder = FilePaths.photosFolder(jobId: jobId)
        let url = folder.appendingPathComponent(fileName)
        do {
            try FileSecurity.ensureProtectedDirectory(folder)
            guard let data = image.pngData() else { return nil }
            try FileSecurity.writeProtected(data, to: url, options: [.atomic])
            PhotoLoadService.shared.generateThumbnailIfNeeded(jobId: jobId, fileName: fileName)
            return fileName
        } catch {
            print("DemoModeFixture: savePhoto failed: \(error)")
            return nil
        }
    }
}
#endif
