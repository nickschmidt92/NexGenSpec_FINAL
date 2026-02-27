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
///
/// Note: The following accounts are for internal/testing only:
/// - Owner: username "owner", password "supersecret" (admin-level owner role)
/// - Admin: username "admin", password "supersecret" (admin-level admin role)
/// - Tester: username "testflight", password "testpassword" (standard user role)
@MainActor
public final class AuthManager: ObservableObject {

    // MARK: – Public state ----------------------------------------------------

    /// `true` when a user is signed-in.
    @Published public private(set) var isAuthenticated = false

    /// Very simple role model used by the UI.
    public enum AppRole {
        case none
        case owner
        case admin
        case user
    }

    @Published public private(set) var role: AppRole = .none

    /// `true` when the current user is an admin (owner or admin).
    ///
    /// Use this property wherever admin-only controls or functions should be displayed or enabled in your UI.
    /// ```swift
    /// if authManager.isAdmin {
    ///     // show admin controls
    /// }
    /// ```
    public var isAdmin: Bool {
        return role == .owner || role == .admin
    }

    // MARK: – Login / Logout --------------------------------------------------

    /// Attempts to sign in.
    /// - Returns: `true` on success.
    ///
    /// Demo rules:
    ///  • owner / supersecret (admin-level owner role)
    ///  • admin / supersecret (admin-level admin role)
    ///  • testflight / testpassword (standard user role for tester)
    ///  • any other non-empty combo             → user role
    ///  • empty fields                          → reject
    @discardableResult
    public func login(username: String, password: String) -> Bool {

        // Reviewer/Test login:
        //   Owner: owner / supersecret
        //   Admin: admin / supersecret
        //   Tester: testflight / testpassword

        if username == "owner", password == "supersecret" {
            isAuthenticated = true
            role = .owner
        } else if username == "admin", password == "supersecret" {
            isAuthenticated = true
            role = .admin
        } else if username == "testflight", password == "testpassword" {
            isAuthenticated = true
            role = .user
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

