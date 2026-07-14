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
    /// today's behavior. Nil whenever `intentClear` is false — nothing has
    /// been resolved yet on a clarification/redirect turn.
    var resolvedConstraints: StyleConstraints? = nil

    /// Clarification Loop (Stylist Intelligence Engine ADR, Phase 2): true
    /// once the occasion is clear enough (or this is the forced final turn)
    /// to output real recommendations this turn. Defaults to `true` so a
    /// pre-clarification-loop fixture/response that omits this key is
    /// treated as already-final, matching prior behavior exactly.
    var intentClear: Bool = true

    /// The assistant's own natural-language turn: a clarifying question, an
    /// out-of-scope redirect, or a wardrobe-aware decision note alongside
    /// real recommendations (e.g. "you don't have a black suit for this
    /// funeral — want to build around your darkest option instead?"). Nil
    /// when there's nothing to say beyond the outfits themselves.
    var followUpText: String? = nil

    /// Tappable quick-reply suggestions for `followUpText`, e.g.
    /// `["Party", "Church", "Job Interview", "Casual Hangout"]`. Empty (not
    /// nil) when there's nothing to suggest — mirrors `outfits`' existing
    /// empty-array-not-null convention.
    var suggestedChips: [String] = []

    enum CodingKeys: String, CodingKey {
        case outfits
        case resolvedConstraints = "resolved_constraints"
        case intentClear = "intent_clear"
        case followUpText = "follow_up_text"
        case suggestedChips = "suggested_chips"
    }

    init(
        outfits: [RecommendedOutfitWire],
        resolvedConstraints: StyleConstraints? = nil,
        intentClear: Bool = true,
        followUpText: String? = nil,
        suggestedChips: [String] = []
    ) {
        self.outfits = outfits
        self.resolvedConstraints = resolvedConstraints
        self.intentClear = intentClear
        self.followUpText = followUpText
        self.suggestedChips = suggestedChips
    }

    // Custom Codable (rather than relying on the memberwise defaults above,
    // which synthesized Codable ignores) so a response/fixture that omits
    // intent_clear/follow_up_text/suggested_chips — every one predating this
    // ADR phase — still decodes as "already final," matching prior behavior.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outfits = try container.decode([RecommendedOutfitWire].self, forKey: .outfits)
        resolvedConstraints = try container.decodeIfPresent(StyleConstraints.self, forKey: .resolvedConstraints)
        intentClear = try container.decodeIfPresent(Bool.self, forKey: .intentClear) ?? true
        followUpText = try container.decodeIfPresent(String.self, forKey: .followUpText)
        suggestedChips = try container.decodeIfPresent([String].self, forKey: .suggestedChips) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outfits, forKey: .outfits)
        try container.encodeIfPresent(resolvedConstraints, forKey: .resolvedConstraints)
        try container.encode(intentClear, forKey: .intentClear)
        try container.encodeIfPresent(followUpText, forKey: .followUpText)
        try container.encode(suggestedChips, forKey: .suggestedChips)
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
