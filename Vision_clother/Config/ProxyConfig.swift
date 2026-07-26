//
//  ProxyConfig.swift
//  Vision_clother
//
//  Base URLs of the three Firebase Cloud Functions (backend/README.md,
//  backend/functions/src/index.ts) that front every OpenRouter/Pexels call
//  and the account/payments routes — see Services/ProxyAuthHeaders.swift
//  and each provider service's `endpoint` property. Split by cost/latency
//  profile (docs/backend/architecture.md's "Cloud Functions" section):
//  `proxyApi` (cheap passthrough), `heavyApi` (image generation, long
//  timeout), `accountApi` (payments/account management). Each is its own
//  deployed Cloud Run service with its own URL — there is no longer a
//  single shared base URL.
//

import Foundation

enum ProxyConfig {
    /// Quota/usage tracking lives in real, persistent Firestore behind
    /// these deployed Cloud Functions HTTPS triggers (`backend/README.md`).
    /// DEBUG previously pointed at a local emulator tunneled through ngrok;
    /// that setup's Firestore is ephemeral and gets wiped on every emulator
    /// restart, which is what made quota look like it was "resetting"
    /// during normal testing. Swap back to a `localhost`/ngrok URL here
    /// only for offline backend-code iteration, and start the emulator
    /// with `--import`/`--export-on-exit` if you do, so local quota state
    /// survives restarts.
    ///
    /// TODO(post-split-deploy): replace these three placeholders with the
    /// actual per-function URLs printed by `firebase deploy --only functions`
    /// (or the Firebase console) after deploying the 3-function split —
    /// see the deploy steps in `backend/README.md`. Until then this still
    /// points every base at the old monolithic `api` URL, which will 404
    /// on every route once the split is deployed and `api` is deleted.
    private static let proxyBaseURL = URL(string: "https://us-central1-visionclother.cloudfunctions.net/proxyApi")!
    private static let heavyBaseURL = URL(string: "https://us-central1-visionclother.cloudfunctions.net/heavyApi")!
    private static let accountBaseURL = URL(string: "https://us-central1-visionclother.cloudfunctions.net/accountApi")!

    /// `proxyApi` — `/openrouter/chat`.
    static var openRouterChatURL: URL { proxyBaseURL.appendingPathComponent("openrouter/chat") }
    /// `proxyApi` — credit-gated alias of `openRouterChatURL` for outfit
    /// recommendations only (`backend/functions/src/middleware/creditGate.ts`'s
    /// `RECOMMENDATION` operation) — same pass-through handler, different
    /// path so the backend can gate it without parsing the request body.
    static var openRouterRecommendURL: URL { proxyBaseURL.appendingPathComponent("openrouter/recommend") }
    /// `heavyApi` — credit-gated alias of `openRouterChatURL` for try-on
    /// rendering only (`creditGate.ts`'s `IMAGE_GEN` operation, hard-capped at
    /// 0 for guests) — see `openRouterRecommendURL`'s doc comment. Moved off
    /// `proxyApi` because image generation regularly exceeds `proxyApi`'s 15s
    /// timeout.
    static var openRouterTryOnURL: URL { heavyBaseURL.appendingPathComponent("openrouter/tryon") }
    /// `heavyApi` — see `openRouterTryOnURL`.
    static var openRouterImagesURL: URL { heavyBaseURL.appendingPathComponent("openrouter/images") }
    /// `proxyApi`.
    static var pexelsSearchURL: URL { proxyBaseURL.appendingPathComponent("pexels/search") }
    /// `accountApi` — backed by `backend/functions/src/routes/accountDelete.ts`.
    /// See `Services/AccountDeletionService.swift`.
    static var accountDeleteURL: URL { accountBaseURL.appendingPathComponent("account/delete") }
    /// `accountApi` — backed by `backend/functions/src/routes/iapVerify.ts` —
    /// verifies a StoreKit 2 transaction JWS server-side and credits the
    /// purchased balance on `users/{uid}/meta/usage`. See
    /// `Services/IAPVerificationService.swift`.
    static var iapVerifyURL: URL { accountBaseURL.appendingPathComponent("iap/verify") }
    /// `accountApi` — backed by `backend/functions/src/routes/entitlementLimits.ts` —
    /// resolves the caller's tier into concrete recommendation/try-on/item
    /// caps server-side, so the client never hardcodes its own copy of
    /// those numbers. See `Services/EntitlementLimitsService.swift`.
    static var entitlementLimitsURL: URL { accountBaseURL.appendingPathComponent("entitlement/limits") }
    /// `accountApi` — backed by `backend/functions/src/routes/analyticsConfig.ts` —
    /// resolves Analytics & Insights confidence/unlock thresholds
    /// server-side. See `Services/AnalyticsConfigService.swift`.
    static var analyticsConfigURL: URL { accountBaseURL.appendingPathComponent("analytics/config") }
}
