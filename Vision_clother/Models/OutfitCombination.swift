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
    /// One entry per slot present in this outfit. top/bottom/footwear are
    /// guaranteed present (see `init`'s assertion) — every other slot is
    /// present only when the engine/validator decided to include it.
    var itemsBySlot: [Slot: WardrobeItem]
    /// Mean of the constituent pairwise compatibility posteriors, combined
    /// with per-item preference. See `Domain/PairCompatibilityScoring.swift`.
    var score: Double
    /// One-line explanation from the recommendation LLM (PRD §3.7) for why
    /// this combination was picked. `nil` for outfits produced by the fully
    /// deterministic fallback engine.
    var structuredRationale: StructuredRationale? = nil

    init(itemsBySlot: [Slot: WardrobeItem], score: Double, structuredRationale: StructuredRationale? = nil) {
        assert(
            Slot.allCases.filter(\.isRequired).allSatisfy { itemsBySlot[$0] != nil },
            "OutfitCombination missing a required slot"
        )
        self.itemsBySlot = itemsBySlot
        self.score = score
        self.structuredRationale = structuredRationale
    }

    // Convenience accessors for the always-required slots and the original
    // optional-accent slot (outerwear) plus the newer accents — every one of
    // these force-unwraps/asserts is safe because the two construction sites
    // (`OutfitRecommendationEngine.generateCandidates`,
    // `OutfitRecommendationValidator.resolve`) both guard non-empty
    // top/bottom/footwear before ever constructing an `OutfitCombination`.
    var top: WardrobeItem { itemsBySlot[.top]! }
    var bottom: WardrobeItem { itemsBySlot[.bottom]! }
    var footwear: WardrobeItem { itemsBySlot[.footwear]! }
    var outerwear: WardrobeItem? { itemsBySlot[.outerwear] }
    var headwear: WardrobeItem? { itemsBySlot[.headwear] }
    var accessory: WardrobeItem? { itemsBySlot[.accessory] }
    var bag: WardrobeItem? { itemsBySlot[.bag] }

    var items: [WardrobeItem] {
        Slot.allCases.compactMap { itemsBySlot[$0] }
    }

    /// Ghost elements are scored identically to real items (see
    /// `Domain/PairCompatibilityScoring.swift`) — this flag exists only so
    /// the UI can label provenance ("Starter Piece"), not to affect scoring.
    var containsGhostElements: Bool {
        items.contains { $0.isGhostElement }
    }
}

struct StructuredRationale: Codable, Equatable {
    var summary: String
    var confidence: Int
}
