//
//  ColorProfileMigrationTests.swift
//  Vision_clotherTests
//
//  Covers the 2026-07-10 addition of `ColorProfile.undertone` — existing
//  persisted rows (pre-reversal) have no "undertone" key at all, and must
//  decode as `nil` rather than throw, matching SwiftData's automatic
//  lightweight migration for a new optional stored property.
//  See Models/WardrobeItem.swift.
//

import Foundation
import Testing
@testable import Vision_clother

struct ColorProfileMigrationTests {

    @Test func preReversalJSONWithNoUndertoneKeyDecodesAsNil() throws {
        // This is exactly the shape a `ColorProfile` encoded before
        // `undertone` existed would have on disk.
        let json = """
        { "primaryHex": "#3A7CA5", "secondaryHex": null, "category": "neutral" }
        """

        let decoded = try JSONDecoder().decode(ColorProfile.self, from: Data(json.utf8))

        #expect(decoded.primaryHex == "#3A7CA5")
        #expect(decoded.category == .neutral)
        #expect(decoded.undertone == nil)
    }

    @Test func memberwiseInitDefaultsUndertoneToNil() {
        let profile = ColorProfile(primaryHex: "#000000", secondaryHex: nil, category: .monochrome)
        #expect(profile.undertone == nil)
    }

    @Test func encodeDecodeRoundTripsANonNilUndertone() throws {
        let original = ColorProfile(primaryHex: "#FF0000", secondaryHex: nil, category: .vibrant, undertone: .warm)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ColorProfile.self, from: data)
        #expect(decoded.undertone == .warm)
    }
}
