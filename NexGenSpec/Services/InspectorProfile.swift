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

    /// Company logo image for PDF report branding.
    @Published var companyLogo: UIImage? {
        didSet { saveLogoToDisk(companyLogo) }
    }

    private init() {
        self.inspectorName = UserDefaults.standard.string(forKey: Key.name) ?? ""
        self.companyName = UserDefaults.standard.string(forKey: Key.company) ?? ""
        self.licenseNumber = UserDefaults.standard.string(forKey: Key.license) ?? ""
        self.phone = UserDefaults.standard.string(forKey: Key.phone) ?? ""
        self.email = UserDefaults.standard.string(forKey: Key.email) ?? ""
        self.companyLogo = loadLogoFromDisk()
    }

    /// Wipes all stored profile data. Called from `AuthManager.logout()` so a
    /// shared device never carries one inspector's identity into the next
    /// user's session. This matters beyond convenience: the profile email is
    /// auto-CC'd on invoices, and the name / company / license are printed on
    /// the client-facing report — none of which should belong to a previous
    /// user. The `didSet` observers persist the cleared values to UserDefaults,
    /// and setting `companyLogo = nil` removes the logo file from disk.
    @MainActor
    func clear() {
        inspectorName = ""
        companyName = ""
        licenseNumber = ""
        phone = ""
        email = ""
        companyLogo = nil
    }

    /// Base64-encoded PNG of the company logo (for embedding in HTML reports).
    var companyLogoBase64: String? {
        guard let logo = companyLogo,
              let data = logo.pngData() else { return nil }
        return data.base64EncodedString()
    }

    func removeCompanyLogo() {
        companyLogo = nil
        try? FileManager.default.removeItem(at: Self.logoURL)
    }

    // MARK: - Disk persistence

    private static var logoURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("company_logo.png")
    }

    private func saveLogoToDisk(_ image: UIImage?) {
        guard let image, let data = image.pngData() else {
            try? FileManager.default.removeItem(at: Self.logoURL)
            return
        }
        try? data.write(to: Self.logoURL, options: .atomic)
    }

    private func loadLogoFromDisk() -> UIImage? {
        guard let data = try? Data(contentsOf: Self.logoURL) else { return nil }
        return UIImage(data: data)
    }
}
