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

/// A slot-keyed dictionary can't be sent/received as a literal dynamic JSON
/// object under OpenRouter's strict `response_format: json_schema` mode
/// (which requires a fixed `properties`/`required` list — see
/// `Services/OutfitRecommendationService.swift`'s schema builder), so this
/// type stays dictionary-shaped only on the Swift side, via a custom
/// `Codable` implementation that maps to/from each `Slot.wireKey`. Adding a
/// future slot only means adding a `Slot` case — this type needs no changes.
struct RecommendedOutfitWire: Equatable {
    /// slot -> catalog item id string. Only slots the LLM actually picked
    /// appear here; required-slot presence is enforced by
    /// `OutfitRecommendationValidator`, not by this type.
    var itemIDsBySlot: [Slot: String]
    var rationale: StructuredRationaleWire
}

extension RecommendedOutfitWire: Codable {
    private struct DynamicCodingKeys: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
        var resolved: [Slot: String] = [:]
        for slot in Slot.allCases {
            guard let key = DynamicCodingKeys(stringValue: slot.wireKey) else { continue }
            if let id = try container.decodeIfPresent(String.self, forKey: key) {
                resolved[slot] = id
            }
        }
        itemIDsBySlot = resolved
        guard let rationaleKey = DynamicCodingKeys(stringValue: "rationale") else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "invalid rationale key")
            )
        }
        rationale = try container.decode(StructuredRationaleWire.self, forKey: rationaleKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKeys.self)
        for slot in Slot.allCases {
            guard let key = DynamicCodingKeys(stringValue: slot.wireKey) else { continue }
            try container.encodeIfPresent(itemIDsBySlot[slot], forKey: key)
        }
        guard let rationaleKey = DynamicCodingKeys(stringValue: "rationale") else {
            throw EncodingError.invalidValue(
                rationale, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "invalid rationale key")
            )
        }
        try container.encode(rationale, forKey: rationaleKey)
    }
}

struct StructuredRationaleWire: Codable, Equatable {
    var summary: String
    var confidence: Int
}
