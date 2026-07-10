//
//  GarmentMetadata.swift
//  Vision_clother
//
//  Wire type returned by the vision-metadata LLM call (PRD.md §3.1's
//  ingestion metadata table). Kept separate from `WardrobeItem`'s own
//  `ColorProfile` (which uses Swift-native camelCase keys for local
//  persistence) because this is untrusted wire data with its own explicit
//  `CodingKeys`, per CLAUDE.md §4's "Strict Schema Bounds" invariant.
//
//  Mapping into a `WardrobeItem` happens at the call site (currently
//  `AddItemViewModel`), not here — this type only owns the wire shape.
//

import Foundation

struct GarmentMetadata: Codable, Equatable {
    struct ColorProfileWire: Codable, Equatable {
        var primaryHex: String
        var secondaryHex: String?
        var category: ColorVibe
        var undertone: Undertone?

        enum CodingKeys: String, CodingKey {
            case primaryHex = "primary_hex"
            case secondaryHex = "secondary_hex"
            case category
            case undertone
        }
    }

    var slot: Slot
    var formalityScore: Double
    var colorProfile: ColorProfileWire
    var pattern: GarmentPattern
    var seasonality: [Season]
    var fabricWeight: FabricWeight
    /// One concise sentence (≤140 chars) describing the garment — becomes
    /// the catalog entry text for the recommendation LLM
    /// (`Domain/WardrobeCatalogBuilder.swift`).
    var description: String
    /// Free-form style descriptors (e.g. "minimalist", "streetwear").
    var styleTags: [String]

    // Rich styling attributes (added 2026-07-10)
    var garmentSubtype: String?
    var fit: String?
    var silhouette: String?
    var material: String?
    var texture: String?

    enum CodingKeys: String, CodingKey {
        case slot
        case formalityScore = "formality_score"
        case colorProfile = "color_profile"
        case pattern
        case seasonality
        case fabricWeight = "fabric_weight"
        case description
        case styleTags = "style_tags"
        case garmentSubtype = "garment_subtype"
        case fit
        case silhouette
        case material
        case texture
    }
}
