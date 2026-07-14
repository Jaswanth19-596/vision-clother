//
//  OutfitRecommendationEngine.swift
//  Vision_clother
//
//  Outfit scoring engine: pure function of (items, constraints, feedback
//  history) → Double score in 0…1. Used by `OutfitRecommendationValidator`
//  to re-score LLM-proposed outfits and by feedback-learning modules. No
//  I/O; the caller (a ViewModel) loads `FeedbackHistory` from SwiftData and
//  passes it in — keeping this module isolated and mockable per CLAUDE.md §4.
//

import Foundation

/// Order-independent key for pair-level feedback lookups, matching the
/// ordering convention in `Models/FeedbackEvent.swift`.
struct PairKey: Hashable {
    let a: UUID
    let b: UUID

    init(_ x: UUID, _ y: UUID) {
        if x.uuidString < y.uuidString {
            a = x
            b = y
        } else {
            a = y
            b = x
        }
    }
}

/// Pre-aggregated feedback counts, computed once from SwiftData by the
/// caller. Keeps the scoring/engine layer free of persistence concerns.
struct FeedbackHistory {
    /// pair key -> (decay-weighted sum of liked-together events, decay-weighted sum of all evaluations)
    var pairFeedback: [PairKey: (likes: Double, total: Double)] = [:]
    /// item id -> (decay-weighted sum of liked events, decay-weighted sum of all evaluations)
    var itemFeedback: [UUID: (likes: Double, total: Double)] = [:]
    /// Learned color/pattern/formality taste, built from `ItemRating` history
    /// (see `Domain/AttributePreferenceProfile.swift`). Defaults to an empty
    /// profile — every affinity then reads as neutral 0.5, so
    /// `affinityBonus` is 0 and scoring is unchanged from before this
    /// feature existed.
    var attributeProfile: AttributePreferenceProfile = AttributePreferenceProfile()
    /// Time-decayed net-negative-feedback signal for an *exact* outfit item
    /// combination, keyed by the full set of item ids in that outfit
    /// (top+bottom+footwear+optional outerwear) rather than any outfit ID —
    /// a freshly generated `OutfitCombination` has no durable id of its own
    /// until saved, so whole-outfit dislike history can only be looked up by
    /// which items it actually contains. Positive values mean net dislike;
    /// built from `SavedCombination` <-> `OutfitFeedback` joins in
    /// `Data/WardrobeRepository.swift`. Empty by default, so scoring is
    /// unchanged when no such history exists.
    var outfitNegativeSignalByItemSet: [Set<UUID>: Double] = [:]
    /// Time-decayed net-negative-feedback signal per item, folding
    /// `ItemFeedback`/`ItemRating`/favorite-weakest-item history — positive
    /// means net dislike. Distinct from `itemFeedback` above (a decay-weighted
    /// like/total sum used by `PairCompatibilityScoring.itemPreference`) — this
    /// is a separate signal `OutfitRecommendationEngine.outfitScore` reads for
    /// the negative-feedback penalty. Empty by default, so scoring is
    /// unchanged when no such history exists.
    var itemNegativeSignal: [UUID: Double] = [:]
}

