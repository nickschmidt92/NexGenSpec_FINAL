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
        // Branding freezes into each inspection's snapshot at creation time
        // (InspectionStore.createNewInspection), so seed it before anything else.
        seedBranding()

        // Lightweight rows so the dashboard metrics read non-trivially
        // (6 total / 4 drafts / 2 final). ORDER MATTERS: createNewInspection
        // inserts at metadataList index 0 and ScreenshotHost.primaryVersionID
        // targets .first — the rich finalized Whitaker job must be created LAST.
        createLightweightInspection(
            store: store, clientName: "Priya & Dev Patel",
            clientEmail: "ppatel@example.com", clientPhone: "(303) 555-0164",
            propertyAddress: "4521 Larkspur Lane, Thornton, CO 80241",
            hoursAgo: 24 * 14, coverPhoto: "02-kitchen.jpg", finalized: false)
        createLightweightInspection(
            store: store, clientName: "Sofia Ramirez",
            clientEmail: "sramirez@example.com", clientPhone: "(720) 555-0119",
            propertyAddress: "882 Beacon Hill Court, Aurora, CO 80016",
            hoursAgo: 24 * 10, coverPhoto: "03-bathroom.jpg", finalized: false)
        createLightweightInspection(
            store: store, clientName: "Grant & Lily Okafor",
            clientEmail: "gokafor@example.com", clientPhone: "(303) 555-0195",
            propertyAddress: "7310 Winterberry Drive, Castle Rock, CO 80109",
            hoursAgo: 24 * 6, coverPhoto: "15-hvac-unit.jpg", finalized: true)
        createLightweightInspection(
            store: store, clientName: "Tom Beckett",
            clientEmail: "tbeckett@example.com", clientPhone: "(720) 555-0148",
            propertyAddress: "1540 S Gaylord Street, Denver, CO 80210",
            hoursAgo: 24 * 3, coverPhoto: "06-defect-roof-shingle.jpg", finalized: false)

        createDraftInspection(store: store)
        createReadyToFinalizeInspection(store: store)
    }

    // MARK: - Demo branding

    /// Generic screenshot branding (never D.I.A. / never Nick's name).
    @MainActor
    private static func seedBranding() {
        let profile = InspectorProfile.shared
        profile.inspectorName = "Jordan Reed"
        profile.companyName = "Summit Home Inspections"
        profile.licenseNumber = "CO-HI-104382"
        profile.phone = "(303) 555-0177"
        profile.email = "office@summitinspections.example"
        if let logo = UIImage(contentsOfFile: "\(assetsPath)/summit-logo.png") {
            profile.companyLogo = logo   // didSet writes appRoot/company_logo.png
        } else {
            print("DemoModeFixture: summit-logo.png missing — reports fall back to the NexGenSpec logo")
        }
    }

    // MARK: - Lightweight dashboard rows

    @MainActor
    private static func createLightweightInspection(
        store: InspectionStore,
        clientName: String,
        clientEmail: String,
        clientPhone: String,
        propertyAddress: String,
        hoursAgo: Double,
        coverPhoto: String,
        finalized: Bool
    ) {
        store.createNewInspection(
            clientName: clientName,
            clientEmail: clientEmail,
            clientPhone: clientPhone,
            propertyAddress: propertyAddress,
            inspectorName: "Jordan Reed",
            inspectorConfirmed: true,
            inspectionDate: Date().addingTimeInterval(-3600 * hoursAgo)
        )
        guard let metadata = store.metadataList.first,
              var version = store.loadFullVersion(id: metadata.id) else { return }
        let jobId = UUID(uuidString: version.inspection.inspectionId) ?? version.id
        if let coverName = loadCoverPhoto(named: coverPhoto, jobId: jobId) {
            version.inspection.coverPhotoFileName = coverName
        }
        version.inspection.weather = sampleWeather()
        if finalized {
            for sIdx in version.inspection.sections.indices {
                for iIdx in version.inspection.sections[sIdx].items.indices {
                    version.inspection.sections[sIdx].items[iIdx].status = .inspected
                    version.inspection.sections[sIdx].items[iIdx].includeInReport = true
                }
            }
            version.inspection.signatures = [
                InspectionSignature(name: "Jordan Reed", imageData: Data(), date: Date()),
                InspectionSignature(name: clientName, imageData: Data(), date: Date())
            ]
            store.update(version: version)
            store.finalize(version: version)
        } else {
            store.update(version: version)
        }
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

        if let coverName = loadCoverPhoto(named: "01-exterior.jpg", jobId: jobId) {
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

        if let coverName = loadCoverPhoto(named: "11-aerial-drone.jpg", jobId: jobId)
            ?? loadCoverPhoto(named: "01-exterior.jpg", jobId: jobId) {
            version.inspection.coverPhotoFileName = coverName
        }
        version.inspection.weather = sampleWeather()

        populateSections(&version, jobId: jobId, mode: .full)
        seedLiDARScan(jobId: jobId)
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
        // Photo order matters: the FIRST photo in each list lands on the
        // section's first tagged defect item (see targets below), so lead
        // with the photo that depicts the defect.
        let photoMap: [String: [String]] = [
            "Roof Structure":  ["06-defect-roof-shingle.jpg"],
            "Exterior":        ["14-defect-foundation-crack.jpg", "01-exterior.jpg"],
            "Foundation":      ["14-defect-foundation-crack.jpg"],
            "Plumbing":        ["08-defect-plumbing-leak.jpg", "03-bathroom.jpg"],
            "Electrical":      ["07-defect-electrical-outlet.jpg", "12-thermal-electrical.jpg"],
            "Heating & Cooling": ["10-defect-hvac-filter.jpg", "15-hvac-unit.jpg", "13-thermal-wall.jpg"],
            "Attic":           ["13-thermal-wall.jpg"],
            "Water Heater":    ["08-defect-plumbing-leak.jpg"],
            "Appliances":      ["02-kitchen.jpg"],
            "Crawl Space":     ["05-defect-ceiling-stain.jpg"]
        ]

        // Defect tagging with full write-ups so report item cards don't show
        // empty Observed/Implication/Recommendation labels. Item indices are
        // chosen to match the template item whose TITLE reads like the defect
        // (verified against Templates/InspectionTemplate.json).
        struct DemoDefect {
            let itemIndex: Int
            let severity: Severity
            let location: String
            let observed: String
            let implication: String
            let recommendation: String
        }
        let defectMap: [String: [DemoDefect]] = [
            "Roof Structure": [DemoDefect(itemIndex: 0, severity: .marginal,
                location: "South slope",
                observed: "Displaced tiles with exposed underlayment on the south slope.",
                implication: "Open courses admit wind-driven rain and accelerate deck deterioration.",
                recommendation: "Licensed roofing contractor to reset or replace displaced tiles and evaluate the underlayment.")],
            "Exterior": [DemoDefect(itemIndex: 1, severity: .minor,
                location: "Front entry walkway",
                observed: "Walkway slab offset 3/4\" at the front approach joint.",
                implication: "Trip hazard on the primary entry path.",
                recommendation: "Grind or mudjack the offset section to restore an even walking surface.")],
            "Foundation": [DemoDefect(itemIndex: 1, severity: .major,
                location: "Northeast corner",
                observed: "Vertical crack wider than 1/8\" with minor spalling.",
                implication: "May indicate ongoing settlement and provides a moisture entry path.",
                recommendation: "Consult a licensed structural engineer; seal and monitor the crack.")],
            "Plumbing": [DemoDefect(itemIndex: 2, severity: .marginal,
                location: "Kitchen sink cabinet",
                observed: "Active seep at the copper supply joint below the kitchen sink.",
                implication: "Continued leakage will damage the cabinet base and may promote mold growth.",
                recommendation: "Licensed plumber to re-sweat or replace the affected joint.")],
            "Electrical": [DemoDefect(itemIndex: 13, severity: .safety,
                location: "Kitchen counter receptacle",
                observed: "Open ground at the kitchen counter GFCI receptacle.",
                implication: "Shock hazard; downstream protection may not operate as intended.",
                recommendation: "Licensed electrician to correct the grounding before close.")],
            "Heating & Cooling": [DemoDefect(itemIndex: 3, severity: .marginal,
                location: "Furnace return",
                observed: "Return filter heavily loaded; airflow restricted at the blower.",
                implication: "Reduced efficiency and added strain on the blower motor.",
                recommendation: "Replace the filter, service the furnace, and verify airflow.")],
            // Documented with the imported thermal image — shows the
            // drone/thermal photo-library import feature in the report.
            "Attic": [DemoDefect(itemIndex: 2, severity: .marginal,
                location: "North attic wall",
                observed: "Infrared scan: cold streaking between framing bays — insulation voids.",
                implication: "Heat loss, higher energy costs, and potential condensation points at the cold bays.",
                recommendation: "Air-seal and top up insulation in the affected bays; re-scan to verify coverage.")]
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
                    var item = version.inspection.sections[sIdx].items[d.itemIndex]
                    item.defectSeverity = d.severity
                    item.location = d.location
                    item.observed = d.observed
                    item.implication = d.implication
                    item.recommendation = d.recommendation
                    item.inspectorComments = sampleComment(for: d.severity)
                    version.inspection.sections[sIdx].items[d.itemIndex] = item
                }
            }

            // Photos attach to the tagged DEFECT items first (so defect-summary
            // thumbnails show the defect photo), then to the remaining items.
            // Iterate until enough photos actually LOAD (a missing asset no
            // longer silently leaves the section photo-less).
            var targets = (defectMap[section.title] ?? []).map(\.itemIndex).filter { $0 < section.items.count }
            for idx in section.items.indices where !targets.contains(idx) { targets.append(idx) }
            let photoFiles = photoMap[section.title] ?? []
            let wanted = (mode == .partial) ? 1 : photoFiles.count
            var attached = 0
            for photoFile in photoFiles {
                guard attached < wanted, attached < targets.count else { break }
                if let fileName = loadPhoto(named: photoFile, jobId: jobId) {
                    let target = targets[attached]
                    let photo = InspectionPhoto(
                        fileName: fileName,
                        caption: "",
                        sortOrder: version.inspection.sections[sIdx].items[target].photos.count
                    )
                    version.inspection.sections[sIdx].items[target].photos.append(photo)
                    attached += 1
                }
            }
        }
    }

    // MARK: - LiDAR demo scan (floor-plan hero + 3D model shots)

    /// Seeds one clean rectangular "Living Room" scan on the primary demo job:
    /// copies the fixture USDZ, draws a floor-plan PNG in FloorplanRenderer's
    /// exact visual style, and saves a LiDARScan whose hand-authored
    /// measurements match the drawn geometry
    /// (15.2 ft × 13.1 ft · 8.0 ft ceiling · ~199 sq ft).
    /// roomJSONFileName stays nil so the whole-home merge path (which needs
    /// ≥2 decodable CapturedRooms) is never attempted in the simulator.
    @MainActor
    private static func seedLiDARScan(jobId: UUID) {
        let lidarDir = FilePaths.lidarFolder(jobId: jobId)
        try? FileSecurity.ensureProtectedDirectory(lidarDir)

        let scanId = UUID()
        let usdzName = "\(scanId.uuidString).usdz"
        guard let usdz = try? Data(contentsOf: URL(fileURLWithPath: "\(assetsPath)/living-room-scan.usdz")) else {
            print("DemoModeFixture: living-room-scan.usdz missing — run scripts/make-demo-fixtures.swift")
            return
        }
        do {
            try FileSecurity.writeProtected(usdz, to: lidarDir.appendingPathComponent(usdzName), options: [.atomic])
        } catch {
            print("DemoModeFixture: USDZ write failed: \(error)")
            return
        }

        var pngName: String?
        if let png = demoFloorplanPNG() {
            let name = "\(scanId.uuidString)_floorplan.png"
            if (try? FileSecurity.writeProtected(png, to: lidarDir.appendingPathComponent(name), options: [.atomic])) != nil {
                pngName = name
            }
        }

        let scan = LiDARScan(
            id: scanId,
            versionId: jobId,
            usdzFileName: usdzName,
            floorplanPNGFileName: pngName,
            roomJSONFileName: nil,
            name: "Living Room",
            sectionId: nil,
            measurements: [
                Measurement(type: Measurement.Kind.roomLength, value: 15.2, unit: Measurement.Unit.feet, label: "Room length"),
                Measurement(type: Measurement.Kind.roomWidth, value: 13.1, unit: Measurement.Unit.feet, label: "Room width"),
                Measurement(type: Measurement.Kind.ceilingHeight, value: 8.0, unit: Measurement.Unit.feet, label: "Ceiling height"),
                Measurement(type: Measurement.Kind.floorArea, value: 199, unit: Measurement.Unit.squareFeet, label: "Floor area")
            ],
            capturedAt: Date().addingTimeInterval(-3600 * 25)
        )
        LiDARScanStore.save(scan, jobId: jobId)
    }

    /// Draws the demo floor plan in FloorplanRenderer.renderPNG's exact visual
    /// style (canvas, colors, line widths, labels, legend). FloorplanRenderer
    /// itself consumes a RoomPlan CapturedRoom — which has no public
    /// initializer and can only come from a real device capture — so for the
    /// seeded demo we mirror its drawing code over the same rectangular
    /// geometry the seeded measurements describe.
    private static func demoFloorplanPNG() -> Data? {
        struct Seg { var start: CGPoint; var end: CGPoint }
        let w: CGFloat = 4.633   // meters ⇒ 15.2 ft
        let d: CGFloat = 3.993   // meters ⇒ 13.1 ft
        let walls = [
            Seg(start: .init(x: -w/2, y: -d/2), end: .init(x: w/2, y: -d/2)),
            Seg(start: .init(x: -w/2, y: d/2), end: .init(x: w/2, y: d/2)),
            Seg(start: .init(x: -w/2, y: -d/2), end: .init(x: -w/2, y: d/2)),
            Seg(start: .init(x: w/2, y: -d/2), end: .init(x: w/2, y: d/2))
        ]
        // A 3.0 ft door on the south wall; a 5.0 ft and a 4.0 ft window.
        let doors = [Seg(start: .init(x: 0.60, y: d/2), end: .init(x: 1.51, y: d/2))]
        let windows = [
            Seg(start: .init(x: -1.20, y: -d/2), end: .init(x: 0.32, y: -d/2)),
            Seg(start: .init(x: w/2, y: -1.00), end: .init(x: w/2, y: 0.22))
        ]

        let size = CGSize(width: 1600, height: 1200)
        let margin: CGFloat = 80
        let scale = min((size.width - margin * 2) / w, (size.height - margin * 2) / d)
        let offsetX = (size.width - w * scale) / 2 + (w / 2) * scale
        let offsetY = (size.height - d * scale) / 2 + (d / 2) * scale
        func project(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * scale + offsetX, y: p.y * scale + offsetY)
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let c = ctx.cgContext
            UIColor.white.setFill()
            c.fill(CGRect(origin: .zero, size: size))

            c.setLineCap(.round)
            c.setLineJoin(.round)
            UIColor.black.setStroke()
            c.setLineWidth(5)
            for seg in walls {
                c.move(to: project(seg.start))
                c.addLine(to: project(seg.end))
            }
            c.strokePath()

            UIColor.systemOrange.setStroke()
            c.setLineWidth(7)
            for seg in doors {
                c.move(to: project(seg.start))
                c.addLine(to: project(seg.end))
            }
            c.strokePath()

            UIColor.systemTeal.setStroke()
            c.setLineWidth(7)
            for seg in windows {
                c.move(to: project(seg.start))
                c.addLine(to: project(seg.end))
            }
            c.strokePath()

            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
                .foregroundColor: UIColor.darkGray
            ]
            for seg in walls {
                let meters = hypot(seg.end.x - seg.start.x, seg.end.y - seg.start.y)
                let feet = Double(meters) * 3.28084
                let label = String(format: "%.1f′", feet)
                let pStart = project(seg.start)
                let pEnd = project(seg.end)
                let mid = CGPoint(x: (pStart.x + pEnd.x) / 2, y: (pStart.y + pEnd.y) / 2)
                let dx = pEnd.x - pStart.x
                let dy = pEnd.y - pStart.y
                let len = max(hypot(dx, dy), 0.001)
                let nx = -dy / len
                let ny = dx / len
                let offset: CGFloat = 14
                let textPoint = CGPoint(x: mid.x + nx * offset, y: mid.y + ny * offset)
                let attr = NSAttributedString(string: label, attributes: labelAttrs)
                let textSize = attr.size()
                let rect = CGRect(
                    x: textPoint.x - textSize.width / 2,
                    y: textPoint.y - textSize.height / 2,
                    width: textSize.width,
                    height: textSize.height
                )
                UIColor(white: 1, alpha: 0.85).setFill()
                UIBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -2), cornerRadius: 4).fill()
                attr.draw(in: rect)
            }

            // Legend — bottom-left, mirroring FloorplanRenderer.drawLegend.
            let x: CGFloat = 24
            let y: CGFloat = size.height - 96
            let rowH: CGFloat = 22
            let swatchW: CGFloat = 28
            let items: [(String, UIColor, Bool)] = [
                ("Wall", .black, false),
                ("Door", .systemOrange, false),
                ("Window", .systemTeal, false),
                ("Opening", UIColor(white: 0.55, alpha: 1), true)
            ]
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.darkGray
            ]
            for (i, item) in items.enumerated() {
                let rowY = y + CGFloat(i) * rowH
                item.1.setStroke()
                c.setLineWidth(4)
                if item.2 { c.setLineDash(phase: 0, lengths: [6, 4]) }
                c.move(to: CGPoint(x: x, y: rowY + rowH / 2))
                c.addLine(to: CGPoint(x: x + swatchW, y: rowY + rowH / 2))
                c.strokePath()
                c.setLineDash(phase: 0, lengths: [])
                let label = NSAttributedString(string: item.0, attributes: titleAttrs)
                label.draw(at: CGPoint(x: x + swatchW + 8, y: rowY + 2))
            }
        }
        return image.pngData()
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

    /// Cover photos are NOT item photos: CoverThumbnailView and the PDF cover
    /// resolve `FilePaths.coverPhotoFile(jobId:fileName:)` — the inspection
    /// folder ROOT — so the asset must be copied there (not photos/).
    private static func loadCoverPhoto(named: String, jobId: UUID) -> String? {
        let srcURL = URL(fileURLWithPath: "\(assetsPath)/\(named)")
        guard let data = try? Data(contentsOf: srcURL), UIImage(data: data) != nil else {
            print("DemoModeFixture: failed to load cover \(named) from \(assetsPath)")
            return nil
        }
        do {
            try FilePaths.ensureAppStructure(jobId: jobId)
            let url = FilePaths.coverPhotoFile(jobId: jobId, fileName: FilePaths.defaultCoverPhotoFileName)
            try FileSecurity.writeProtected(data, to: url, options: [.atomic])
            return FilePaths.defaultCoverPhotoFileName
        } catch {
            print("DemoModeFixture: cover save failed: \(error)")
            return nil
        }
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
