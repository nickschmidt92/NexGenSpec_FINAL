//
//  InspectorProfile.swift
//  NexGenSpec
//
//  Persistent inspector/company profile. Stored in UserDefaults.
//  Auto-fills inspector name and company on new inspections.
//

import Foundation
import UIKit

final class InspectorProfile: ObservableObject {

    static let shared = InspectorProfile()

    private enum Key {
        static let name = "nexgenspec.profile.inspectorName"
        static let company = "nexgenspec.profile.companyName"
        static let license = "nexgenspec.profile.licenseNumber"
        static let phone = "nexgenspec.profile.phone"
        static let email = "nexgenspec.profile.email"
    }

    @Published var inspectorName: String {
        didSet { UserDefaults.standard.set(inspectorName, forKey: Key.name) }
    }

    @Published var companyName: String {
        didSet { UserDefaults.standard.set(companyName, forKey: Key.company) }
    }

    @Published var licenseNumber: String {
        didSet { UserDefaults.standard.set(licenseNumber, forKey: Key.license) }
    }

    @Published var phone: String {
        didSet { UserDefaults.standard.set(phone, forKey: Key.phone) }
    }

    @Published var email: String {
        didSet { UserDefaults.standard.set(email, forKey: Key.email) }
    }

    /// When true, the `companyLogo` didSet skips the disk write/delete. Used by
    /// `clear(removeLogoFile: false)` to drop the in-memory logo on logout
    /// WITHOUT deleting the per-UID file — the file belongs to the logging-out
    /// user, is per-UID isolated (never bleeds into another account), and is
    /// restored on their own re-login. Account deletion still wipes it.
    private var suppressLogoDiskSync = false

    /// Company logo image for PDF report branding.
    @Published var companyLogo: UIImage? {
        didSet { if !suppressLogoDiskSync { saveLogoToDisk(companyLogo) } }
    }

    private init() {
        self.inspectorName = UserDefaults.standard.string(forKey: Key.name) ?? ""
        self.companyName = UserDefaults.standard.string(forKey: Key.company) ?? ""
        self.licenseNumber = UserDefaults.standard.string(forKey: Key.license) ?? ""
        self.phone = UserDefaults.standard.string(forKey: Key.phone) ?? ""
        self.email = UserDefaults.standard.string(forKey: Key.email) ?? ""
        self.companyLogo = loadLogoFromDisk()
    }

    /// Wipes the stored profile so a shared device never carries one inspector's
    /// identity into the next user's session: the profile email is auto-CC'd on
    /// invoices, and the name / company / license are printed on the client
    /// report — none of which should belong to a previous user. The `didSet`
    /// observers persist the cleared text values to UserDefaults.
    ///
    /// `removeLogoFile` controls the per-UID company logo on disk:
    /// - `true` (default, used by account DELETION): delete the logo file too.
    /// - `false` (used by LOGOUT): drop the logo from memory but KEEP the file.
    ///   The logo is namespaced per-UID under `FilePaths.appRoot`, so it can
    ///   never bleed into another account, and keeping it restores the user's
    ///   own branding on their next login instead of silently losing it.
    @MainActor
    func clear(removeLogoFile: Bool = true) {
        inspectorName = ""
        companyName = ""
        licenseNumber = ""
        phone = ""
        email = ""
        if removeLogoFile {
            companyLogo = nil            // didSet removes the per-UID logo file
        } else {
            suppressLogoDiskSync = true  // drop from memory, keep the file
            companyLogo = nil
            suppressLogoDiskSync = false
        }
    }

    /// Re-reads the profile for the CURRENT namespace. Called from the
    /// account-switch seam (NexGenSpecApp's `onChange(of: currentUID)`) alongside
    /// `store.reloadFromDisk()` / `CustomTemplateStore.reload()`, so the profile
    /// re-scopes on login / logout / account switch like its siblings. The flat
    /// text keys live in `UserDefaults.standard` (re-read here for completeness),
    /// while the company logo is namespaced under `FilePaths.appRoot` — so the
    /// logo specifically must be reloaded from the now-current namespace, or
    /// account B could keep showing account A's logo on a shared device.
    @MainActor
    func reload() {
        inspectorName = UserDefaults.standard.string(forKey: Key.name) ?? ""
        companyName = UserDefaults.standard.string(forKey: Key.company) ?? ""
        licenseNumber = UserDefaults.standard.string(forKey: Key.license) ?? ""
        phone = UserDefaults.standard.string(forKey: Key.phone) ?? ""
        email = UserDefaults.standard.string(forKey: Key.email) ?? ""
        companyLogo = loadLogoFromDisk()
    }

