//
//  OutfitRecommendationResponseDecodingTests.swift
//  Vision_clotherTests
//
//  Verifies `OutfitRecommendationResponse` decodes the PRD.md §3.7 response
//  shape exactly — the contract the recommendation LLM's
//  `response_format: json_schema` is constrained to
//  (Services/OutfitRecommendationService.swift).
//

import Foundation
import Testing
@testable import Vision_clother

struct OutfitRecommendationResponseDecodingTests {

    @Test func decodesThePRDResponseShapeExactly() throws {
        let json = """
        {
          "outfits": [
            {
              "top_id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
              "bottom_id": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
              "footwear_id": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
              "outerwear_id": null,
              "rationale": {
                  "occasion": "A balanced, neutral-anchored look.",
                  "color_harmony": "Great colors.",
                  "body_profile": "Good fit.",
                  "weather": "Nice for today.",
                  "style": "Minimalist.",
                  "confidence": 95
              }
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: Data(json.utf8))

        #expect(decoded.outfits.count == 1)
        #expect(decoded.outfits.first?.topID == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        #expect(decoded.outfits.first?.bottomID == "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        #expect(decoded.outfits.first?.footwearID == "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
        #expect(decoded.outfits.first?.outerwearID == nil)
        #expect(decoded.outfits.first?.rationale.occasion == "A balanced, neutral-anchored look.")
        #expect(decoded.outfits.first?.rationale.confidence == 95)
        // Backward compatible: a response without `resolved_constraints`
        // (e.g. an older fixture, or a model that omits it) still decodes.
        #expect(decoded.resolvedConstraints == nil)
    }

    @Test func decodesResolvedConstraintsWhenPresent() throws {
        let json = """
        {
          "outfits": [],
          "resolved_constraints": {
            "formality_range": [4.0, 5.0],
            "weather_layering_required": false,
            "color_palette_vibe": ["neutral"],
            "season_suitability": "summer"
          }
        }
        """

        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: Data(json.utf8))

        #expect(decoded.resolvedConstraints?.formalityRange.lowerBound == 4.0)
        #expect(decoded.resolvedConstraints?.formalityRange.upperBound == 5.0)
        #expect(decoded.resolvedConstraints?.weatherLayeringRequired == false)
        #expect(decoded.resolvedConstraints?.colorPaletteVibe == [.neutral])
        #expect(decoded.resolvedConstraints?.seasonSuitability == .summer)
    }

    @Test func decodesExplicitNullResolvedConstraintsAsNil() throws {
        let json = #"{ "outfits": [], "resolved_constraints": null }"#
        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: Data(json.utf8))
        #expect(decoded.resolvedConstraints == nil)
    }

    @Test func nonNullOuterwearIDDecodes() throws {
        let json = """
        {
          "outfits": [
            {
              "top_id": "1", "bottom_id": "2", "footwear_id": "3",
              "outerwear_id": "4", "rationale": {
                  "occasion": "Layered.",
                  "color_harmony": "",
                  "body_profile": "",
                  "weather": "",
                  "style": "",
                  "confidence": 90
              }
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: Data(json.utf8))
        #expect(decoded.outfits.first?.outerwearID == "4")
    }

    @Test func emptyOutfitsArrayDecodes() throws {
        let json = #"{ "outfits": [] }"#
        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: Data(json.utf8))
        #expect(decoded.outfits.isEmpty)
    }
}
