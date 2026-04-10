//
//  InspectorProfile.swift
//  NexGenSpec
//
//  Persistent inspector/company profile. Stored in UserDefaults.
//  Auto-fills inspector name and company on new inspections.
//

import Foundation

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

    private init() {
        self.inspectorName = UserDefaults.standard.string(forKey: Key.name) ?? ""
        self.companyName = UserDefaults.standard.string(forKey: Key.company) ?? ""
        self.licenseNumber = UserDefaults.standard.string(forKey: Key.license) ?? ""
        self.phone = UserDefaults.standard.string(forKey: Key.phone) ?? ""
        self.email = UserDefaults.standard.string(forKey: Key.email) ?? ""
    }
}
