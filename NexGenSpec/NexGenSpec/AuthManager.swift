//
//  AuthManager.swift
//  InspectIQ
//
//  Completely rewritten – 17 Feb 2026
//

import Foundation
import Combine

/// **Demo-only authentication layer.**
/// Replace the logic with your real backend later.
@MainActor
public final class AuthManager: ObservableObject {

    // MARK: – Public state ----------------------------------------------------

    /// `true` when a user is signed-in.
    @Published public private(set) var isAuthenticated = false

    /// Very simple role model used by the UI.
    public enum AppRole {
        case none
        case owner
        case user
    }

    @Published public private(set) var role: AppRole = .none

    // MARK: – Login / Logout --------------------------------------------------

    /// Attempts to sign in.
    /// - Returns: `true` on success.
    @discardableResult
    public func login(username: String, password: String) -> Bool {

        // --------------------------------------------------------------------
        // Demo rules:
        //  • owner / supersecret     → owner role
        //  • any non-empty combo     → user role
        //  • empty fields            → reject
        // --------------------------------------------------------------------

        if username == "owner", password == "supersecret" {
            isAuthenticated = true
            role = .owner
        } else if !username.isEmpty && !password.isEmpty {
            isAuthenticated = true
            role = .user
        } else {
            isAuthenticated = false
            role = .none
        }

        return isAuthenticated
    }

    /// Signs the current user out.
    public func logout() {
        isAuthenticated = false
        role = .none
    }
}
