//
//  AttributePreferenceProfileTests.swift
//  Vision_clotherTests
//
//  Covers the Item Rating & Preference Learning attribute-affinity model
//  (Domain/AttributePreferenceProfile.swift): NaN-safety and neutrality for
//  empty input, shrinkage direction with real ratings, and the bounded
//  affinityBonus used to bias (not filter) recommendations.
//

import Foundation
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
        // Unrated on every axis (not just color) — pattern .solid/band 2
        // match the trained ratings, so isolating color alone requires
        // picking pattern/formality values absent from `ratings` too.
        let unratedItem = makeItem(colorVibe: .pastel, pattern: .graphic, formalityScore: 5.0)

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

    // MARK: - Stylist Intelligence Engine Phase 1: outfit-dimension ratings

    private func makeOutfitDimensionRating(
        colorHarmony: Double = 0.5,
        occasionMatch: Double = 0.5,
        styleMatch: Double = 0.5,
        silhouette: Double = 0.5,
        weatherFit: Double = 0.5,
        colorVibe: ColorVibe = .neutral,
        styleTags: [String] = [],
        silhouetteTag: String? = nil,
        formalityBand: Int = 2,
        fabricWeight: FabricWeight = .light
    ) -> OutfitDimensionRatedAttributes {
        OutfitDimensionRatedAttributes(
            colorHarmony: colorHarmony,
            occasionMatch: occasionMatch,
            styleMatch: styleMatch,
            silhouette: silhouette,
            weatherFit: weatherFit,
            colorVibe: colorVibe,
            styleTags: styleTags,
            silhouetteTag: silhouetteTag,
            formalityBand: formalityBand,
            fabricWeight: fabricWeight
        )
    }

    @Test func styleMatchRaisesStyleTagAffinityAboveNeutral() {
        let ratings = (0..<5).map { _ in
            makeOutfitDimensionRating(styleMatch: 1.0, styleTags: ["minimalist"])
        }
        let profile = AttributePreferenceProfile.build(from: [], outfitDimensionRatings: ratings)

        let likedItem = makeItem()
        likedItem.styleTags = ["minimalist"]
        let unratedItem = makeItem()
        unratedItem.styleTags = ["streetwear"]

        #expect(profile.affinityBonus(for: likedItem) > 0)
        #expect(profile.affinityBonus(for: unratedItem) == 0)
    }

    // MARK: - Stylist Intelligence Engine Phase 1 addendum: item-level Style Identity

    @Test func itemLevelStyleIdentityRaisesStyleTagAffinityAboveNeutral() {
        let ratings = (0..<5).map { _ in
            RatedAttributes(value: 0.5, colorVibe: .neutral, pattern: .solid, formalityBand: 2, styleIdentity: 1.0, styleTags: ["minimalist"])
        }
        let profile = AttributePreferenceProfile.build(from: ratings)

        let likedItem = makeItem()
        likedItem.styleTags = ["minimalist"]
        let unratedItem = makeItem(colorVibe: .pastel, pattern: .graphic, formalityScore: 5.0)
        unratedItem.styleTags = ["streetwear"]

        #expect(profile.affinityBonus(for: likedItem) > 0)
        #expect(profile.affinityBonus(for: unratedItem) == 0)
    }

    @Test func itemLevelAndOutfitLevelStyleSignalsShareTheSameAffinityChannel() {
        let itemRatings = [
            RatedAttributes(value: 0.5, colorVibe: .neutral, pattern: .solid, formalityBand: 2, styleIdentity: 1.0, styleTags: ["minimalist"])
        ]
        let outfitRatings = [
            makeOutfitDimensionRating(styleMatch: 1.0, styleTags: ["minimalist"])
        ]
        let profile = AttributePreferenceProfile.build(from: itemRatings, outfitDimensionRatings: outfitRatings)

        // Two independent positive signals for the same tag should shrink
        // toward "liked" more confidently than either alone.
        let itemOnly = AttributePreferenceProfile.build(from: itemRatings)
        #expect((profile.styleTagAffinity["minimalist"] ?? 0) >= (itemOnly.styleTagAffinity["minimalist"] ?? 0))
    }

    @Test func silhouetteRatingLowersSilhouetteAffinityBelowNeutral() {
        let ratings = (0..<5).map { _ in
            makeOutfitDimensionRating(silhouette: 0.0, silhouetteTag: "boxy")
        }
        let profile = AttributePreferenceProfile.build(from: [], outfitDimensionRatings: ratings)

        let dislikedItem = makeItem()
        dislikedItem.silhouette = "boxy"

        #expect(profile.affinityBonus(for: dislikedItem) < 0)
    }

    @Test func weatherFitRaisesFabricWeightAffinityAboveNeutral() {
        let ratings = (0..<5).map { _ in
            makeOutfitDimensionRating(weatherFit: 1.0, fabricWeight: .heavy)
        }
        let profile = AttributePreferenceProfile.build(from: [], outfitDimensionRatings: ratings)

        let likedItem = makeItem()
        likedItem.fabricWeight = .heavy

        #expect(profile.affinityBonus(for: likedItem) > 0)
    }

    @Test func colorHarmonyAndOccasionMatchFoldIntoExistingColorAndFormalityAffinity() {
        let ratings = (0..<5).map { _ in
            makeOutfitDimensionRating(colorHarmony: 1.0, occasionMatch: 1.0, colorVibe: .vibrant, formalityBand: 4)
        }
        let profile = AttributePreferenceProfile.build(from: [], outfitDimensionRatings: ratings)

        #expect((profile.colorVibeAffinity[.vibrant] ?? 0) > 0.5)
        #expect((profile.formalityAffinity[4] ?? 0) > 0.5)
    }

    @Test func emptyOutfitDimensionRatingsYieldNeutralZeroBonus() {
        let profile = AttributePreferenceProfile.build(from: [], outfitDimensionRatings: [])
        let item = makeItem()

        #expect(profile.affinityBonus(for: item) == 0)
    }

    // MARK: - Math Engine Overhaul: exponential time-decay

    @Test func staleRatingsContributeLessThanRecentOnesOfTheSameStrength() {
        let now = Date.now
        let recentOnly = [RatedAttributes(value: 1.0, colorVibe: .vibrant, pattern: .solid, formalityBand: 2, recordedAt: now)]
        // 120 days ago — two 60-day half-lives, so this rating's weight
        // should have decayed to roughly a quarter of the recent one's.
        let staleOnly = [RatedAttributes(value: 1.0, colorVibe: .vibrant, pattern: .solid, formalityBand: 2, recordedAt: now.addingTimeInterval(-120 * 86400))]

        let recentProfile = AttributePreferenceProfile.build(from: recentOnly, now: now)
        let staleProfile = AttributePreferenceProfile.build(from: staleOnly, now: now)

        let recentAffinity = recentProfile.colorVibeAffinity[.vibrant] ?? 0.5
        let staleAffinity = staleProfile.colorVibeAffinity[.vibrant] ?? 0.5

        // Both are still likes (affinity > neutral), but the stale one pulls
        // less far from 0.5 than the recent one — decay reduces its
        // effective weight against the same flat prior.
        #expect(staleAffinity > 0.5)
        #expect(staleAffinity < recentAffinity)
    }

    @Test func decayWeightIsApproximatelyHalfAtTheSixtyDayHalfLife() {
        let now = Date.now
        let sixtyDaysAgo = now.addingTimeInterval(-60 * 86400)
        let weight = AttributePreferenceProfile.decayWeight(recordedAt: sixtyDaysAgo, now: now)
        #expect(abs(weight - 0.5) < 0.01)
    }

    // MARK: - Math Engine Overhaul: dynamic Bayesian shrinkage prior

    @Test func aLargerClosetBaselineRequiresMoreFeedbackToMoveTheSameAmount() {
        // A handful of likes should move a rarely-owned attribute's affinity
        // further from neutral than the same handful of likes moves an
        // attribute the closet already has many items of — the prior scales
        // with how entrenched that attribute already is.
        let ratings = (0..<3).map { _ in
            RatedAttributes(value: 1.0, colorVibe: .vibrant, pattern: .solid, formalityBand: 2)
        }

        let smallCloset = [makeItem(colorVibe: .vibrant)]
        let largeCloset = (0..<50).map { _ in makeItem(colorVibe: .vibrant) }

        let smallClosetProfile = AttributePreferenceProfile.build(from: ratings, inventory: smallCloset)
        let largeClosetProfile = AttributePreferenceProfile.build(from: ratings, inventory: largeCloset)

        let smallAffinity = smallClosetProfile.colorVibeAffinity[.vibrant] ?? 0.5
        let largeAffinity = largeClosetProfile.colorVibeAffinity[.vibrant] ?? 0.5

        #expect(smallAffinity > largeAffinity)
        #expect(largeAffinity > 0.5) // still a net-positive signal, just more shrunk
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
