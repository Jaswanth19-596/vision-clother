//
//  StyleConstraints.swift
//  Vision_clother
//
//  Wire type returned by the intent-extraction LLM call (PRD.md §3.3).
//  Intent extraction itself never sees the wardrobe — it only ever produces
//  this constraint payload. As of the 2026-07-10 LLM-as-Recommender reversal
//  (docs/decisions/resolved-v1.md), this is no longer the primary
//  recommendation path: it now feeds the deterministic *fallback* engine
//  (`Domain/OutfitRecommendationEngine.swift`), used when the primary
//  `Services/OutfitRecommendationService.swift` call fails or returns
//  nothing valid. See PRD.md §2.1a for the primary flow.
//

import Foundation

/// `[min, max]` formality band, decoded from/encoded to a 2-element JSON
/// array per the PRD §3.3 schema (`minItems: 2, maxItems: 2`).
struct FormalityRange: Codable, Equatable {
    var lowerBound: Double
    var upperBound: Double

    init(lowerBound: Double, upperBound: Double) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard let count = container.count, count == 2 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "formality_range must be a 2-element array"
                )
            )
        }
        lowerBound = try container.decode(Double.self)
        upperBound = try container.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(lowerBound)
        try container.encode(upperBound)
    }

    func contains(_ value: Double, tolerance: Double = 0) -> Bool {
        value >= lowerBound - tolerance && value <= upperBound + tolerance
    }

    var midpoint: Double { (lowerBound + upperBound) / 2 }
}

/// Matches the JSON Schema in PRD.md §3.3 exactly — this is the only shape
/// the LLM is ever allowed to produce (enforced via OpenRouter's
/// `response_format: json_schema`, see `Services/OpenRouterIntentExtractionService.swift`).
struct StyleConstraints: Codable, Equatable {
    var formalityRange: FormalityRange
    var weatherLayeringRequired: Bool
    var colorPaletteVibe: [ColorVibe]
    var seasonSuitability: Season
    /// Optional accent slots (headwear/accessory/bag) the scenario calls
    /// for, beyond outerwear (still governed by `weatherLayeringRequired`)
    /// and the always-included top/bottom/footwear. Defaulted to `[]` so
    /// older fixtures / a model response that omits the field still decode
    /// cleanly, same migration-safety pattern as `ColorProfile.undertone`.
    var desiredAccentSlots: Set<Slot> = []

    enum CodingKeys: String, CodingKey {
        case formalityRange = "formality_range"
        case weatherLayeringRequired = "weather_layering_required"
        case colorPaletteVibe = "color_palette_vibe"
        case seasonSuitability = "season_suitability"
        case desiredAccentSlots = "desired_accent_slots"
    }

    init(
        formalityRange: FormalityRange,
        weatherLayeringRequired: Bool,
        colorPaletteVibe: [ColorVibe],
        seasonSuitability: Season,
        desiredAccentSlots: Set<Slot> = []
    ) {
        self.formalityRange = formalityRange
        self.weatherLayeringRequired = weatherLayeringRequired
        self.colorPaletteVibe = colorPaletteVibe
        self.seasonSuitability = seasonSuitability
        self.desiredAccentSlots = desiredAccentSlots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formalityRange = try container.decode(FormalityRange.self, forKey: .formalityRange)
        weatherLayeringRequired = try container.decode(Bool.self, forKey: .weatherLayeringRequired)
        colorPaletteVibe = try container.decode([ColorVibe].self, forKey: .colorPaletteVibe)
        seasonSuitability = try container.decode(Season.self, forKey: .seasonSuitability)
        desiredAccentSlots = try container.decodeIfPresent(Set<Slot>.self, forKey: .desiredAccentSlots) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formalityRange, forKey: .formalityRange)
        try container.encode(weatherLayeringRequired, forKey: .weatherLayeringRequired)
        try container.encode(colorPaletteVibe, forKey: .colorPaletteVibe)
        try container.encode(seasonSuitability, forKey: .seasonSuitability)
        try container.encode(desiredAccentSlots, forKey: .desiredAccentSlots)
    }
}

/// Localized weather passed alongside the free-text prompt to the intent
/// extractor (PRD.md §2.1, Intent Extraction Layer).
struct WeatherContext: Codable, Equatable {
    var temperatureFahrenheit: Double
    var conditions: String
}
