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
                  "summary": "A balanced, neutral-anchored look.",
                  "confidence": 95
              }
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: Data(json.utf8))

        #expect(decoded.outfits.count == 1)
        #expect(decoded.outfits.first?.itemIDsBySlot[.top] == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        #expect(decoded.outfits.first?.itemIDsBySlot[.bottom] == "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
        #expect(decoded.outfits.first?.itemIDsBySlot[.footwear] == "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")
        #expect(decoded.outfits.first?.itemIDsBySlot[.outerwear] == nil)
        #expect(decoded.outfits.first?.rationale.summary == "A balanced, neutral-anchored look.")
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
                  "summary": "Layered.",
                  "confidence": 90
              }
            }
          ]
        }
        """

        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: Data(json.utf8))
        #expect(decoded.outfits.first?.itemIDsBySlot[.outerwear] == "4")
    }

    // MARK: - Multi-Accessory Outfits (Stylist Intelligence Engine ADR)

    @Test func omittedSupplementaryAccessoryIDsDecodesAsEmpty() throws {
        // Every fixture predating this feature omits `supplementary_accessory_ids`
        // entirely — must still decode as "nothing extra."
        let json = """
        {
          "outfits": [
            {
              "top_id": "1", "bottom_id": "2", "footwear_id": "3",
              "rationale": { "summary": "A clean look.", "confidence": 90 }
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: Data(json.utf8))
        #expect(decoded.outfits.first?.supplementaryAccessoryIDs == [])
    }

    @Test func decodesSupplementaryAccessoryIDsWhenPresent() throws {
        let json = """
        {
          "outfits": [
            {
              "top_id": "1", "bottom_id": "2", "footwear_id": "3",
              "supplementary_accessory_ids": ["watch-id", "necklace-id"],
              "rationale": { "summary": "Layered accessories.", "confidence": 88 }
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: Data(json.utf8))
        #expect(decoded.outfits.first?.supplementaryAccessoryIDs == ["watch-id", "necklace-id"])
    }

    @Test func encodesAndDecodesRoundTripWithSupplementaryAccessoryIDs() throws {
        let original = RecommendedOutfitWire(
            itemIDsBySlot: [.top: "1", .bottom: "2", .footwear: "3"],
            supplementaryAccessoryIDs: ["a", "b"],
            rationale: StructuredRationaleWire(summary: "Test.", confidence: 80)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecommendedOutfitWire.self, from: data)

        #expect(decoded == original)
    }

    @Test func emptyOutfitsArrayDecodes() throws {
        let json = #"{ "outfits": [] }"#
        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: Data(json.utf8))
        #expect(decoded.outfits.isEmpty)
    }

    // MARK: - Clarification Loop (Stylist Intelligence Engine ADR, Phase 2)

    @Test func omittedClarificationFieldsDecodeAsAlreadyFinal() throws {
        // Every fixture/response predating this ADR phase omits
        // intent_clear/follow_up_text/suggested_chips entirely — must still
        // decode as "already final," matching prior behavior exactly.
        let json = #"{ "outfits": [] }"#
        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: Data(json.utf8))

        #expect(decoded.intentClear == true)
        #expect(decoded.followUpText == nil)
        #expect(decoded.suggestedChips.isEmpty)
    }

    @Test func decodesAClarificationTurnWithChipsAndNullResolvedConstraints() throws {
        let json = """
        {
          "outfits": [],
          "resolved_constraints": null,
          "intent_clear": false,
          "follow_up_text": "What kind of event are you dressing for?",
          "suggested_chips": ["Party", "Church", "Job Interview", "Casual Hangout"]
        }
        """

        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: Data(json.utf8))

        #expect(decoded.intentClear == false)
        #expect(decoded.outfits.isEmpty)
        #expect(decoded.resolvedConstraints == nil)
        #expect(decoded.followUpText == "What kind of event are you dressing for?")
        #expect(decoded.suggestedChips == ["Party", "Church", "Job Interview", "Casual Hangout"])
    }

    @Test func encodesAndDecodesRoundTripForAClarificationTurn() throws {
        let original = OutfitRecommendationResponse(
            outfits: [],
            intentClear: false,
            followUpText: "Could you tell me more about the occasion?",
            suggestedChips: ["Party", "Work"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OutfitRecommendationResponse.self, from: data)

        #expect(decoded == original)
    }
}
