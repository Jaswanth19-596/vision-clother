//
//  ItemRatingScoringTests.swift
//  Vision_clotherTests
//
//  Zero-mocking per docs/approach/conventions.md — FeedbackHistory is a
//  plain struct, so these tests construct it directly and call the pure
//  function, with no SwiftData container involved.
//

import Foundation
import Testing
@testable import Vision_clother

struct ItemRatingScoringTests {

    @Test func returnsNeutralFiftyWhenItemHasNoFeedbackAnywhere() {
        let itemID = UUID()
        let history = FeedbackHistory()
        #expect(ItemRatingScoring.score(for: itemID, history: history) == 50)
    }

    @Test func matchesItemPreferenceScaledByHundredFromItemFeedbackAlone() {
        let itemID = UUID()
        var history = FeedbackHistory()
        history.itemFeedback[itemID] = (likes: 8, total: 10)

        let expected = PairCompatibilityScoring.itemPreference(likeCount: 8, dislikeCount: 2)
        let score = ItemRatingScoring.score(for: itemID, history: history)

        #expect(abs(Double(score) - expected * 100) < 1.0)
    }

    @Test func foldsInPairFeedbackWhereItemIsEitherSideOfThePair() {
        let itemID = UUID()
        let otherA = UUID()
        let otherB = UUID()
        var history = FeedbackHistory()
        history.pairFeedback[PairKey(itemID, otherA)] = (likes: 3, total: 3)
        history.pairFeedback[PairKey(otherB, itemID)] = (likes: 0, total: 2)

        let expected = PairCompatibilityScoring.itemPreference(likeCount: 3, dislikeCount: 2)
        let score = ItemRatingScoring.score(for: itemID, history: history)

        #expect(abs(Double(score) - expected * 100) < 1.0)
    }

    @Test func ignoresPairFeedbackThatDoesNotReferenceTheItem() {
        let itemID = UUID()
        let unrelatedA = UUID()
        let unrelatedB = UUID()
        var history = FeedbackHistory()
        history.pairFeedback[PairKey(unrelatedA, unrelatedB)] = (likes: 5, total: 5)

        #expect(ItemRatingScoring.score(for: itemID, history: history) == 50)
    }

    @Test func sumsItemFeedbackAndPairFeedbackWithoutOverwriting() {
        let itemID = UUID()
        let otherA = UUID()
        var history = FeedbackHistory()
        history.itemFeedback[itemID] = (likes: 2, total: 2)
        history.pairFeedback[PairKey(itemID, otherA)] = (likes: 0, total: 2)

        let expected = PairCompatibilityScoring.itemPreference(likeCount: 2, dislikeCount: 2)
        let score = ItemRatingScoring.score(for: itemID, history: history)

        #expect(abs(Double(score) - expected * 100) < 1.0)
    }

    @Test func stronglyLikedItemTrendsNearHundredAndStaysBounded() {
        let itemID = UUID()
        var history = FeedbackHistory()
        history.itemFeedback[itemID] = (likes: 20, total: 20)

        let score = ItemRatingScoring.score(for: itemID, history: history)
        #expect(score <= 100)
        #expect(score >= 90)
    }

    @Test func stronglyDislikedItemTrendsNearZeroAndStaysBounded() {
        let itemID = UUID()
        var history = FeedbackHistory()
        history.itemFeedback[itemID] = (likes: 0, total: 20)

        let score = ItemRatingScoring.score(for: itemID, history: history)
        #expect(score >= 0)
        #expect(score <= 10)
    }
}
