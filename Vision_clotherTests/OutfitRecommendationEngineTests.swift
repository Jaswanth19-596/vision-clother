//
//  OutfitRecommendationEngineTests.swift
//  Vision_clotherTests
//
//  Covers the Permutation & Heuristic Engine (PRD.md §2.1, stage 3) end to
//  end: empty-inventory ghost fallback, NaN immunity, and `limit` handling.
//

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
}
