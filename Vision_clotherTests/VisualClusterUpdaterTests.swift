//
//  VisualClusterUpdaterTests.swift
//  Vision_clotherTests
//
//  Covers the online mini-batch k-means updater (`Domain/VisualPreferenceProfile.swift`)
//  that turns a stream of liked/disliked photo embeddings into a small
//  number of "style persona" centroids per side.
//

import Foundation
import Testing
@testable import Vision_clother

struct VisualClusterUpdaterTests {

    @Test func cosineSimilarityIsOneForIdenticalVectorsAndZeroForOrthogonal() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]

        #expect(abs(VisualClusterUpdater.cosineSimilarity(a, a) - 1.0) < 0.0001)
        #expect(abs(VisualClusterUpdater.cosineSimilarity(a, b) - 0.0) < 0.0001)
    }

    @Test func cosineSimilarityIsNaNSafeForZeroMagnitudeOrMismatchedVectors() {
        let zero: [Float] = [0, 0, 0]
        let a: [Float] = [1, 0, 0]
        let mismatched: [Float] = [1, 0]

        #expect(!VisualClusterUpdater.cosineSimilarity(zero, a).isNaN)
        #expect(VisualClusterUpdater.cosineSimilarity(zero, a) == 0)
        #expect(VisualClusterUpdater.cosineSimilarity(a, mismatched) == 0)
        #expect(VisualClusterUpdater.cosineSimilarity([], []) == 0)
    }

    @Test func l2NormalizedProducesUnitLengthVectors() {
        let vector: [Float] = [3, 4, 0]
        let normalized = VisualClusterUpdater.l2Normalized(vector)
        let magnitude = sqrt(normalized.reduce(Float(0)) { $0 + $1 * $1 })
        #expect(abs(magnitude - 1.0) < 0.0001)
    }

    @Test func l2NormalizedLeavesNearZeroVectorsUnchanged() {
        let degenerate: [Float] = [0, 0, 0]
        #expect(VisualClusterUpdater.l2Normalized(degenerate) == degenerate)
    }

    @Test func seedsANewCentroidPerSwipeUntilMaxClustersReached() {
        var centroids: [VisualCentroid] = []

        for i in 0..<VisualClusterUpdater.maxClusters {
            var vector = [Float](repeating: 0, count: 3)
            vector[i] = 1
            VisualClusterUpdater.update(&centroids, with: vector)
        }

        #expect(centroids.count == VisualClusterUpdater.maxClusters)
        #expect(centroids.allSatisfy { $0.weight == 1 })
    }

    @Test func nudgesNearestCentroidRatherThanSeedingBeyondMaxClusters() {
        var centroids: [VisualCentroid] = []
        // Seed exactly maxClusters distinct orthogonal-ish centroids.
        for i in 0..<VisualClusterUpdater.maxClusters {
            var vector = [Float](repeating: 0, count: VisualClusterUpdater.maxClusters)
            vector[i] = 1
            VisualClusterUpdater.update(&centroids, with: vector)
        }

        // A near-duplicate of the first centroid should nudge it, not seed
        // a fourth cluster.
        var nearDuplicate = [Float](repeating: 0, count: VisualClusterUpdater.maxClusters)
        nearDuplicate[0] = 1
        VisualClusterUpdater.update(&centroids, with: nearDuplicate)

        #expect(centroids.count == VisualClusterUpdater.maxClusters)
        #expect(centroids[0].weight == 2)
        #expect(centroids[1].weight == 1)
        #expect(centroids[2].weight == 1)
    }

    @Test func doesNotCollapseBimodalTasteIntoASingleMeaninglessCentroid() {
        // Two clearly distinct, opposite-ish "style personas" — repeatedly
        // liked — must stay as two separable centroids rather than
        // averaging into a midpoint that resembles neither.
        var centroids: [VisualCentroid] = []
        let personaA: [Float] = [1, 0, 0]
        let personaB: [Float] = [0, 1, 0]

        for _ in 0..<10 {
            VisualClusterUpdater.update(&centroids, with: personaA)
            VisualClusterUpdater.update(&centroids, with: personaB)
        }

        let similarityToA = centroids.map { VisualClusterUpdater.cosineSimilarity($0.vector, personaA) }.max() ?? 0
        let similarityToB = centroids.map { VisualClusterUpdater.cosineSimilarity($0.vector, personaB) }.max() ?? 0
        #expect(similarityToA > 0.9)
        #expect(similarityToB > 0.9)
    }

    @Test func updateIsANoOpForAnEmptyVector() {
        var centroids: [VisualCentroid] = []
        VisualClusterUpdater.update(&centroids, with: [])
        #expect(centroids.isEmpty)
    }
}
