//
//  AuthService.swift
//  Vision_clother
//
//  Guest-first: `ensureGuestSession()` starts a Firebase Anonymous session
//  at launch so every install gets a working (if capped, see
//  `backend/functions/src/middleware/quota.ts`) AI session with no sign-in
//  wall. Google Sign-In + Phone Number Auth *link* that anonymous session to
//  a real credential rather than replacing it, keeping the guest's local
//  closet. Sign in with Apple is deferred (needs a paid Apple Developer
//  account for the capability) — see docs/decisions/resolved-v1.md.
//  `ServiceFactory` gates every OpenRouter/Pexels-backed service on
//  `isSignedIn` (replacing the old API-key-presence gate now that those
//  calls go through the Firebase proxy — see Services/ProxyAuthHeaders.swift);
//  that's true for guests too by design, since `isAnonymous` (not
//  `isSignedIn`) is what actually distinguishes guest vs. linked tiers now.
//  `currentIDToken()` supplies the bearer token every proxied request
//  carries.
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
    /// Which account is signed in, not just whether one is — `Data/WardrobeSyncCoordinator.swift`
    /// subscribes to changes here (not `isSignedIn`) to react to account
    /// switches, not just sign-in/sign-out transitions.
    @Published private(set) var uid: String?
    /// True for an unlinked Firebase Anonymous session (guest-first —
    /// `ensureGuestSession()`). `isSignedIn` stays true for guests too
    /// (`Auth.auth().currentUser != nil`), by design: `ServiceFactory`'s
    /// mock/real gating on `isSignedIn` is exactly "has a working AI
    /// session," which is true for guests. `isAnonymous` is the finer-grained
    /// flag UI (`AccountSectionView`, the try-on guest guard) needs.
    @Published private(set) var isAnonymous: Bool
    /// Set when `ensureGuestSession()`'s `signInAnonymously()` call fails
    /// (e.g. Anonymous sign-in not enabled for this Firebase project, or no
    /// network at first launch) — surfaced by `AccountSectionView` so a
    /// silently-never-signed-in session (which otherwise looks identical to
    /// "browsing as guest" everywhere else in the app) has a visible cause
    /// and a manual retry, instead of every AI feature silently mocking
    /// forever with no explanation.
    @Published private(set) var guestSessionError: String?
    /// Best-effort human-readable label for the signed-in identity (email,
    /// then phone, then Firebase's `displayName`) — `nil` for guests/no
    /// session. Used by the Profile tab's account card so "Signed in" isn't
    /// just a bare status word.
    @Published private(set) var displayLabel: String?

    private override init() {
        let user = Auth.auth().currentUser
        isSignedIn = user != nil
        uid = user?.uid
        isAnonymous = user?.isAnonymous ?? false
        displayLabel = Self.displayLabel(for: user)
        super.init()
        AppLog.info(.auth, "init: currentUser=\(Auth.auth().currentUser?.uid ?? "nil") isAnonymous=\(isAnonymous)")
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            AppLog.notice(.auth, "authStateDidChange: uid=\(user?.uid ?? "nil") isAnonymous=\(user?.isAnonymous ?? false)")
            self?.isSignedIn = user != nil
            self?.uid = user?.uid
            self?.isAnonymous = user?.isAnonymous ?? false
            self?.displayLabel = Self.displayLabel(for: user)
        }
        Task { [weak self] in await self?.ensureGuestSession() }
    }

    private static func displayLabel(for user: User?) -> String? {
        guard let user, !user.isAnonymous else { return nil }
        return user.email ?? user.phoneNumber ?? user.displayName
    }

    /// Guest-first entry point — kicked fire-and-forget from `init` so a
    /// fresh install gets a working AI session with no sign-in wall. Never
    /// throws out: a Firebase-project-less dev environment or an offline
    /// first launch stays exactly as interactive as today (mocks apply with
    /// zero Firebase configured, per `Config/README.md`). Returns the
    /// resulting uid so callers that need it deterministically (e.g.
    /// `Data/WardrobeSyncCoordinator.swift`'s `performExplicitSignOut`)
    /// don't have to wait a beat for `$uid`'s listener-driven publish.
    @discardableResult
    func ensureGuestSession() async -> String? {
        if let existing = Auth.auth().currentUser {
            AppLog.debug(.auth, "ensureGuestSession: already have a session, uid=\(existing.uid)")
            return existing.uid
        }
        AppLog.info(.auth, "ensureGuestSession: starting signInAnonymously")
        do {
            let result = try await Auth.auth().signInAnonymously()
            guestSessionError = nil
            AppLog.info(.auth, "ensureGuestSession: succeeded, uid=\(result.user.uid)")
            return result.user.uid
        } catch {
            guestSessionError = error.localizedDescription
            AppLog.error(.auth, "ensureGuestSession: failed — \(error.localizedDescription)")
            return nil
        }
    }

    @MainActor
    func signInWithGoogle() async throws {
        AppLog.info(.auth, "signInWithGoogle: starting")
        guard let presentingViewController = Self.rootViewController() else {
            AppLog.error(.auth, "signInWithGoogle: no presenting view controller")
            throw AuthServiceError.missingPresentingViewController
        }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController)
            guard let idToken = result.user.idToken?.tokenString else {
                throw AuthServiceError.missingGoogleIDToken
            }

            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            try await signInOrLink(with: credential)
            AppLog.info(.auth, "signInWithGoogle: succeeded, uid=\(Auth.auth().currentUser?.uid ?? "nil")")
        } catch {
            AppLog.error(.auth, "signInWithGoogle: failed — \(String(describing: error))")
            throw error
        }
    }

    /// Step 1 of phone sign-in — sends an SMS code (or triggers Firebase's
    /// Safari-hosted reCAPTCHA challenge first, since no APNs auth key is
    /// configured to skip it silently — see docs/decisions/resolved-v1.md).
    /// Returns a verification ID to pass back into `confirmPhoneSignIn`.
    func startPhoneSignIn(phoneNumber: String) async throws -> String {
        AppLog.info(.auth, "startPhoneSignIn: requesting SMS code (number length=\(phoneNumber.count))")
        do {
            let verificationID = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
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
            AppLog.info(.auth, "startPhoneSignIn: SMS code sent")
            return verificationID
        } catch {
            AppLog.error(.auth, "startPhoneSignIn: failed — \(String(describing: error))")
            throw error
        }
    }

    /// Step 2 of phone sign-in — completes sign-in with the SMS code the user
    /// received for the verification ID `startPhoneSignIn` returned.
    func confirmPhoneSignIn(verificationID: String, code: String) async throws {
        AppLog.info(.auth, "confirmPhoneSignIn: starting")
        let credential = PhoneAuthProvider.provider().credential(
            withVerificationID: verificationID,
            verificationCode: code
        )
        do {
            try await signInOrLink(with: credential)
            AppLog.info(.auth, "confirmPhoneSignIn: succeeded, uid=\(Auth.auth().currentUser?.uid ?? "nil")")
        } catch {
            AppLog.error(.auth, "confirmPhoneSignIn: failed — \(String(describing: error))")
            throw error
        }
    }

    /// Guest-first linking: an anonymous session signing in with a real
    /// credential should *become* that account (keeping its local closet),
    /// not get replaced by a brand-new sign-in. Falls back to a plain
    /// `signIn(with:)` when the credential already belongs to a different,
    /// real account elsewhere (`credentialAlreadyInUse`) — that's an
    /// ordinary different-account switch as far as `WardrobeSyncCoordinator`
    /// is concerned (drain-before-wipe already handles it), so the guest's
    /// unsynced local edits are lost the same way any unsynced switch
    /// already loses them. A guest-data-merge flow is out of scope for v1.
    private func signInOrLink(with credential: AuthCredential) async throws {
        if let currentUser = Auth.auth().currentUser, currentUser.isAnonymous {
            do {
                try await currentUser.link(with: credential)
                AppLog.info(.auth, "signInOrLink: linked guest session, uid=\(currentUser.uid)")
                return
            } catch let error as NSError where error.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
                AppLog.notice(.auth, "signInOrLink: credential already in use elsewhere — falling back to plain sign-in")
            }
        }
        try await Auth.auth().signIn(with: credential)
    }

    func signOut() throws {
        AppLog.notice(.auth, "signOut: uid=\(Auth.auth().currentUser?.uid ?? "nil")")
        try Auth.auth().signOut()
        GIDSignIn.sharedInstance.signOut()
    }

    /// Fresh (Firebase SDK auto-refreshes as needed) ID token for every
    /// proxy request — see `Services/ProxyAuthHeaders.swift`.
    func currentIDToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            AppLog.error(.auth, "currentIDToken: no current user")
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
