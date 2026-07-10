//
//  UserStyleProfileDecodingTests.swift
//  Vision_clotherTests
//
//  Verifies `UserStyleProfileWire` decodes the PRD.md §3.8 shape exactly —
//  the contract the profile-derivation LLM's `response_format: json_schema`
//  is constrained to (Services/UserProfileDerivationService.swift).
//

import Foundation
import Testing
@testable import Vision_clother

struct UserStyleProfileDecodingTests {

    @Test func decodesThePRDStyleProfileShapeExactly() throws {
        let json = """
        {
          "skin_tone": "medium, warm olive",
          "undertone": "warm",
          "body_type": "athletic build",
          "style_keywords": ["classic", "minimalist"],
          "recommended_colors": ["#8A5A44", "#3A7CA5"],
          "avoid_colors": ["#B983FF"]
        }
        """

        let decoded = try JSONDecoder().decode(UserStyleProfileWire.self, from: Data(json.utf8))

        #expect(decoded.skinTone == "medium, warm olive")
        #expect(decoded.undertone == .warm)
        #expect(decoded.bodyType == "athletic build")
        #expect(decoded.styleKeywords == ["classic", "minimalist"])
        #expect(decoded.recommendedColors == ["#8A5A44", "#3A7CA5"])
        #expect(decoded.avoidColors == ["#B983FF"])
    }

    @Test func roundTripsThroughUserStyleProfilePersistedModel() {
        let wire = UserStyleProfileWire(
            skinTone: "fair, cool pink",
            undertone: .cool,
            bodyType: "slim",
            styleKeywords: ["preppy"],
            recommendedColors: ["#000080"],
            avoidColors: ["#FFA500"]
        )

        let profile = UserStyleProfile(
            skinTone: wire.skinTone,
            undertone: wire.undertone,
            bodyType: wire.bodyType,
            styleKeywords: wire.styleKeywords,
            recommendedColors: wire.recommendedColors,
            avoidColors: wire.avoidColors
        )

        #expect(profile.undertone == .cool)
        #expect(profile.undertoneRaw == "cool")
    }
}
