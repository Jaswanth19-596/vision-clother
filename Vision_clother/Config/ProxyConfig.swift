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
    /// DEBUG builds point at the local Firebase emulator
    /// (`backend/README.md`'s `npm run serve`); release builds point at the
    /// deployed Cloud Functions HTTPS trigger — fill in the real project ID /
    /// function URL after `firebase deploy` (see `backend/README.md`).
    static let baseURL: URL = {
        #if DEBUG
        // return URL(string: "http://localhost:5001/REPLACE_WITH_YOUR_FIREBASE_PROJECT_ID/us-central1/api")!
        return URL(string: "https://4c94-2601-243-c884-d480-ac0a-b28-d01a-a91a.ngrok-free.app/visionclother/us-central1/api")!

        #else
        return URL(string: "https://REPLACE_WITH_YOUR_DEPLOYED_FUNCTION_URL/api")!
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
}
