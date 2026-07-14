//
//  OutfitRecommendationEngineTests.swift
//  Vision_clotherTests
//
//  Covers the Permutation & Heuristic Engine (PRD.md §2.1, stage 3) end to
//  end: empty-inventory ghost fallback, NaN immunity, and `limit` handling.
//

import Foundation
import Testing
@testable import Vision_clother

struct OutfitRecommendationEngineTests {

    private var wideOpenConstraints: StyleConstraints {
        StyleConstraints(
            formalityRange: FormalityRange(lowerBound: 1.0, upperBound: 5.0),
            weatherLayeringRequired: false,
            colorPaletteVibe: [.neutral],
            seasonSuitability: .summer
        )
    }

    @Test func emptyInventoryStillProducesGhostBackedCandidates() {
        let candidates = OutfitRecommendationEngine.generateCandidates(
            inventory: [],
            constraints: wideOpenConstraints
        )

        #expect(!candidates.isEmpty)
        #expect(candidates.allSatisfy { $0.containsGhostElements })
        #expect(candidates.allSatisfy { !$0.score.isNaN })
    }

    @Test func respectsTheRequestedLimit() {
        let candidates = OutfitRecommendationEngine.generateCandidates(
            inventory: [],
            constraints: wideOpenConstraints,
            limit: 1
        )
        #expect(candidates.count <= 1)
    }

    @Test func candidatesAreSortedByScoreDescending() {
        let candidates = OutfitRecommendationEngine.generateCandidates(
            inventory: [],
            constraints: wideOpenConstraints,
            limit: 10
        )
        let scores = candidates.map(\.score)
        #expect(scores == scores.sorted(by: >))
    }

    @Test func outfitScoreHandlesEmptyAndSingleItemInputWithoutNaN() {
        let single = WardrobeItem(
            slot: .top,
            formalityScore: 2,
            colorProfile: ColorProfile(primaryHex: "#FFFFFF", secondaryHex: nil, category: .neutral),
            pattern: .solid,
            seasonality: [.summer],
            fabricWeight: .light
        )

        let emptyScore = OutfitRecommendationEngine.outfitScore(for: [], history: FeedbackHistory())
        let singleScore = OutfitRecommendationEngine.outfitScore(for: [single], history: FeedbackHistory())

        #expect(!emptyScore.isNaN)
        #expect(!singleScore.isNaN)
    }

    @Test func ghostFallbackFillsGapsEvenWhenRealInventoryMissesTheSeasonFilter() {
        // A winter-only real top should be filtered out by a "summer"
        // constraint, but the top slot must still be filled — by the
        // all-season ghost default — so the result is not empty.
        let winterOnlyTop = WardrobeItem(
            slot: .top,
            formalityScore: 2,
            colorProfile: ColorProfile(primaryHex: "#FFFFFF", secondaryHex: nil, category: .neutral),
            pattern: .solid,
            seasonality: [.winter],
            fabricWeight: .heavy
        )

        let candidates = OutfitRecommendationEngine.generateCandidates(
            inventory: [winterOnlyTop],
            constraints: wideOpenConstraints
        )

        #expect(!candidates.isEmpty)
        #expect(candidates.allSatisfy { $0.top.isGhostElement })
    }

    // MARK: - Item Rating & Preference Learning (attribute bias)

    @Test func emptyAttributeProfileLeavesScoresUnchanged() {
        let item = WardrobeItem(
            slot: .top,
            formalityScore: 2,
            colorProfile: ColorProfile(primaryHex: "#FFFFFF", secondaryHex: nil, category: .neutral),
            pattern: .solid,
            seasonality: [.summer],
            fabricWeight: .light
        )

        let baselineScore = OutfitRecommendationEngine.outfitScore(for: [item], history: FeedbackHistory())

        var historyWithEmptyProfile = FeedbackHistory()
        historyWithEmptyProfile.attributeProfile = AttributePreferenceProfile.build(from: [])
        let scoreWithEmptyProfile = OutfitRecommendationEngine.outfitScore(for: [item], history: historyWithEmptyProfile)

        #expect(abs(baselineScore - scoreWithEmptyProfile) < 0.0001)
    }

