//
//  OutfitRecommendationResponse.swift
//  Vision_clother
//
//  Wire type returned by the primary recommendation LLM call (PRD.md §3.7,
//  the 2026-07-10 LLM-as-Recommender reversal — see
//  docs/decisions/resolved-v1.md). Each entry references wardrobe items by
//  the `id` string sent in `Domain/WardrobeCatalogBuilder.swift`'s catalog
//  (a `WardrobeItem.id.uuidString`) — mapping those IDs back to real
//  `WardrobeItem`s and rejecting anything that doesn't resolve happens in
//  `Domain/OutfitRecommendationValidator.swift`, not here. This type only
//  owns the untrusted wire shape.
//

import Foundation

struct OutfitRecommendationResponse: Codable, Equatable {
    var outfits: [RecommendedOutfitWire]
    /// Self-reported resolution of scenario -> dress code / weather / season
    /// (Stylist Intelligence Engine ADR, Decision Hierarchy Tier 1/2). The
    /// same call that picks items also states what it resolved the intent
    /// to, so the validator can enforce dress-code alignment on the LLM path
    /// without a second intent-extraction call. Optional and defaulted so
    /// older fixtures and a model that omits it still decode cleanly — the
    /// validator simply skips Tier 1/2 enforcement when it's absent, same as
    /// today's behavior.
    var resolvedConstraints: StyleConstraints? = nil

    enum CodingKeys: String, CodingKey {
        case outfits
        case resolvedConstraints = "resolved_constraints"
    }
}

struct RecommendedOutfitWire: Codable, Equatable {
    var topID: String
    var bottomID: String
    var footwearID: String
    var outerwearID: String?
    var rationale: StructuredRationaleWire

    enum CodingKeys: String, CodingKey {
        case topID = "top_id"
        case bottomID = "bottom_id"
        case footwearID = "footwear_id"
        case outerwearID = "outerwear_id"
        case rationale
    }
}

struct StructuredRationaleWire: Codable, Equatable {
    var occasion: String
    var colorHarmony: String
    var bodyProfile: String
    var weather: String
    var style: String
    var confidence: Int

    enum CodingKeys: String, CodingKey {
        case occasion
        case colorHarmony = "color_harmony"
        case bodyProfile = "body_profile"
        case weather
        case style
        case confidence
    }
}