    /// Base64-encoded PNG of the company logo (for embedding in HTML reports).
    ///
    /// Reads the bytes straight from the on-disk PNG that `saveLogoToDisk`
    /// already normalized + wrote, rather than re-encoding the in-memory
    /// `UIImage`. The in-memory image can come from the photo picker without a
    /// backing `CGImage` (e.g. a `CIImage`-backed `UIImage`), in which case
    /// `pngData()` returns nil — which previously made the report silently fall
    /// back to the app icon even though a logo was set (B-0066). The disk copy
    /// is always a valid bitmap PNG, so this can't fail that way.
    var companyLogoBase64: String? {
        guard let data = try? Data(contentsOf: Self.logoURL), !data.isEmpty else { return nil }
        // Validate the bytes actually decode to an image before handing them to
        // the renderer. A corrupt or truncated on-disk PNG would otherwise be
        // base64-encoded as-is and produce a broken <img> in the report with no
        // fallback; returning nil here lets the renderer's NexGenSpec-logo
        // fallback engage instead.
        guard UIImage(data: data) != nil else { return nil }
        return data.base64EncodedString()
    }

    func removeCompanyLogo() {
        companyLogo = nil
        try? FileManager.default.removeItem(at: Self.logoURL)
    }

    // MARK: - Disk persistence

    private static var logoURL: URL {
        // Under the private app root (Application Support), not the file-shared
        // Documents directory (B-0045).
        FilePaths.appRoot.appendingPathComponent("company_logo.png", isDirectory: false)
    }

    /// Max longest-side pixel dimension for the stored company logo. The logo
    /// is the only user-supplied image that previously bypassed report
    /// downsampling, so an un-downsampled photo dropped in as a "logo" could
    /// OOM the report render. Cap the long side at 512px before encoding —
    /// well above what a logo needs in a PDF header. Mirrors the technique in
    /// AnnotationBakeService.resizeForReport.
    private static let maxLogoSidePixels: CGFloat = 512

    /// Normalizes the company logo for storage: caps the longest side at
    /// `maxLogoSidePixels` (down-scaling only when larger) AND **always**
    /// re-renders through `UIGraphicsImageRenderer`, guaranteeing a
    /// `CGImage`-backed bitmap. The always-render matters: a picker-supplied
    /// `UIImage` may have no backing `CGImage`, so calling `pngData()` on it
    /// directly returns nil — which used to delete the logo file and fall the
    /// report back to the app icon (B-0066). Re-rendering normalizes any source
    /// so `pngData()` always succeeds.
    private static func normalizedLogo(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        let ratio = longest > maxLogoSidePixels ? maxLogoSidePixels / longest : 1
        let target = CGSize(
            width: floor(image.size.width * ratio),
            height: floor(image.size.height * ratio)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func saveLogoToDisk(_ image: UIImage?) {
        guard let image else {
            try? FileManager.default.removeItem(at: Self.logoURL)
            return
        }
        // Normalize (downsample if huge + force a CGImage-backed bitmap) before
        // encoding so a huge user-supplied image can't OOM the report render and
        // a picker image with no CGImage backing can't make pngData() return nil
        // (B-0066). After normalizing, pngData() always succeeds.
        guard let data = Self.normalizedLogo(image).pngData() else {
            try? FileManager.default.removeItem(at: Self.logoURL)
            return
        }
        // Ensure the private app root exists and write with file protection.
        try? FileSecurity.ensureProtectedDirectory(Self.logoURL.deletingLastPathComponent())
        try? FileSecurity.writeProtected(data, to: Self.logoURL)
    }

    private func loadLogoFromDisk() -> UIImage? {
        guard let data = try? Data(contentsOf: Self.logoURL) else { return nil }
        return UIImage(data: data)
    }
}
