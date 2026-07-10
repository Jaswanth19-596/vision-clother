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

        enum CodingKeys: String, CodingKey {
            case primaryHex = "primary_hex"
            case secondaryHex = "secondary_hex"
            case category
        }
    }

    var slot: Slot
    var formalityScore: Double
    var colorProfile: ColorProfileWire
    var pattern: GarmentPattern
    var seasonality: [Season]
    var fabricWeight: FabricWeight

    enum CodingKeys: String, CodingKey {
        case slot
        case formalityScore = "formality_score"
        case colorProfile = "color_profile"
        case pattern
        case seasonality
        case fabricWeight = "fabric_weight"
    }
}