    @Test func likedAttributeCombinationOutranksANeutralOne() {
        let lovedColor = ColorVibe.vibrant
        let neutralColor = ColorVibe.pastel

        let lovedTop = WardrobeItem(
            slot: .top, formalityScore: 2,
            colorProfile: ColorProfile(primaryHex: "#FF0000", secondaryHex: nil, category: lovedColor),
            pattern: .solid, seasonality: [.summer], fabricWeight: .light
        )
        let neutralTop = WardrobeItem(
            slot: .top, formalityScore: 2,
            colorProfile: ColorProfile(primaryHex: "#EEEEEE", secondaryHex: nil, category: neutralColor),
            pattern: .solid, seasonality: [.summer], fabricWeight: .light
        )

        var history = FeedbackHistory()
        let ratings = (0..<5).map { _ in
            RatedAttributes(value: 1.0, colorVibe: lovedColor, pattern: .solid, formalityBand: 2)
        }
        history.attributeProfile = AttributePreferenceProfile.build(from: ratings)

        let lovedScore = OutfitRecommendationEngine.outfitScore(for: [lovedTop], history: history)
        let neutralScore = OutfitRecommendationEngine.outfitScore(for: [neutralTop], history: history)

        #expect(lovedScore > neutralScore)
    }

    // MARK: - Recommendation Engine: Read Disliked Signals (2026-07-11)

    @Test func netNegativeItemHistoryPenalizesRatherThanDropsTheOutfit() {
        let item = WardrobeItem(
            slot: .top, formalityScore: 2,
            colorProfile: ColorProfile(primaryHex: "#FFFFFF", secondaryHex: nil, category: .neutral),
            pattern: .solid, seasonality: [.summer], fabricWeight: .light
        )

        var history = FeedbackHistory()
        history.itemNegativeSignal[item.id] = 1.0 // net dislike

        let baselineScore = OutfitRecommendationEngine.outfitScore(for: [item], history: FeedbackHistory())
        let penalizedScore = OutfitRecommendationEngine.outfitScore(for: [item], history: history)

        #expect(!penalizedScore.isNaN)
        #expect(penalizedScore < baselineScore)
    }

    @Test func netNegativeOutfitItemSetHistoryPenalizesTheExactCombination() {
        let top = WardrobeItem(
            slot: .top, formalityScore: 2,
            colorProfile: ColorProfile(primaryHex: "#FFFFFF", secondaryHex: nil, category: .neutral),
            pattern: .solid, seasonality: [.summer], fabricWeight: .light
        )
        let bottom = WardrobeItem(
            slot: .bottom, formalityScore: 2,
            colorProfile: ColorProfile(primaryHex: "#000000", secondaryHex: nil, category: .neutral),
            pattern: .solid, seasonality: [.summer], fabricWeight: .light
        )

        var history = FeedbackHistory()
        history.outfitNegativeSignalByItemSet[Set([top.id, bottom.id])] = 1.0

        let baselineScore = OutfitRecommendationEngine.outfitScore(for: [top, bottom], history: FeedbackHistory())
        let penalizedScore = OutfitRecommendationEngine.outfitScore(for: [top, bottom], history: history)

        #expect(penalizedScore < baselineScore)
        // A different combination sharing only one item must not be
        // penalized — the match is by the exact item set, not any overlap.
        let otherBottom = WardrobeItem(
            slot: .bottom, formalityScore: 2,
            colorProfile: ColorProfile(primaryHex: "#111111", secondaryHex: nil, category: .neutral),
            pattern: .solid, seasonality: [.summer], fabricWeight: .light
        )
        let unaffectedScore = OutfitRecommendationEngine.outfitScore(for: [top, otherBottom], history: history)
        #expect(abs(unaffectedScore - baselineScore) < 0.0001)
    }

    // MARK: - Recommendation Engine: Override Static Colors (2026-07-11)

