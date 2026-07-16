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

    // MARK: - Item Rating -> Swipe-to-Learn implicit swipe (gentle learning rate)

    @Test func implicitLearningRateNudgesLessThanTheDefaultIncrementalMeanStep() {
        // Seed exactly `maxClusters` (3) centroids so the next update nudges
        // the nearest one instead of seeding a fresh one.
        var explicitCentroids: [VisualCentroid] = [
            VisualCentroid(vector: [1, 0, 0], weight: 1),
            VisualCentroid(vector: [0, 1, 0], weight: 1),
            VisualCentroid(vector: [0, 0, 1], weight: 1)
        ]
        var implicitCentroids = explicitCentroids
        let newVector: [Float] = [0.7, 0.7, 0]

        // Explicit swipe: default `1/weight` incremental-mean step.
        VisualClusterUpdater.update(&explicitCentroids, with: newVector)
        // Implicit swipe (a rating): fixed, gentle step.
        VisualClusterUpdater.update(&implicitCentroids, with: newVector, learningRate: VisualClusterUpdater.implicitLearningRate)

        // Both nudge the same nearest centroid ([1, 0, 0], closest to
        // [0.7, 0.7, 0]) toward `newVector` — the gentle implicit update
        // should stay much closer to the original direction.
        let explicitSimilarityToOriginal = VisualClusterUpdater.cosineSimilarity(explicitCentroids[0].vector, [1, 0, 0])
        let implicitSimilarityToOriginal = VisualClusterUpdater.cosineSimilarity(implicitCentroids[0].vector, [1, 0, 0])

        #expect(implicitSimilarityToOriginal > explicitSimilarityToOriginal)
    }

    // MARK: - matchDetail (Test Your Style manual verification tool)

    @Test func matchDetailIsNilForAnUntrainedProfile() {
        let profile = VisualPreferenceProfile()
        #expect(profile.matchDetail(forEmbedding: [1, 0, 0]) == nil)
    }

    @Test func matchDetailIsNilForANilOrEmptyEmbeddingEvenWithATrainedProfile() {
        var profile = VisualPreferenceProfile()
        profile.likedCentroids = [VisualCentroid(vector: [1, 0, 0], weight: 5)]

        #expect(profile.matchDetail(forEmbedding: nil) == nil)
        #expect(profile.matchDetail(forEmbedding: []) == nil)
    }

    @Test func matchDetailExposesTheRawSimilaritiesBehindTheBonus() {
        var profile = VisualPreferenceProfile()
        profile.likedCentroids = [VisualCentroid(vector: [1, 0, 0], weight: 5)]
        profile.dislikedCentroids = [VisualCentroid(vector: [0, 1, 0], weight: 5)]

        let detail = profile.matchDetail(forEmbedding: [1, 0, 0])
        #expect(detail != nil)
        #expect(abs((detail?.likedSimilarity ?? 0) - 1.0) < 0.0001)
        #expect(abs((detail?.dislikedSimilarity ?? 0) - 0.0) < 0.0001)
        #expect(detail?.bonus == profile.affinityBonus(forEmbedding: [1, 0, 0]))
    }

    @Test func explicitSwipesAreUnaffectedByTheLearningRateParameterDefault() {
        // No `learningRate` argument at all — mirrors every pre-existing
        // call site (`recordSwipe`, `build(from:dislikedEmbeddings:)`) and
        // must behave byte-for-byte as before this parameter was added.
        var centroids: [VisualCentroid] = [
            VisualCentroid(vector: [1, 0, 0], weight: 1),
            VisualCentroid(vector: [0, 1, 0], weight: 1),
            VisualCentroid(vector: [0, 0, 1], weight: 1)
        ]
        VisualClusterUpdater.update(&centroids, with: [1, 0, 0])

        #expect(centroids[0].weight == 2)
    }
}
