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
    static func current() async throws -> [String: String] {
        do {
            let token = try await AuthService.shared.currentIDToken()
            return ["Authorization": "Bearer \(token)", "X-Request-Id": AppLog.newRequestID()]
        } catch {
            AppLog.error(.network, "ProxyAuthHeaders.current: failed to build auth header — \(String(describing: error))")
            throw error
        }
    }
}
