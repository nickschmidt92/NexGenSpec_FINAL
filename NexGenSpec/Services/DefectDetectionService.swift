//
//  DefectDetectionService.swift
//  NexGenSpec
//
//  AI defect detection using Apple Vision framework. Analyzes inspection photos
//  and suggests defect categories based on image classification.
//

import UIKit
import Vision

/// Analyzes inspection photos using VNClassifyImageRequest and maps results
/// to common home-inspection defect categories. Runs asynchronously; callers
/// receive suggestions when ready.
final class DefectDetectionService {

    static let shared = DefectDetectionService()
    private init() {}

    // MARK: - Defect Categories

    /// Inspection-specific defect categories surfaced to the inspector.
    static let defectCategories: [String] = [
        "Water Damage / Moisture",
        "Cracks",
        "Mold / Mildew",
        "Electrical Issue",
        "Rust / Corrosion",
        "Missing / Damaged Component",
        "Staining / Discoloration",
        "Pest / Insect Damage",
        "Deterioration / Wear"
    ]

    // MARK: - Vision-label-to-defect mapping

    /// Maps Vision classification identifiers (lowercased substrings) to
    /// inspection defect categories.  VNClassifyImageRequest uses the built-in
    /// Core ML model which returns generic labels — we do a best-effort
    /// keyword match against known defect-related terms.
    private static let labelMapping: [(keywords: [String], defect: String)] = [
        // Water / moisture
        (["water", "puddle", "flood", "drip", "leak", "moisture", "wet", "damp", "condensation", "rain"],
         "Water Damage / Moisture"),
        // Cracks
        (["crack", "fracture", "split", "fissure", "break", "broken"],
         "Cracks"),
        // Mold / mildew
        (["mold", "mildew", "fungus", "fungi", "lichen", "algae", "moss"],
         "Mold / Mildew"),
        // Electrical
        (["wire", "wiring", "cable", "electric", "outlet", "socket", "switch", "spark", "conductor"],
         "Electrical Issue"),
        // Rust / corrosion
        (["rust", "corrosion", "corrode", "oxidize", "oxidation", "patina", "tarnish"],
         "Rust / Corrosion"),
        // Missing / damaged components
        (["hole", "missing", "damage", "dent", "bent", "deform", "shatter", "chip", "gouge"],
         "Missing / Damaged Component"),
        // Staining
        (["stain", "discolor", "blotch", "spot", "mark", "blemish", "yellowing", "brown"],
         "Staining / Discoloration"),
        // Pest damage
        (["insect", "pest", "termite", "ant", "rodent", "gnaw", "bore", "infestation", "cockroach", "spider", "web"],
         "Pest / Insect Damage"),
        // General deterioration
        (["decay", "rot", "deteriorat", "wear", "erode", "erosion", "peel", "flak", "blister", "warp", "sag", "bubble"],
         "Deterioration / Wear")
    ]

    // MARK: - Public API

    /// Analyze an image and return suggested defect tags.
    /// Returns an empty array if nothing relevant is detected.
    /// Safe to call from any queue; work is dispatched internally.
    func detectDefects(in image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }

        return await withCheckedContinuation { continuation in
            let request = VNClassifyImageRequest { request, error in
                guard error == nil,
                      let results = request.results as? [VNClassificationObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let tags = Self.mapClassifications(results)
                continuation.resume(returning: tags)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                Diagnostics.logError(context: "DefectDetection Vision request failed", error: error)
                continuation.resume(returning: [])
            }
        }
    }

    /// Convenience: detect from file on disk.
    func detectDefects(jobId: UUID, fileName: String) async -> [String] {
        let url = FilePaths.photosFolder(jobId: jobId).appendingPathComponent(fileName)
        guard let image = UIImage(contentsOfFile: url.path) else { return [] }
        return await detectDefects(in: image)
    }

    // MARK: - Mapping

    /// Takes Vision classification observations and returns unique defect tags
    /// whose confidence exceeds the threshold.
    private static func mapClassifications(_ observations: [VNClassificationObservation]) -> [String] {
        let confidenceThreshold: Float = 0.10
        var matched = Set<String>()

        for obs in observations where obs.confidence >= confidenceThreshold {
            let label = obs.identifier.lowercased()
            for mapping in labelMapping {
                if mapping.keywords.contains(where: { label.contains($0) }) {
                    matched.insert(mapping.defect)
                }
            }
        }

        // Return in a stable order matching defectCategories
        return defectCategories.filter { matched.contains($0) }
    }
}
