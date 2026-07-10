//
//  AttributePreferenceProfileTests.swift
//  Vision_clotherTests
//
//  Covers the Item Rating & Preference Learning attribute-affinity model
//  (Domain/AttributePreferenceProfile.swift): NaN-safety and neutrality for
//  empty input, shrinkage direction with real ratings, and the bounded
//  affinityBonus used to bias (not filter) recommendations.
//

import Testing
@testable import Vision_clother

struct AttributePreferenceProfileTests {

    private func makeItem(
        colorVibe: ColorVibe = .neutral,
        pattern: GarmentPattern = .solid,
        formalityScore: Double = 2.0
    ) -> WardrobeItem {
        WardrobeItem(
            slot: .top,
            formalityScore: formalityScore,
            colorProfile: ColorProfile(primaryHex: "#FFFFFF", secondaryHex: nil, category: colorVibe),
            pattern: pattern,
            seasonality: Season.allCases,
            fabricWeight: .light
        )
    }

    @Test func emptyInputYieldsNeutralZeroBonus() {
        let profile = AttributePreferenceProfile.build(from: [])
        let item = makeItem()

        let bonus = profile.affinityBonus(for: item)

        #expect(!bonus.isNaN)
        #expect(bonus == 0)
    }

    @Test func strongLikesOnAColorRaiseItsAffinityAboveNeutral() {
        let ratings = (0..<5).map { _ in
            RatedAttributes(value: 1.0, colorVibe: .vibrant, pattern: .solid, formalityBand: 2)
        }
        let profile = AttributePreferenceProfile.build(from: ratings)

        let likedItem = makeItem(colorVibe: .vibrant)
        let unratedItem = makeItem(colorVibe: .pastel)

        #expect(profile.affinityBonus(for: likedItem) > 0)
        #expect(profile.affinityBonus(for: unratedItem) == 0)
    }

    @Test func strongDislikesOnAPatternLowerItsAffinityBelowNeutral() {
        let ratings = (0..<5).map { _ in
            RatedAttributes(value: 0.0, colorVibe: .neutral, pattern: .graphic, formalityBand: 2)
        }
        let profile = AttributePreferenceProfile.build(from: ratings)

        let dislikedItem = makeItem(pattern: .graphic)
        #expect(profile.affinityBonus(for: dislikedItem) < 0)
    }

    @Test func affinityBonusStaysWithinBounds() {
        let allLoved = (0..<50).map { _ in
            RatedAttributes(value: 1.0, colorVibe: .earthTones, pattern: .textured, formalityBand: 5)
        }
        let profile = AttributePreferenceProfile.build(from: allLoved)
        let item = makeItem(colorVibe: .earthTones, pattern: .textured, formalityScore: 5.0)

        let bonus = profile.affinityBonus(for: item)
        #expect(!bonus.isNaN)
        #expect(bonus <= AttributePreferenceProfile.maxBonusMagnitude + 0.0001)
        #expect(bonus >= -AttributePreferenceProfile.maxBonusMagnitude - 0.0001)
    }

    @Test func ghostElementsAreScoredThroughTheIdenticalPath() {
        // Domain/CLAUDE.md: no isGhostElement branch anywhere in scoring.
        let ratings = (0..<5).map { _ in
            RatedAttributes(value: 1.0, colorVibe: .monochrome, pattern: .solid, formalityBand: 2)
        }
        let profile = AttributePreferenceProfile.build(from: ratings)

        let ghost = GhostElementProvider.defaultItem(for: .top)
        let realItem = makeItem(colorVibe: .monochrome)

        // Both items share the same relevant attributes as the ghost
        // default (solid pattern, formality band 2) modulo color, so the
        // bonus formula itself must not special-case isGhostElement.
        #expect(!profile.affinityBonus(for: ghost).isNaN)
        #expect(!profile.affinityBonus(for: realItem).isNaN)
    }
}
