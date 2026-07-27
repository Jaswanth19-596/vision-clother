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
    /// `X-Request-Id` is the join key between this client-side call's
    /// `AppLog` lines and the matching `backend/functions/src/app.ts`
    /// request-logging middleware's Cloud Logging line for the same request
    /// — echoed back verbatim by the backend so a caller that logs it can
    /// grep both sides by the same short id. **Callers must pass the exact
    /// `requestID` they already minted via `AppLog.newRequestID()` for their
    /// own log lines** — this used to generate a second, different id
    /// internally, which silently broke that join (the id printed in the
    /// on-device log was never the one actually sent to the server, so the
    /// two logs couldn't be correlated at all).
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
    static func current(requestID: String) async throws -> [String: String] {
        do {
            let token = try await AuthService.shared.currentIDToken()
            return [
                "Authorization": "Bearer \(token)",
                "X-Request-Id": requestID,
                "X-Idempotency-Key": UUID().uuidString,
            ]
        } catch {
            AppLog.error(.network, "ProxyAuthHeaders.current: failed to build auth header — \(String(describing: error))")
            throw error
        }
    }
}
