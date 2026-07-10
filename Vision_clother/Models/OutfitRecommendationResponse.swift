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

    enum CodingKeys: String, CodingKey {
        case outfits
    }
}

struct RecommendedOutfitWire: Codable, Equatable {
    var topID: String
    var bottomID: String
    var footwearID: String
    var outerwearID: String?
    var rationale: String

    enum CodingKeys: String, CodingKey {
        case topID = "top_id"
        case bottomID = "bottom_id"
        case footwearID = "footwear_id"
        case outerwearID = "outerwear_id"
        case rationale
    }
}
