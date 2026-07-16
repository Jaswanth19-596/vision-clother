//
//  AuthService.swift
//  Vision_clother
//
//  Google Sign-In + Phone Number Auth -> Firebase Auth. Sign in with Apple is
//  deferred (needs a paid Apple Developer account for the capability) — see
//  docs/decisions/resolved-v1.md. `ServiceFactory` gates every
//  OpenRouter/Pexels-backed service on `isSignedIn` (replacing the old
//  API-key-presence gate now that those calls go through the Firebase proxy
//  — see Services/ProxyAuthHeaders.swift), and `currentIDToken()` supplies
//  the bearer token every proxied request carries.
//

import Combine
import FirebaseAuth
import Foundation
import GoogleSignIn
import UIKit

enum AuthServiceError: Error, LocalizedError {
    case notSignedIn
    case missingPresentingViewController
    case missingGoogleIDToken
    case missingVerificationID

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to use Vision Clother's AI styling features."
        case .missingPresentingViewController:
            return "Couldn't find a screen to present sign-in from — try again."
        case .missingGoogleIDToken:
            return "Google didn't return an identity token."
        case .missingVerificationID:
            return "Sign-in state was lost — request a new code."
        }
    }
}

final class AuthService: NSObject, ObservableObject {
    static let shared = AuthService()

    @Published private(set) var isSignedIn: Bool

    private override init() {
        isSignedIn = Auth.auth().currentUser != nil
        super.init()
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            self?.isSignedIn = user != nil
        }
    }

    @MainActor
    func signInWithGoogle() async throws {
        guard let presentingViewController = Self.rootViewController() else {
            throw AuthServiceError.missingPresentingViewController
        }

        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController)
        guard let idToken = result.user.idToken?.tokenString else {
            throw AuthServiceError.missingGoogleIDToken
        }

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        try await Auth.auth().signIn(with: credential)
    }

    /// Step 1 of phone sign-in — sends an SMS code (or triggers Firebase's
    /// Safari-hosted reCAPTCHA challenge first, since no APNs auth key is
    /// configured to skip it silently — see docs/decisions/resolved-v1.md).
    /// Returns a verification ID to pass back into `confirmPhoneSignIn`.
    func startPhoneSignIn(phoneNumber: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            PhoneAuthProvider.provider().verifyPhoneNumber(phoneNumber, uiDelegate: nil) { verificationID, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let verificationID {
                    continuation.resume(returning: verificationID)
                } else {
                    continuation.resume(throwing: AuthServiceError.missingVerificationID)
                }
            }
        }
    }

    /// Step 2 of phone sign-in — completes sign-in with the SMS code the user
    /// received for the verification ID `startPhoneSignIn` returned.
    func confirmPhoneSignIn(verificationID: String, code: String) async throws {
        let credential = PhoneAuthProvider.provider().credential(
            withVerificationID: verificationID,
            verificationCode: code
        )
        try await Auth.auth().signIn(with: credential)
    }

    func signOut() throws {
        try Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    /// Fresh (Firebase SDK auto-refreshes as needed) ID token for every
    /// proxy request — see `Services/ProxyAuthHeaders.swift`.
    func currentIDToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AuthServiceError.notSignedIn
        }
        return try await user.getIDToken()
    }

    /// Single-window app (RootTabView hosted in one WindowGroup, see
    /// Vision_clotherApp.swift) — safe to grab the first connected scene's
    /// key window rather than threading a window reference through.
    @MainActor
    private static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }
}
