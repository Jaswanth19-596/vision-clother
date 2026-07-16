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
        return URL(string: "https://5747-2601-243-c884-d480-1da0-d138-6153-810f.ngrok-free.app/visionclother/us-central/api")!

        #else
        return URL(string: "https://REPLACE_WITH_YOUR_DEPLOYED_FUNCTION_URL/api")!
        #endif
    }()

    static var openRouterChatURL: URL { baseURL.appendingPathComponent("openrouter/chat") }
    static var openRouterImagesURL: URL { baseURL.appendingPathComponent("openrouter/images") }
    static var pexelsSearchURL: URL { baseURL.appendingPathComponent("pexels/search") }
}
