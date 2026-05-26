//
//  SignInWithAppleCoordinator.swift
//  NexGenSpec
//
//  Bridges ASAuthorizationController (UIKit-style delegate API) into an async
//  Swift call. Holds the raw nonce so the resulting Apple ID token can be
//  exchanged with Firebase. Single use: instantiate, await `start()`, discard.
//

import Foundation
import AuthenticationServices
import CryptoKit

@MainActor
final class SignInWithAppleCoordinator: NSObject,
                                        ASAuthorizationControllerDelegate,
                                        ASAuthorizationControllerPresentationContextProviding {

    /// Random raw nonce; the SHA256 of this is sent to Apple, the raw value is
    /// sent to Firebase. Firebase verifies the binding to prevent replay.
    let rawNonce: String
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    private init(rawNonce: String) {
        self.rawNonce = rawNonce
        super.init()
    }

    /// Creates a coordinator with a freshly generated secure nonce. Throws
    /// (rather than crashing) if the system secure RNG is unavailable — see
    /// `makeNonce`. Use this instead of a plain initializer.
    static func make() throws -> SignInWithAppleCoordinator {
        SignInWithAppleCoordinator(rawNonce: try makeNonce())
    }

    func start() async throws -> ASAuthorizationAppleIDCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(rawNonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            controller.performRequests()
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: NSError(
                domain: "SignInWithApple",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected credential type from Apple."]
            ))
            continuation = nil
            return
        }
        continuation?.resume(returning: credential)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Find the active foreground window scene's key window. Falls back to a
        // fresh window if none is available (shouldn't happen in practice).
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    // MARK: - Nonce helpers
    //
    // Exposed at module-internal scope so the SignInWithAppleButton SwiftUI
    // wrapper in LoginView can produce the same nonce shape (raw + SHA256
    // hashed) without duplicating the implementation. Reauth still uses the
    // coordinator path; new sign-in goes through SignInWithAppleButton.

    /// Thrown when the system secure RNG is unavailable. Realistically never
    /// happens on iOS, but `SecRandomCopyBytes` can fail in principle, so we
    /// surface it as a handled error instead of crashing the sign-in flow
    /// (`precondition` is NOT stripped from release builds).
    enum NonceError: Error { case secureRandomUnavailable }

    static func makeNonce(length: Int = 32) throws -> String {
        precondition(length > 0)
        let charset: [Character] =
            Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remaining = length
        while remaining > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            guard status == errSecSuccess else {
                throw NonceError.secureRandomUnavailable
            }
            for byte in randoms where remaining > 0 {
                if byte < charset.count {
                    result.append(charset[Int(byte) % charset.count])
                    remaining -= 1
                }
            }
        }
        return result
    }

    static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.map { String(format: "%02x", $0) }.joined()
    }
}
