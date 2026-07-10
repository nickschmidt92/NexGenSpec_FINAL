//
//  ExportNaming.swift
//  NexGenSpec
//
//  Canonical, human-readable names for USER-FACING export & share artifacts —
//  the ZIP a client receives, its unzipped folder, the shared report PDF, and
//  the plain-text summary. One scheme, applied everywhere, so every artifact an
//  inspector hands a client reads the same way:
//
//      <Company>_<Property-or-Client>_<yyyy-MM-dd>
//      e.g. "Summit-Home-Inspections_123-Main-St_2026-07-10"
//
//  Company falls out when the inspection has no company snapshot (pre-build-26
//  inspections), leaving "<Property>_<Date>". Property falls back to the client
//  name, then to "Inspection", so the stem is never empty.
//
//  SCOPE — exports only. The INTERNAL canonical storage path
//  (`<appRoot>/Reports/[Property Address]/Inspection_Report.pdf`, FilesAppPublisher)
//  is deliberately NOT routed through here: cross-device asset sync (D-0203) and
//  the reports browser resolve PDFs by that exact fixed name, so renaming it
//  would orphan synced assets. This helper only governs what the inspector
//  shares OUT.
//

import Foundation

enum ExportNaming {

    // MARK: - Base stem

    /// Shared base stem for every user-facing export artifact of `inspection`,
    /// using the given `date` (pass the inspection date for stable, idempotent
    /// names — re-exporting the same job reproduces the same name rather than
    /// piling up timestamped copies).
    static func baseStem(for inspection: Inspection, date: Date) -> String {
        baseStem(
            company: inspection.companyName,
            property: firstNonEmpty(inspection.propertyAddress, inspection.clientName),
            date: date
        )
    }

    /// Convenience: base stem using the inspection's own `inspectionDate`.
    static func baseStem(for inspection: Inspection) -> String {
        baseStem(for: inspection, date: inspection.inspectionDate)
    }

    /// Base stem from raw components. Each text component is sanitized to a
    /// filesystem-safe, hyphenated form and length-clamped; components join with
    /// "_" (so the three fields stay visually separable). `company` may be empty;
    /// `property` empty falls back to "Inspection". Never returns "".
    static func baseStem(company: String, property: String, date: Date) -> String {
        let c = sanitize(company, maxLength: 40)
        let p = sanitize(property, maxLength: 60)
        let d = dateFormatter.string(from: date)
        var parts: [String] = []
        if !c.isEmpty { parts.append(c) }
        parts.append(p.isEmpty ? "Inspection" : p)
        parts.append(d)
        return parts.joined(separator: "_")
    }

    // MARK: - Share staging

    /// A fresh, uniquely-named temp directory for user-facing share artifacts
    /// (the shared PDF, the text summary). Prefixed `ngs-export-` so
    /// `ReportExportService.tempExportPrefixes` reaps it in both the routine temp
    /// sweep and the Account-Deletion wipe — client PII must never outlive account
    /// deletion (Guideline 5.1.1(v)).
    ///
    /// Non-throwing on purpose: it ALWAYS returns an `ngs-export-`-prefixed URL, so
    /// a caller can never be pushed onto a bare-temp fallback whose filename would
    /// escape the reap prefixes. Directory creation is best-effort here; the
    /// protected write that follows (`FileSecurity.writeProtected` /
    /// `copyProtectedItem`) re-creates the dir if this attempt didn't, and if that
    /// write can't create it either it throws — so no un-reaped PII file is ever
    /// left behind.
    static func freshShareDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ngs-export-\(UUID().uuidString)", isDirectory: true)
        try? FileSecurity.ensureProtectedDirectory(dir)
        return dir
    }

    /// Returns a URL to hand the share sheet under `desiredName`. If `originalURL`
    /// is already named `desiredName` it is returned unchanged (no copy — e.g. a
    /// ZIP that already carries its export name). Otherwise the file is copied
    /// into a fresh, reap-tagged temp dir under `desiredName`, so "Save to Files"
    /// shows the clean name instead of an internal fixed one (the canonical
    /// `Inspection_Report.pdf`). Best-effort: on any copy failure it falls back to
    /// the original URL so sharing can never break.
    static func preparedShareURL(for originalURL: URL, desiredName: String) -> URL {
        guard originalURL.lastPathComponent != desiredName else { return originalURL }
        do {
            let dest = freshShareDirectory().appendingPathComponent(desiredName)
            try FileSecurity.copyProtectedItem(from: originalURL, to: dest)
            return dest
        } catch {
            Diagnostics.logError(
                context: "ExportNaming.preparedShareURL copy failed",
                error: error, persistToDisk: false
            )
            return originalURL
        }
    }

    // MARK: - Helpers

    private static func firstNonEmpty(_ a: String, _ b: String) -> String {
        a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? b : a
    }

    /// Keeps alphanumerics, maps every other character (spaces, punctuation) to a
    /// single "-", collapses runs, trims edge "-", then clamps to `maxLength`.
    private static func sanitize(_ raw: String, maxLength: Int) -> String {
        let allowed = CharacterSet.alphanumerics
        var cleaned = raw.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if cleaned.count > maxLength {
            cleaned = String(cleaned.prefix(maxLength))
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        return cleaned
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
