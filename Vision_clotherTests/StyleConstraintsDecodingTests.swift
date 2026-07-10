//
//  StyleConstraintsDecodingTests.swift
//  Vision_clotherTests
//
//  Verifies `StyleConstraints` decodes the exact JSON Schema shape in
//  PRD.md §3.3 — this is the contract OpenRouter's `response_format:
//  json_schema` is constrained to (Services/OpenRouterIntentExtractionService.swift).
//

import Foundation
import Testing
@testable import Vision_clother

struct StyleConstraintsDecodingTests {

    @Test func decodesThePRDSchemaShapeExactly() throws {
        let json = """
        {
          "formality_range": [2.5, 3.5],
          "weather_layering_required": true,
          "color_palette_vibe": ["neutral", "earth_tones"],
          "season_suitability": "spring_fall"
        }
        """

        let decoded = try JSONDecoder().decode(StyleConstraints.self, from: Data(json.utf8))

        #expect(decoded.formalityRange.lowerBound == 2.5)
        #expect(decoded.formalityRange.upperBound == 3.5)
        #expect(decoded.weatherLayeringRequired == true)
        #expect(decoded.colorPaletteVibe == [.neutral, .earthTones])
        #expect(decoded.seasonSuitability == .springFall)
    }

    @Test func formalityRangeRejectsAMalformedArray() {
        // FormalityRange decodes as a bare 2-element array (PRD §3.3's
        // `formality_range` shape), so the malformed JSON here is the array
        // itself, not a wrapping object.
        let json = "[1.0, 2.0, 3.0]"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FormalityRange.self, from: Data(json.utf8))
        }
    }

    @Test func formalityRangeRoundTripsThroughEncodeAndDecode() throws {
        let original = FormalityRange(lowerBound: 1.5, upperBound: 4.0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FormalityRange.self, from: data)
        #expect(decoded == original)
    }
}
