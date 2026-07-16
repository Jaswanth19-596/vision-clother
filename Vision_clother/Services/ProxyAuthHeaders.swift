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
    static func current() async throws -> [String: String] {
        ["Authorization": "Bearer \(try await AuthService.shared.currentIDToken())"]
    }
}
