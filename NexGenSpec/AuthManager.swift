//
//  AuthManager.swift
//  NexGenSpec
//
//  Firebase-backed auth. Email/password + (in Step 3) Sign in with Apple.
//  Identity key: email address (lowercased, trimmed).
//  Session survives app relaunch via Firebase's own keychain-backed persistence.
//

import Foundation
import Combine
import FirebaseAuth
import AuthenticationServices

@MainActor
public final class AuthManager: ObservableObject {

    // MARK: - Public state

    @Published public private(set) var isAuthenticated = false
    @Published public private(set) var currentUsername: String?   // holds the user's email
    @Published public private(set) var isEmailVerified = false
    @Published public private(set) var authErrorMessage: String?
    @Published public private(set) var isBusy = false

    /// Kept for compatibility with existing views (AppSettingsView uses role / isAdmin).
    /// In V1 every Firebase user is a standard user. Admin/team roles come from a later
    /// Firestore custom-claims pass; do not gate UI on this yet.
    public enum AppRole {
        case none, owner, admin, user
    }
    @Published public private(set) var role: AppRole = .none
    public var isAdmin: Bool { role == .owner || role == .admin }

    // MARK: - Lifecycle

    private var authStateHandle: AuthStateDidChangeListenerHandle?

    public init() {
        // Rehydrate session on launch and keep state in sync with Firebase.
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.applyUser(user)
            }
        }
    }

    deinit {
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    private func applyUser(_ user: User?) {
        if let user {
            isAuthenticated = true
            currentUsername = user.email
            isEmailVerified = user.isEmailVerified
            role = .user
        } else {
            isAuthenticated = false
            currentUsername = nil
            isEmailVerified = false
            role = .none
        }
    }

    // MARK: - Login

    /// Signs in with email + password. Returns true on success.
    /// Error text (if any) is surfaced via `authErrorMessage`.
    @discardableResult
    public func login(email: String, password: String) async -> Bool {
        authErrorMessage = nil
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanEmail.isEmpty, !password.isEmpty else {
            authErrorMessage = "Please enter your email and password."
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await Auth.auth().signIn(withEmail: cleanEmail, password: password)
            applyUser(result.user)
            return true
        } catch {
            authErrorMessage = Self.friendlyMessage(for: error)
            return false
        }
    }

    // MARK: - Account creation

    /// Creates an account and sends a verification email. Returns true on success.
    /// Password must meet complexity rules (see `validatePassword`).
    @discardableResult
    public func createAccount(email: String, password: String) async -> Bool {
        authErrorMessage = nil
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard Self.isValidEmail(cleanEmail) else {
            authErrorMessage = "Please enter a valid email address."
            return false
        }
        if let complaint = Self.validatePassword(password) {
            authErrorMessage = complaint
            return false
        }

        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await Auth.auth().createUser(withEmail: cleanEmail, password: password)
            // Fire-and-forget verification email; don't block account creation on delivery.
            try? await result.user.sendEmailVerification()
            applyUser(result.user)
            return true
        } catch {
            authErrorMessage = Self.friendlyMessage(for: error)
            return false
        }
    }

    // MARK: - Sign in with Apple

    /// Runs the Sign in with Apple flow and exchanges the resulting Apple ID
    /// token for a Firebase credential. Returns true on success.
    @discardableResult
    public func signInWithApple() async -> Bool {
        authErrorMessage = nil
        isBusy = true
        defer { isBusy = false }

        let coordinator = SignInWithAppleCoordinator()
        do {
            let appleCredential = try await coordinator.start()
            guard let tokenData = appleCredential.identityToken,
                  let idTokenString = String(data: tokenData, encoding: .utf8) else {
                authErrorMessage = "Apple sign-in did not return an identity token."
                return false
            }

            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: idTokenString,
                rawNonce: coordinator.rawNonce,
                fullName: appleCredential.fullName
            )

            let result = try await Auth.auth().signIn(with: firebaseCredential)
            applyUser(result.user)
            return true
        } catch {
            // Treat user-cancellation as a silent dismiss, not an error banner.
            if let asError = error as? ASAuthorizationError, asError.code == .canceled {
                return false
            }
            authErrorMessage = Self.friendlyMessage(for: error)
            return false
        }
    }

    // MARK: - Forgot password

    @discardableResult
    public func sendPasswordReset(email: String) async -> Bool {
        authErrorMessage = nil
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isValidEmail(cleanEmail) else {
            authErrorMessage = "Please enter a valid email address."
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await Auth.auth().sendPasswordReset(withEmail: cleanEmail)
            return true
        } catch {
            authErrorMessage = Self.friendlyMessage(for: error)
            return false
        }
    }

    // MARK: - Email verification

    @discardableResult
    public func resendVerificationEmail() async -> Bool {
        authErrorMessage = nil
        guard let user = Auth.auth().currentUser else {
            authErrorMessage = "You must be signed in to resend a verification email."
            return false
        }
        do {
            try await user.sendEmailVerification()
            return true
        } catch {
            authErrorMessage = Self.friendlyMessage(for: error)
            return false
        }
    }

    /// Reloads the Firebase user so `isEmailVerified` reflects the latest server state.
    public func refreshEmailVerificationStatus() async {
        guard let user = Auth.auth().currentUser else { return }
        try? await user.reload()
        applyUser(Auth.auth().currentUser)
    }

    // MARK: - Logout

    public func logout() {
        authErrorMessage = nil
        do {
            try Auth.auth().signOut()
            applyUser(nil)
        } catch {
            authErrorMessage = Self.friendlyMessage(for: error)
        }
    }

    // MARK: - Delete account

    public enum DeleteAccountError: Error, LocalizedError {
        case notSignedIn
        case needsPasswordReauth
        case needsAppleReauth
        case other(String)

        public var errorDescription: String? {
            switch self {
            case .notSignedIn:          return "You are not signed in."
            case .needsPasswordReauth:  return "Please re-enter your password to confirm account deletion."
            case .needsAppleReauth:     return "Please re-authenticate with Apple to confirm account deletion."
            case .other(let msg):       return msg
            }
        }
    }

    /// The Firebase provider ID of the *primary* sign-in method for the current user.
    /// Returns nil if signed out. Used by Delete Account UI to pick the right reauth flow.
    public var currentProviderID: String? {
        guard let user = Auth.auth().currentUser else { return nil }
        // Prefer non-firebase providers (apple.com, password, google.com). Firebase always
        // includes itself in providerData, so we look at the first non-firebase entry.
        for info in user.providerData {
            return info.providerID
        }
        return nil
    }

    /// Deletes the current Firebase user. Caller is responsible for wiping local data
    /// (InspectionStore.clearAllLocalData) after this succeeds.
    ///
    /// If Firebase requires a fresh login, this throws `.needsPasswordReauth` or
    /// `.needsAppleReauth` so the UI can prompt accordingly and then call
    /// `reauthenticateWithPassword(_:)` / `reauthenticateWithApple()` before retrying.
    public func deleteAccount() async throws {
        guard let user = Auth.auth().currentUser else { throw DeleteAccountError.notSignedIn }
        do {
            try await user.delete()
            applyUser(nil)
        } catch {
            let ns = error as NSError
            if ns.domain == AuthErrorDomain,
               let code = AuthErrorCode(rawValue: ns.code),
               code == .requiresRecentLogin {
                switch currentProviderID {
                case "apple.com":
                    throw DeleteAccountError.needsAppleReauth
                case "password":
                    throw DeleteAccountError.needsPasswordReauth
                default:
                    throw DeleteAccountError.other(Self.friendlyMessage(for: error))
                }
            }
            throw DeleteAccountError.other(Self.friendlyMessage(for: error))
        }
    }

    /// Re-authenticates the current email/password user so a sensitive operation
    /// (like account deletion) can proceed. Call `deleteAccount()` again on success.
    public func reauthenticateWithPassword(_ password: String) async throws {
        guard let user = Auth.auth().currentUser, let email = user.email else {
            throw DeleteAccountError.notSignedIn
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        do {
            try await user.reauthenticate(with: credential)
        } catch {
            throw DeleteAccountError.other(Self.friendlyMessage(for: error))
        }
    }

    /// Re-authenticates the current Apple-signed-in user by running a fresh Apple
    /// authorization and reauthenticating with the new credential.
    public func reauthenticateWithApple() async throws {
        guard let user = Auth.auth().currentUser else {
            throw DeleteAccountError.notSignedIn
        }
        let coordinator = SignInWithAppleCoordinator()
        do {
            let appleCredential = try await coordinator.start()
            guard let tokenData = appleCredential.identityToken,
                  let idTokenString = String(data: tokenData, encoding: .utf8) else {
                throw DeleteAccountError.other("Apple did not return an identity token.")
            }
            let firebaseCredential = OAuthProvider.appleCredential(
                withIDToken: idTokenString,
                rawNonce: coordinator.rawNonce,
                fullName: appleCredential.fullName
            )
            try await user.reauthenticate(with: firebaseCredential)
        } catch let error as DeleteAccountError {
            throw error
        } catch {
            if let asError = error as? ASAuthorizationError, asError.code == .canceled {
                throw DeleteAccountError.other("Apple re-authentication was cancelled.")
            }
            throw DeleteAccountError.other(Self.friendlyMessage(for: error))
        }
    }

    // MARK: - Validation

    /// Matches plan §4: min 12 chars, upper + lower + number + symbol.
    /// Returns nil if the password passes, otherwise a human-readable complaint.
    public static func validatePassword(_ password: String) -> String? {
        if password.count < 12 {
            return "Password must be at least 12 characters."
        }
        let hasUpper = password.rangeOfCharacter(from: .uppercaseLetters) != nil
        let hasLower = password.rangeOfCharacter(from: .lowercaseLetters) != nil
        let hasDigit = password.rangeOfCharacter(from: .decimalDigits) != nil
        let symbolSet = CharacterSet.punctuationCharacters.union(.symbols)
        let hasSymbol = password.rangeOfCharacter(from: symbolSet) != nil
        if !hasUpper { return "Password must include an uppercase letter." }
        if !hasLower { return "Password must include a lowercase letter." }
        if !hasDigit { return "Password must include a number." }
        if !hasSymbol { return "Password must include a symbol (e.g. !@#$%)." }
        return nil
    }

    public static func isValidEmail(_ email: String) -> Bool {
        // Simple, permissive check. Firebase rejects the truly malformed ones server-side.
        let pattern = #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#
        return email.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Error mapping

    private static func friendlyMessage(for error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == AuthErrorDomain,
              let code = AuthErrorCode(rawValue: ns.code) else {
            return ns.localizedDescription
        }
        switch code {
        case .invalidEmail:                 return "That email address isn’t valid."
        case .emailAlreadyInUse:            return "An account with that email already exists."
        case .weakPassword:                 return "That password is too weak."
        case .wrongPassword, .invalidCredential:
                                            return "Incorrect email or password."
        case .userNotFound:                 return "No account found for that email."
        case .userDisabled:                 return "This account has been disabled. Contact support@nexgenspec.com."
        case .networkError:                 return "Network error. Check your connection and try again."
        case .tooManyRequests:              return "Too many attempts. Please wait a minute and try again."
        case .requiresRecentLogin:          return "For security, please sign in again before making this change."
        case .operationNotAllowed:          return "Email/password sign-in is not enabled. Contact support@nexgenspec.com."
        default:                            return ns.localizedDescription
        }
    }
}
