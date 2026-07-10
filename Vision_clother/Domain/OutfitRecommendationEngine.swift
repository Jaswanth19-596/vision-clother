//
//  OutfitRecommendationEngine.swift
//  Vision_clother
//
//  Candidate Retrieval + Permutation & Heuristic Engine (PRD.md §2.1, stages
//  2–3), running entirely on-device. Pure function of (inventory,
//  constraints, feedback history) → sorted candidates — no I/O. The caller
//  (a ViewModel) is responsible for loading `FeedbackHistory` from SwiftData
//  and passing it in, keeping this module isolated and mockable per
//  CLAUDE.md §4.
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
    /// pair key -> (times liked together, total times evaluated)
    var pairFeedback: [PairKey: (likes: Int, total: Int)] = [:]
    /// item id -> (times liked, total times evaluated)
    var itemFeedback: [UUID: (likes: Int, total: Int)] = [:]
    /// Learned color/pattern/formality taste, built from `ItemRating` history
    /// (see `Domain/AttributePreferenceProfile.swift`). Defaults to an empty
    /// profile — every affinity then reads as neutral 0.5, so
    /// `affinityBonus` is 0 and scoring is unchanged from before this
    /// feature existed.
    var attributeProfile: AttributePreferenceProfile = AttributePreferenceProfile()
}

enum OutfitRecommendationEngine {
    /// Filters the wardrobe by constraint, fills empty slots with Ghost
    /// Elements (PRD §3.2), cross-products the remaining slots, scores each
    /// combination, and returns the top `limit` by score descending.
    ///
    /// Returns an empty array (never crashes) if, even after ghost-element
    /// injection, some required slot has no candidate — e.g. an inventory
    /// with items but none matching the season filter for a mandatory slot.
    static func generateCandidates(
        inventory: [WardrobeItem],
        constraints: StyleConstraints,
        history: FeedbackHistory = FeedbackHistory(),
        limit: Int = 5
    ) -> [OutfitCombination] {
        let seasonFiltered = inventory.filter { $0.seasonality.contains(constraints.seasonSuitability) }
        let formalityFiltered = seasonFiltered.filter {
            constraints.formalityRange.contains($0.formalityScore, tolerance: 0.5)
        }

        let withGhosts = GhostElementProvider.ensureGhostElements(in: formalityFiltered)

        let tops = withGhosts.filter { $0.slot == .top }
        let bottoms = withGhosts.filter { $0.slot == .bottom }
        let footwear = withGhosts.filter { $0.slot == .footwear }
        let outerwear = withGhosts.filter { $0.slot == .outerwear }

        guard !tops.isEmpty, !bottoms.isEmpty, !footwear.isEmpty else { return [] }

        let outerwearOptions: [WardrobeItem?] = (constraints.weatherLayeringRequired && !outerwear.isEmpty)
            ? outerwear.map { $0 }
            : [nil]

        var combos: [OutfitCombination] = []
        combos.reserveCapacity(tops.count * bottoms.count * footwear.count * outerwearOptions.count)

        for top in tops {
            for bottom in bottoms {
                for shoe in footwear {
                    for outer in outerwearOptions {
                        let items = [top, bottom, shoe] + (outer.map { [$0] } ?? [])
                        let score = outfitScore(for: items, history: history)
                        combos.append(
                            OutfitCombination(top: top, bottom: bottom, footwear: shoe, outerwear: outer, score: score)
                        )
                    }
                }
            }
        }

        return Array(combos.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// `Score_Total = mean(pairwise P(Pair|History)) + mean(Preference(Item))
    /// + mean(AttributeAffinityBonus(Item))` across every item in the
    /// combination — the PRD §3.4 formula applied outfit-wide rather than to
    /// a single pair, plus a bounded learned-taste bias term (Item Rating &
    /// Preference Learning feature; see `Domain/AttributePreferenceProfile.swift`).
    /// Guarded against empty pair/item sets so a malformed (e.g. single-item)
    /// call never divides by zero. With an empty `attributeProfile` (no
    /// ratings yet) the bonus term is always 0, so this is byte-for-byte the
    /// same score as before the feature existed.
    static func outfitScore(for items: [WardrobeItem], history: FeedbackHistory) -> Double {
        let pairs = PairCompatibilityScoring.pairwiseCombinations(items)
        let pairScores: [Double] = pairs.map { a, b in
            let feedback = history.pairFeedback[PairKey(a.id, b.id)]
            let prior = PairCompatibilityScoring.aestheticPrior(a, b)
            return PairCompatibilityScoring.pairCompatibilityScore(
                aestheticPrior: prior,
                feedbackSum: Double(feedback?.likes ?? 0),
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

        return meanPairScore + meanPreference + meanAffinityBonus
    }
}