enum OutfitRecommendationEngine {
    /// `Score_Total = mean(pairwise P(Pair|History)) + mean(Preference(Item))
    /// + mean(AttributeAffinityBonus(Item)) + FormalityPenalty + WeatherPenalty + ProfileColorsBonus + NegativeFeedbackPenalty`
    /// across every item in the combination — applying the Decision Rubric (added 2026-07-10).
    static func outfitScore(
        for items: [WardrobeItem],
        constraints: StyleConstraints? = nil,
        profile: UserStyleProfile? = nil,
        weather: WeatherContext? = nil,
        history: FeedbackHistory
    ) -> Double {
        let pairs = PairCompatibilityScoring.pairwiseCombinations(items)
        let pairScores: [Double] = pairs.map { a, b in
            let feedback = history.pairFeedback[PairKey(a.id, b.id)]
            let prior = PairCompatibilityScoring.aestheticPrior(a, b)
            return PairCompatibilityScoring.pairCompatibilityScore(
                aestheticPrior: prior,
                feedbackSum: feedback?.likes ?? 0,
                evaluationCount: feedback?.total ?? 0
            )
        }
        let meanPairScore = pairScores.isEmpty ? 0 : pairScores.reduce(0, +) / Double(pairScores.count)

        let preferenceScores: [Double] = items.map { item in
            let counts = history.itemFeedback[item.id]
            let likes = counts?.likes ?? 0
            let total = counts?.total ?? 0
            return PairCompatibilityScoring.itemPreference(likeCount: likes, dislikeCount: total - likes)
        }
        let meanPreference = preferenceScores.isEmpty ? 0 : preferenceScores.reduce(0, +) / Double(preferenceScores.count)

        let affinityBonuses: [Double] = items.map { history.attributeProfile.affinityBonus(for: $0) }
        let meanAffinityBonus = affinityBonuses.isEmpty ? 0 : affinityBonuses.reduce(0, +) / Double(affinityBonuses.count)

        // Read Disliked Signals (added 2026-07-11): previously `likedOverall`
        // and `.normalizedRating` were collected but never read by scoring —
        // a disliked outfit or item could keep resurfacing indefinitely.
        // Penalize rather than hard-drop, matching the "bias, not filter"
        // posture the rest of this file follows.
        var negativeFeedbackPenalty: Double = 0.0
        let candidateItemSet = Set(items.map(\.id))
        if let outfitNegativity = history.outfitNegativeSignalByItemSet[candidateItemSet], outfitNegativity > 0 {
            negativeFeedbackPenalty -= 0.25
        }
        for item in items {
            if let itemNegativity = history.itemNegativeSignal[item.id], itemNegativity > 0 {
                negativeFeedbackPenalty -= 0.08
            }
        }

        // 1. Formality Alignment Penalty (added 2026-07-10)
        var formalityPenalty: Double = 0.0
        if let constraints {
            for item in items {
                if !constraints.formalityRange.contains(item.formalityScore, tolerance: 0.5) {
                    formalityPenalty -= 0.15
                }
            }
        }

        // 2. Weather & Temperature Suitability Penalty (added 2026-07-10)
        var weatherPenalty: Double = 0.0
        if let weather {
            let isCold = weather.temperatureFahrenheit < 50
            let isHot = weather.temperatureFahrenheit > 80
            let isWet = weather.conditions.lowercased().contains("rain") ||
                        weather.conditions.lowercased().contains("snow") ||
                        weather.conditions.lowercased().contains("shower")

            if isCold || isWet || (constraints?.weatherLayeringRequired == true) {
                let hasOuterwear = items.contains { $0.slot == .outerwear }
                if !hasOuterwear {
                    weatherPenalty -= 0.25 // Missing layers in cold/wet weather
                }
            }

            for item in items {
                if isCold && item.fabricWeight == .light {
                    weatherPenalty -= 0.15 // Light fabric in cold weather
                }
                if isHot && item.fabricWeight == .heavy {
                    weatherPenalty -= 0.15 // Heavy fabric in hot weather
                }
            }
        }

        // 3. User Style Profile Colors Alignment (added 2026-07-10)
        var profileBonus: Double = 0.0
        if let profile {
            for item in items {
                let hex = item.colorProfile.primaryHex.lowercased().replacingOccurrences(of: "#", with: "")

                let isRecommended = profile.recommendedColors.contains { color in
                    let sanitized = color.lowercased().replacingOccurrences(of: "#", with: "")
                    return hex == sanitized || item.displayLabel.lowercased().contains(color.lowercased())
                }
                if isRecommended {
                    profileBonus += 0.10
                }

                let isAvoided = profile.avoidColors.contains { color in
                    let sanitized = color.lowercased().replacingOccurrences(of: "#", with: "")
                    return hex == sanitized || item.displayLabel.lowercased().contains(color.lowercased())
                }
                // Override Static Colors (added 2026-07-11): behavioral
                // history can outrank the static onboarding-derived avoid
                // list — if the user has since demonstrated a strong learned
                // affinity for this item's own color vibe (> 0.6), the static
                // penalty no longer reflects their actual taste, so it's
                // zeroed out rather than applied.
                let learnedAffinityForThisVibe = history.attributeProfile.colorVibeAffinity[item.colorProfile.category] ?? 0.5
                if isAvoided, learnedAffinityForThisVibe <= 0.6 {
                    profileBonus -= 0.20
                }
            }
        }

        return (meanPairScore + meanPreference + meanAffinityBonus + formalityPenalty + weatherPenalty + profileBonus + negativeFeedbackPenalty)
            .clamped(to: 0...1)
    }
}
