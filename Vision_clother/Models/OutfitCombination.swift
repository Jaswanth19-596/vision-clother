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
    /// filled whenever the wardrobe has a real (non-ghost) item for that
    /// slot, but are not guaranteed — a wardrobe with zero items in a
    /// required slot legitimately produces an outfit missing it (see
    /// `Domain/OutfitRecommendationValidator.swift`'s `availableSlots`
    /// handling) rather than being rejected outright. Every other slot is
    /// present only when the engine/validator decided to include it.
    var itemsBySlot: [Slot: WardrobeItem]
    /// Mean of the constituent pairwise compatibility posteriors, combined
    /// with per-item preference. See `Domain/PairCompatibilityScoring.swift`.
    var score: Double
    /// One-line explanation from the recommendation LLM (PRD §3.7) for why
    /// this combination was picked. `nil` for outfits produced by the fully
    /// deterministic fallback engine.
    var structuredRationale: StructuredRationale? = nil
    /// Multi-Accessory Outfits (Stylist Intelligence Engine ADR, closed
    /// 2026-07-15): 0-`FashionKnowledgeConstants.DressCode.maxSupplementaryAccessories`
    /// additional accent items worn alongside `accessory` — a wholly
    /// separate list, not a second `.accessory` dictionary entry. Every
    /// other slot stays singular; this is the one deliberate exception.
    var supplementaryAccessories: [WardrobeItem] = []

    init(
        itemsBySlot: [Slot: WardrobeItem],
        score: Double,
        structuredRationale: StructuredRationale? = nil,
        supplementaryAccessories: [WardrobeItem] = []
    ) {
        self.itemsBySlot = itemsBySlot
        self.score = score
        self.structuredRationale = structuredRationale
        self.supplementaryAccessories = supplementaryAccessories
    }

    // Convenience accessors, one per slot. top/bottom/footwear are usually
    // present (`OutfitRecommendationValidator.resolve` fills them whenever
    // the wardrobe has a candidate) but, like every other slot here, are not
    // guaranteed — see `itemsBySlot`'s doc comment.
    var top: WardrobeItem? { itemsBySlot[.top] }
    var bottom: WardrobeItem? { itemsBySlot[.bottom] }
    var footwear: WardrobeItem? { itemsBySlot[.footwear] }
    var outerwear: WardrobeItem? { itemsBySlot[.outerwear] }
    var headwear: WardrobeItem? { itemsBySlot[.headwear] }
    var accessory: WardrobeItem? { itemsBySlot[.accessory] }
    var bag: WardrobeItem? { itemsBySlot[.bag] }

    var items: [WardrobeItem] {
        Slot.allCases.compactMap { itemsBySlot[$0] } + supplementaryAccessories
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
