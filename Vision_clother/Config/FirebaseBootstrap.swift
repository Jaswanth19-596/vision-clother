//
//  FirebaseBootstrap.swift
//  Vision_clother
//
//  Configures Firebase and hands GoogleSignIn-iOS the OAuth client ID
//  Firebase already knows about (from GoogleService-Info.plist) so
//  `AuthService.signInWithGoogle()` doesn't need to duplicate it.
//  App Check (App Attest) is deferred — it needs a paid Apple Developer
//  account to configure, same blocker as Sign in with Apple; see
//  docs/decisions/resolved-v1.md.
//

import FirebaseCore
import GoogleSignIn

enum FirebaseBootstrap {
    static func configure() {
        FirebaseApp.configure()

        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }

        // Best-effort, fire-and-forget — `RemoteConfigManager`'s registered
        // defaults (`Config/RemoteConfigManager.swift`) already make every
        // AI model/payload reader correct before this ever completes, so
        // nothing needs to await it. Constructing `.shared` also registers
        // those defaults synchronously, which must happen before the first
        // service reads `Config/ModelConfig.swift`'s Remote-Config-backed
        // properties.
        Task {
            await RemoteConfigManager.shared.fetchAndActivate()
        }
    }
}
