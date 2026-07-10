//
//  RecommendationSettings.swift
//  Vision_clother
//
//  Privacy opt-out for the LLM-as-Recommender path (PRD.md §3.8's privacy
//  note, the 2026-07-10 reversal — see docs/decisions/resolved-v1.md). When
//  disabled, `DailyAssistantViewModel.requestOutfitIdeas()` skips the
//  recommendation call entirely and goes straight to the deterministic
//  fallback (`Domain/OutfitRecommendationEngine.swift`) — no wardrobe
//  catalog or style profile leaves the device in that mode.
//
//  A single UserDefaults-backed flag, not SwiftData — this is a device-local
//  preference with no sync/query needs, matching the simplicity of a plain
//  toggle rather than warranting a persistence-layer model.
//

import Foundation

enum RecommendationSettings {
    private static let key = "com.visionclother.useAIRecommendations"

    /// Defaults to `true` (AI recommendations enabled) — matches this
    /// feature's primary path being the LLM recommender.
    static var useAIRecommendations: Bool {
        get {
            guard UserDefaults.standard.object(forKey: key) != nil else { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
