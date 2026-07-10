//
//  GarmentMetadataDecodingTests.swift
//  Vision_clotherTests
//
//  Verifies `GarmentMetadata` decodes the PRD.md §3.1 ingestion metadata
//  shape exactly — the contract the vision-tagging LLM's `response_format:
//  json_schema` is constrained to (Services/VisionMetadataExtractionService.swift).
//

import Foundation
import Testing
@testable import Vision_clother

struct GarmentMetadataDecodingTests {

    @Test func decodesThePRDIngestionSchemaShapeExactly() throws {
        let json = """
        {
          "slot": "top",
          "formality_score": 2.5,
          "color_profile": {
            "primary_hex": "#1A1A1A",
            "secondary_hex": "#FFFFFF",
            "category": "monochrome",
            "undertone": "cool"
          },
          "pattern": "striped",
          "seasonality": ["summer", "spring_fall"],
          "fabric_weight": "light",
          "description": "Charcoal ribbed crewneck with a slim taper.",
          "style_tags": ["minimalist", "layering"]
        }
        """

        let decoded = try JSONDecoder().decode(GarmentMetadata.self, from: Data(json.utf8))

        #expect(decoded.slot == .top)
        #expect(decoded.formalityScore == 2.5)
        #expect(decoded.colorProfile.primaryHex == "#1A1A1A")
        #expect(decoded.colorProfile.secondaryHex == "#FFFFFF")
        #expect(decoded.colorProfile.category == .monochrome)
        #expect(decoded.colorProfile.undertone == .cool)
        #expect(decoded.pattern == .striped)
        #expect(decoded.seasonality == [.summer, .springFall])
        #expect(decoded.fabricWeight == .light)
        #expect(decoded.description == "Charcoal ribbed crewneck with a slim taper.")
        #expect(decoded.styleTags == ["minimalist", "layering"])
    }

    @Test func nullSecondaryHexDecodesAsNil() throws {
        let json = """
        {
          "slot": "footwear",
          "formality_score": 1.0,
          "color_profile": { "primary_hex": "#FFFFFF", "secondary_hex": null, "category": "neutral", "undertone": "neutral" },
          "pattern": "solid",
          "seasonality": ["summer"],
          "fabric_weight": "medium",
          "description": "",
          "style_tags": []
        }
        """

        let decoded = try JSONDecoder().decode(GarmentMetadata.self, from: Data(json.utf8))
        #expect(decoded.colorProfile.secondaryHex == nil)
    }

    @Test func missingUndertoneKeyDecodesAsNil() throws {
        // Older/lenient (unstructured-fallback) responses may omit
        // "undertone" entirely — it must decode as nil, not throw.
        let json = """
        {
          "slot": "bottom",
          "formality_score": 3.0,
          "color_profile": { "primary_hex": "#222222", "secondary_hex": null, "category": "neutral" },
          "pattern": "solid",
          "seasonality": ["winter"],
          "fabric_weight": "heavy",
          "description": "Black wool trousers.",
          "style_tags": []
        }
        """

        let decoded = try JSONDecoder().decode(GarmentMetadata.self, from: Data(json.utf8))
        #expect(decoded.colorProfile.undertone == nil)
    }
}
