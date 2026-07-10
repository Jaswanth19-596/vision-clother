//
//  OpenRouterResponseParsingTests.swift
//  Vision_clotherTests
//
//  Covers the response_format-unsupported fallback path shared by
//  OpenRouterIntentExtractionService and VisionMetadataExtractionService —
//  `minimax/minimax-m3`'s structured-output support isn't guaranteed
//  (CLAUDE.md §5.1), so both services fall back to parsing a plain-text
//  reply that may be wrapped in a markdown fence or annotated with prose.
//

import Foundation
import Testing
@testable import Vision_clother

struct OpenRouterResponseParsingTests {

    @Test func passesThroughAlreadyCleanJSON() {
        let text = #"{"a": 1, "b": "two"}"#
        let data = OpenRouterResponseParsing.extractJSONObject(from: text)
        #expect(String(decoding: data, as: UTF8.self) == text)
    }

    @Test func stripsAJSONMarkdownFence() {
        let text = "```json\n{\"a\": 1}\n```"
        let data = OpenRouterResponseParsing.extractJSONObject(from: text)
        #expect(String(decoding: data, as: UTF8.self) == "{\"a\": 1}")
    }

    @Test func stripsABarePlainFence() {
        let text = "```\n{\"a\": 1}\n```"
        let data = OpenRouterResponseParsing.extractJSONObject(from: text)
        #expect(String(decoding: data, as: UTF8.self) == "{\"a\": 1}")
    }

    @Test func discardsSurroundingProseAroundTheObject() {
        let text = "Sure, here's the JSON:\n{\"a\": 1}\nHope that helps!"
        let data = OpenRouterResponseParsing.extractJSONObject(from: text)
        #expect(String(decoding: data, as: UTF8.self) == "{\"a\": 1}")
    }

    @Test func extractedTextDecodesAsTheTargetType() throws {
        let text = """
        Here you go:
        ```json
        {
          "formality_range": [2.0, 3.0],
          "weather_layering_required": false,
          "color_palette_vibe": ["vibrant"],
          "season_suitability": "summer"
        }
        ```
        """
        let data = OpenRouterResponseParsing.extractJSONObject(from: text)
        let decoded = try JSONDecoder().decode(StyleConstraints.self, from: data)
        #expect(decoded.seasonSuitability == .summer)
        #expect(decoded.colorPaletteVibe == [.vibrant])
    }
}
