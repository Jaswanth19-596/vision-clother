//
//  ProxyAuthHeaders.swift
//  Vision_clother
//
//  Every OpenRouter/Pexels-backed service calls the Firebase proxy
//  (`backend/functions`) instead of the provider directly — this builds the
//  header `backend/functions/src/app.ts`'s middleware chain requires on
//  every request. Callers map a thrown error here onto their own existing
//  `.missingAPIKey` case, preserving the pre-proxy error contract (see each
//  service's `Error` enum) even though the failure now means "not signed in"
//  rather than "no key in Secrets.plist".
//

import Foundation

enum ProxyAuthHeaders {
    /// `X-Request-Id` (generated fresh per call, `AppLog.newRequestID()`) is
    /// the join key between this client-side call's `AppLog` lines and the
    /// matching `backend/functions/src/app.ts` request-logging middleware's
    /// Cloud Logging line for the same request — echoed back verbatim by the
    /// backend so a caller that logs it here can grep both sides by the same
    /// short id.
    ///
    /// `X-Idempotency-Key` (a fresh UUID, same one-per-call cadence as
    /// `X-Request-Id` above) is required by `backend/functions/src/middleware/idempotency.ts`'s
    /// `idempotencyGate` on the three quota-gated OpenRouter routes
    /// (`/openrouter/recommend`, `/openrouter/tryon`, `/openrouter/images`)
    /// — it's what lets that middleware tell "the app retried this exact
    /// attempt after a timeout/kill" (safe to dedupe) apart from "this is a
    /// deliberately new attempt" (e.g. `OutfitRecommendationService`'s
    /// structured→unstructured fallback, a second call to `current()` with a
    /// different model/payload, which must get its own key). Harmless on
    /// routes that don't require it (`/openrouter/chat`, `/pexels/search`,
    /// the account routes) — those simply ignore the extra header.
    static func current() async throws -> [String: String] {
        do {
            let token = try await AuthService.shared.currentIDToken()
            return [
                "Authorization": "Bearer \(token)",
                "X-Request-Id": AppLog.newRequestID(),
                "X-Idempotency-Key": UUID().uuidString,
            ]
        } catch {
            AppLog.error(.network, "ProxyAuthHeaders.current: failed to build auth header — \(String(describing: error))")
            throw error
        }
    }
}
