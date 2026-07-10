//
//  PairCompatibilityScoringTests.swift
//  Vision_clotherTests
//
//  Covers CLAUDE.md §4's invariant: the scoring module must be test-driven
//  and 100% immune to NaN, including with ghost elements or empty sets.
//

import Testing
@testable import Vision_clother

struct PairCompatibilityScoringTests {

    private func makeItem(
        slot: Slot,
        formalityScore: Double,
        hex: String = "#FFFFFF",
        category: ColorVibe = .neutral,
        pattern: GarmentPattern = .solid
    ) -> WardrobeItem {
        WardrobeItem(
            slot: slot,
            formalityScore: formalityScore,
            colorProfile: ColorProfile(primaryHex: hex, secondaryHex: nil, category: category),
            pattern: pattern,
            seasonality: Season.allCases,
            fabricWeight: .light
        )
    }

    @Test func aestheticPriorStaysWithinZeroToOne() {
        let a = makeItem(slot: .top, formalityScore: 1.0, category: .vibrant, pattern: .graphic)
        let b = makeItem(slot: .bottom, formalityScore: 5.0, category: .vibrant, pattern: .plaid)

        let score = PairCompatibilityScoring.aestheticPrior(a, b)
        #expect(score >= 0 && score <= 1)
    }

    @Test func aestheticPriorIsPerfectForIdenticalNeutralSolids() {
        let a = makeItem(slot: .top, formalityScore: 2.5)
        let b = makeItem(slot: .bottom, formalityScore: 2.5)
        #expect(PairCompatibilityScoring.aestheticPrior(a, b) == 1.0)
    }

    @Test func pairScoreEqualsPriorWhenThereIsNoHistory() {
        let prior = 0.7
        let score = PairCompatibilityScoring.pairCompatibilityScore(
            aestheticPrior: prior,
            feedbackSum: 0,
            evaluationCount: 0
        )
        #expect(abs(score - prior) < 0.0001)
    }

    @Test func pairScoreIsNaNImmuneEvenWithZeroPriorWeightAndZeroHistory() {
        // Denominator would be 0/0 without the guard in
        // PairCompatibilityScoring.pairCompatibilityScore.
        let score = PairCompatibilityScoring.pairCompatibilityScore(
            aestheticPrior: 0.6,
            feedbackSum: 0,
            evaluationCount: 0,
            priorWeight: 0
        )
        #expect(!score.isNaN)
        #expect(score >= 0 && score <= 1)
    }

    @Test func pairScoreStaysBoundedEvenWithHeavyPositiveFeedback() {
        // The PRD's literal ±1 feedback formula can push this above 1 —
        // the normalized-feedback fix keeps it bounded.
        let score = PairCompatibilityScoring.pairCompatibilityScore(
            aestheticPrior: 1.0,
            feedbackSum: 50,
            evaluationCount: 50
        )
        #expect(score <= 1.0001)
    }

    @Test func itemPreferenceDefaultsToNeutralWithNoHistory() {
        let preference = PairCompatibilityScoring.itemPreference(likeCount: 0, dislikeCount: 0)
        #expect(abs(preference - 0.5) < 0.0001)
    }

    @Test func itemPreferenceStaysBounded() {
        let allLiked = PairCompatibilityScoring.itemPreference(likeCount: 20, dislikeCount: 0)
        let allDisliked = PairCompatibilityScoring.itemPreference(likeCount: 0, dislikeCount: 20)
        #expect(allLiked <= 1.0001)
        #expect(allDisliked >= -0.0001)
    }

    @Test func pairwiseCombinationsHandlesEmptyAndSingletonInput() {
        #expect(PairCompatibilityScoring.pairwiseCombinations([]).isEmpty)

        let single = makeItem(slot: .top, formalityScore: 2)
        #expect(PairCompatibilityScoring.pairwiseCombinations([single]).isEmpty)
    }

    @Test func pairwiseCombinationsCoversEveryUnorderedPair() {
        let items = [
            makeItem(slot: .top, formalityScore: 2),
            makeItem(slot: .bottom, formalityScore: 2),
            makeItem(slot: .footwear, formalityScore: 2),
        ]
        #expect(PairCompatibilityScoring.pairwiseCombinations(items).count == 3)
    }
}
