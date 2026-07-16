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
    }
}
