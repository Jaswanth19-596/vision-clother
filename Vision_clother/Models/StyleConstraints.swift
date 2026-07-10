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
}

/// Matches the JSON Schema in PRD.md §3.3 exactly — this is the only shape
/// the LLM is ever allowed to produce (enforced via OpenRouter's
/// `response_format: json_schema`, see `Services/OpenRouterIntentExtractionService.swift`).
struct StyleConstraints: Codable, Equatable {
    var formalityRange: FormalityRange
    var weatherLayeringRequired: Bool
    var colorPaletteVibe: [ColorVibe]
    var seasonSuitability: Season

    enum CodingKeys: String, CodingKey {
        case formalityRange = "formality_range"
        case weatherLayeringRequired = "weather_layering_required"
        case colorPaletteVibe = "color_palette_vibe"
        case seasonSuitability = "season_suitability"
    }
}

/// Localized weather passed alongside the free-text prompt to the intent
/// extractor (PRD.md §2.1, Intent Extraction Layer).
struct WeatherContext: Codable, Equatable {
    var temperatureFahrenheit: Double
    var conditions: String
}
