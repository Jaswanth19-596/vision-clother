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
              "rationale": "A balanced, neutral-anchored look."
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
        #expect(decoded.outfits.first?.rationale == "A balanced, neutral-anchored look.")
    }

    @Test func nonNullOuterwearIDDecodes() throws {
        let json = """
        {
          "outfits": [
            {
              "top_id": "1", "bottom_id": "2", "footwear_id": "3",
              "outerwear_id": "4", "rationale": "Layered."
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
