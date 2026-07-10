//
//  OutfitCombination.swift
//  Vision_clother
//
//  A scored candidate flatlay produced by the Permutation & Heuristic Engine
//  (PRD.md §2.1, stage 3). Purely in-memory / display-oriented — not
//  persisted; only the feedback the user gives on one is persisted
//  (see Models/FeedbackEvent.swift).
//

import Foundation

struct OutfitCombination: Identifiable {
    let id = UUID()
    var top: WardrobeItem
    var bottom: WardrobeItem
    var footwear: WardrobeItem
    var outerwear: WardrobeItem?
    /// Mean of the constituent pairwise compatibility posteriors, combined
    /// with per-item preference. See `Domain/PairCompatibilityScoring.swift`.
    var score: Double
    /// Short explanation from the recommendation LLM (PRD §3.7) for why this
    /// combination was picked. `nil` for outfits produced by the fully
    /// deterministic fallback engine (`Domain/OutfitRecommendationEngine.swift`),
    /// which has no natural-language rationale to offer.
    var rationale: String? = nil

    var items: [WardrobeItem] {
        [top, bottom, footwear] + (outerwear.map { [$0] } ?? [])
    }

    /// Ghost elements are scored identically to real items (see
    /// `Domain/PairCompatibilityScoring.swift`) — this flag exists only so
    /// the UI can label provenance ("Starter Piece"), not to affect scoring.
    var containsGhostElements: Bool {
        items.contains { $0.isGhostElement }
    }
}