    @Test func learnedColorAffinityOverridesTheStaticAvoidColorPenalty() {
        let avoidedVibe = ColorVibe.vibrant
        let item = WardrobeItem(
            slot: .top, formalityScore: 2,
            colorProfile: ColorProfile(primaryHex: "#FF0000", secondaryHex: nil, category: avoidedVibe),
            pattern: .solid, seasonality: [.summer], fabricWeight: .light
        )
        let profile = UserStyleProfile(
            skinTone: "medium", undertone: .warm, bodyType: "athletic",
            styleKeywords: [], recommendedColors: [], avoidColors: ["#FF0000"]
        )

        var neutralHistory = FeedbackHistory()
        neutralHistory.attributeProfile = AttributePreferenceProfile.build(from: [])

        var learnedLikesHistory = FeedbackHistory()
        let strongLikes = (0..<10).map { _ in
            RatedAttributes(value: 1.0, colorVibe: avoidedVibe, pattern: .solid, formalityBand: 2)
        }
        learnedLikesHistory.attributeProfile = AttributePreferenceProfile.build(from: strongLikes)

        let scoreWithStaticPenalty = OutfitRecommendationEngine.outfitScore(for: [item], profile: profile, history: neutralHistory)
        let scoreWithOverride = OutfitRecommendationEngine.outfitScore(for: [item], profile: profile, history: learnedLikesHistory)

        #expect(scoreWithOverride > scoreWithStaticPenalty)
    }

    // MARK: - Optional accent slots (headwear/accessory/bag)

    private func makeItem(slot: Slot, formalityScore: Double = 2.0) -> WardrobeItem {
        WardrobeItem(
            slot: slot,
            formalityScore: formalityScore,
            colorProfile: ColorProfile(primaryHex: "#333333", secondaryHex: nil, category: .neutral),
            pattern: .solid,
            seasonality: Season.allCases,
            fabricWeight: .medium
        )
    }

    @Test func accentSlotIsOmittedWhenNotDesired() {
        let inventory = [
            makeItem(slot: .top), makeItem(slot: .bottom), makeItem(slot: .footwear),
            makeItem(slot: .headwear),
        ]
        let candidates = OutfitRecommendationEngine.generateCandidates(inventory: inventory, constraints: wideOpenConstraints)

        #expect(candidates.allSatisfy { $0.headwear == nil })
    }

    @Test func accentSlotIsIncludedWhenDesiredAndAvailable() {
        let inventory = [
            makeItem(slot: .top), makeItem(slot: .bottom), makeItem(slot: .footwear),
            makeItem(slot: .headwear),
        ]
        var constraints = wideOpenConstraints
        constraints.desiredAccentSlots = [.headwear]

        let candidates = OutfitRecommendationEngine.generateCandidates(inventory: inventory, constraints: constraints)

        #expect(candidates.contains { $0.headwear != nil })
    }

    @Test func desiredAccentSlotWithNoMatchingInventoryIsSilentlyOmitted() {
        // Wanting an accent the closet doesn't own must not empty the result
        // — top/bottom/footwear alone are still a valid, complete outfit.
        let inventory = [makeItem(slot: .top), makeItem(slot: .bottom), makeItem(slot: .footwear)]
        var constraints = wideOpenConstraints
        constraints.desiredAccentSlots = [.headwear, .accessory, .bag]

        let candidates = OutfitRecommendationEngine.generateCandidates(inventory: inventory, constraints: constraints)

        #expect(!candidates.isEmpty)
        #expect(candidates.allSatisfy { $0.headwear == nil && $0.accessory == nil && $0.bag == nil })
    }

    @Test func manyOptionalAccentItemsStayBoundedRatherThanExplodingCombinatorially() {
        // 5 tops/bottoms/shoes x 6 items in each of 4 optional slots would be
        // 5*5*5*6*6*6*6 = 162,000 combinations uncapped; the per-slot
        // formality-closeness cap must keep this from blowing up.
        var inventory: [WardrobeItem] = []
        for _ in 0..<5 {
            inventory.append(makeItem(slot: .top))
            inventory.append(makeItem(slot: .bottom))
            inventory.append(makeItem(slot: .footwear))
        }
        for _ in 0..<6 {
            inventory.append(makeItem(slot: .outerwear))
            inventory.append(makeItem(slot: .headwear))
            inventory.append(makeItem(slot: .accessory))
            inventory.append(makeItem(slot: .bag))
        }

        var constraints = wideOpenConstraints
        constraints.weatherLayeringRequired = true
        constraints.desiredAccentSlots = [.headwear, .accessory, .bag]

        let start = Date()
        let candidates = OutfitRecommendationEngine.generateCandidates(
            inventory: inventory, constraints: constraints, limit: 5
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(!candidates.isEmpty)
        #expect(elapsed < 2.0)
    }
}
