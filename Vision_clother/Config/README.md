# Config/

## `GoogleService-Info.plist` (Firebase — required)

Not present in this repo yet — download it from the Firebase console after registering the iOS app (see `backend/README.md`'s one-time setup) and place it here as `Config/GoogleService-Info.plist`. Unlike `Secrets.plist` below, **this file is not a secret** and is safe to commit — it's Firebase's public client configuration, not a credential. It's what `FirebaseBootstrap.configure()` (`Config/FirebaseBootstrap.swift`) reads at launch.

## `Secrets.plist` (legacy — superseded by the Firebase proxy)

`Secrets.plist` (gitignored) previously held the OpenRouter/Pexels keys read directly by `Services/APIKeys.swift`. That file has been removed — every OpenRouter/Pexels call now goes through the Firebase Cloud Functions proxy (`backend/`), which holds those keys server-side instead (see `docs/backend/architecture.md`). `Secrets.example.plist` is kept as an empty template in case a future provider integration needs a dev-only client-side key again, but nothing in the app currently reads it.

The app's mock/real service gate (`Vision_clother/Vision_clother/AppWiring/ServiceFactory.swift`) now checks `AuthService.shared.isSignedIn` (Firebase Auth via Sign in with Apple — `Services/AuthService.swift`) instead of key presence. With no Firebase project configured and no sign-in, the app falls back to the `Mock*` services exactly as before, so it's still fully interactive in Simulator out of the box.

## `ModelConfig.swift`

Unchanged — still the single place to swap OpenRouter model IDs and edit prompt text (`Services/CLAUDE.md`).

## `ProxyConfig.swift`

Base URL of the Firebase proxy — points at the local emulator in DEBUG builds, the deployed function URL in release. See `backend/README.md`.
