//
//  VisualPreferenceProfileTests.swift
//  Vision_clotherTests
//
//  Covers `VisualPreferenceProfile.affinityBonus` and `.build(from:dislikedEmbeddings:)`
//  (Domain/VisualPreferenceProfile.swift) — the bounded, NaN-safe re-scoring
//  signal `Domain/OutfitRecommendationEngine.swift` folds into `outfitScore`.
//

import Foundation
import Testing
@testable import Vision_clother

struct VisualPreferenceProfileTests {

    @Test func emptyProfileReturnsZeroBonusForAnyEmbedding() {
        let profile = VisualPreferenceProfile()
        #expect(profile.affinityBonus(forEmbedding: [1, 0, 0]) == 0)
    }

    @Test func nilOrEmptyEmbeddingReturnsZeroBonusEvenWithATrainedProfile() {
        var profile = VisualPreferenceProfile()
        profile.likedCentroids = [VisualCentroid(vector: [1, 0, 0], weight: 5)]

        #expect(profile.affinityBonus(forEmbedding: nil) == 0)
        #expect(profile.affinityBonus(forEmbedding: []) == 0)
    }

    @Test func embeddingCloseToALikedCentroidScoresPositive() {
        var profile = VisualPreferenceProfile()
        profile.likedCentroids = [VisualCentroid(vector: [1, 0, 0], weight: 5)]

        let bonus = profile.affinityBonus(forEmbedding: [1, 0, 0])
        #expect(bonus > 0)
        #expect(bonus <= VisualPreferenceProfile.maxBonusMagnitude)
    }

    @Test func embeddingCloseToADislikedCentroidScoresNegative() {
        var profile = VisualPreferenceProfile()
        profile.dislikedCentroids = [VisualCentroid(vector: [1, 0, 0], weight: 5)]

        let bonus = profile.affinityBonus(forEmbedding: [1, 0, 0])
        #expect(bonus < 0)
        #expect(bonus >= -VisualPreferenceProfile.maxBonusMagnitude)
    }

    @Test func bonusIsBoundedEvenForAPerfectDoubleMatch() {
        var profile = VisualPreferenceProfile()
        profile.likedCentroids = [VisualCentroid(vector: [1, 0, 0], weight: 5)]
        profile.dislikedCentroids = [VisualCentroid(vector: [0, 1, 0], weight: 5)]

        let bonus = profile.affinityBonus(forEmbedding: [1, 0, 0])
        #expect(!bonus.isNaN)
        #expect(bonus <= VisualPreferenceProfile.maxBonusMagnitude)
        #expect(bonus >= -VisualPreferenceProfile.maxBonusMagnitude)
    }

    @Test func orthogonalEmbeddingToEveryCentroidScoresNearZero() {
        var profile = VisualPreferenceProfile()
        profile.likedCentroids = [VisualCentroid(vector: [1, 0, 0], weight: 5)]
        profile.dislikedCentroids = [VisualCentroid(vector: [0, 1, 0], weight: 5)]

        let bonus = profile.affinityBonus(forEmbedding: [0, 0, 1])
        #expect(abs(bonus) < 0.0001)
    }

    @Test func buildFromEmbeddingsReproducesIncrementalUpdateOrder() {
        let likedEmbeddings: [[Float]] = [[1, 0, 0], [1, 0, 0], [1, 0, 0]]
        let dislikedEmbeddings: [[Float]] = [[0, 1, 0]]

        let profile = VisualPreferenceProfile.build(from: likedEmbeddings, dislikedEmbeddings: dislikedEmbeddings)

        #expect(profile.likedCentroids.count == 1)
        #expect(profile.likedCentroids.first?.weight == 3)
        #expect(profile.dislikedCentroids.count == 1)
        #expect(profile.affinityBonus(forEmbedding: [1, 0, 0]) > 0)
    }

    @Test func buildFromEmptyEmbeddingsProducesAnEmptyUntrainedProfile() {
        let profile = VisualPreferenceProfile.build(from: [], dislikedEmbeddings: [])
        #expect(profile.likedCentroids.isEmpty)
        #expect(profile.dislikedCentroids.isEmpty)
        #expect(profile.affinityBonus(forEmbedding: [1, 0, 0]) == 0)
    }
}
