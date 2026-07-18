//
//  ProxyConfig.swift
//  Vision_clother
//
//  Base URL of the Firebase Cloud Functions proxy (backend/README.md) that
//  fronts every OpenRouter/Pexels call — see Services/ProxyAuthHeaders.swift
//  and each provider service's `endpoint` property.
//

import Foundation

enum ProxyConfig {
    /// Both configurations point at the deployed Cloud Functions HTTPS
    /// trigger (`backend/README.md`) — quota/usage tracking lives in real,
    /// persistent Firestore there. DEBUG previously pointed at a local
    /// emulator tunneled through ngrok; that setup's Firestore is ephemeral
    /// and gets wiped on every emulator restart, which is what made quota
    /// look like it was "resetting" during normal testing. Swap back to a
    /// `localhost`/ngrok URL here only for offline backend-code iteration,
    /// and start the emulator with `--import`/`--export-on-exit` if you do,
    /// so local quota state survives restarts.
    static let baseURL: URL = {
        #if DEBUG
        return URL(string: "https://api-z3sgjy64ga-uc.a.run.app")!
        #else
        return URL(string: "https://api-z3sgjy64ga-uc.a.run.app")!
        #endif
    }()

    static var openRouterChatURL: URL { baseURL.appendingPathComponent("openrouter/chat") }
    /// Quota'd alias of `openRouterChatURL` for outfit recommendations only
    /// (`backend/functions/src/middleware/quota.ts`'s `"recommendation"`
    /// feature) — same pass-through handler, different path so the backend
    /// can gate it without parsing the request body.
    static var openRouterRecommendURL: URL { baseURL.appendingPathComponent("openrouter/recommend") }
    /// Quota'd alias of `openRouterChatURL` for try-on rendering only
    /// (`quota.ts`'s `"tryOn"` feature, 0 for guests) — see
    /// `openRouterRecommendURL`'s doc comment.
    static var openRouterTryOnURL: URL { baseURL.appendingPathComponent("openrouter/tryon") }
    static var openRouterImagesURL: URL { baseURL.appendingPathComponent("openrouter/images") }
    static var pexelsSearchURL: URL { baseURL.appendingPathComponent("pexels/search") }
    /// Backed by `backend/functions/src/routes/accountDelete.ts` — see
    /// `Services/AccountDeletionService.swift`.
    static var accountDeleteURL: URL { baseURL.appendingPathComponent("account/delete") }
    /// Backed by `backend/functions/src/routes/iapVerify.ts` — verifies a
    /// StoreKit 2 transaction JWS server-side and credits the purchased
    /// balance on `users/{uid}/meta/usage`. See
    /// `Services/IAPVerificationService.swift`.
    static var iapVerifyURL: URL { baseURL.appendingPathComponent("iap/verify") }
    /// Backed by `backend/functions/src/routes/entitlementLimits.ts` —
    /// resolves the caller's tier into concrete recommendation/try-on/item
    /// caps server-side, so the client never hardcodes its own copy of
    /// those numbers. See `Services/EntitlementLimitsService.swift`.
    static var entitlementLimitsURL: URL { baseURL.appendingPathComponent("entitlement/limits") }
}
