//
//  VisualPreferenceProfile.swift
//  Vision_clother
//
//  Swipe-to-Learn Visual Taste: the pure math for turning a stream of
//  liked/disliked photo embeddings (`Services/ImageEmbeddingService.swift`)
//  into a small number of "style persona" centroids per side, and scoring a
//  candidate wardrobe item's embedding against them. Pure, no I/O, NaN-safe
//  for empty input (Domain/CLAUDE.md) — mirrors
//  `Domain/AttributePreferenceProfile.swift`'s bias-not-filter posture: an
//  untrained profile (no swipes yet) returns 0 bonus for everything, so
//  `OutfitRecommendationEngine.outfitScore` is unchanged until the user
//  actually swipes.
//

import Foundation

/// Online mini-batch k-means: seeds up to `maxClusters` centroids (one per
/// distinct early swipe) then nudges the nearest one toward every subsequent
/// point, rather than collapsing all swipes into one running mean. A small
/// fixed K avoids averaging away genuinely bimodal taste (e.g. "goth-grunge"
/// and "pastel-preppy" liked photos both landing in the same feed) into a
/// meaningless midpoint vector.
enum VisualClusterUpdater {
    /// Centroids per side (liked/disliked) — enough to capture a few
    /// distinct "style personas" without needing real clustering
    /// hyperparameter tuning for a v1 feature.
    static let maxClusters = 3

    /// Normalizes to unit length so cosine similarity reduces to a plain dot
    /// product everywhere downstream. A near-zero vector (degenerate input)
    /// is returned unchanged rather than divided by ~0, avoiding NaN
    /// propagation. Shared by `VisionFeaturePrintEmbeddingService` (raw
    /// embedding extraction) and `update` below (re-normalizing a nudged
    /// centroid) — kept here rather than in `Services/` since `Domain/` must
    /// never depend on `Services/` (Domain/CLAUDE.md), and this is pure math.
    static func l2Normalized(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard magnitude > 1e-6 else { return vector }
        return vector.map { $0 / magnitude }
    }

    /// Cosine similarity between two vectors, in `[-1, 1]`. NaN-safe: either
    /// vector's magnitude may be zero (a degenerate/untrained embedding), in
    /// which case similarity is defined as 0 rather than dividing by zero.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var magA: Float = 0
        var magB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denominator = sqrt(magA) * sqrt(magB)
        guard denominator > 1e-6 else { return 0 }
        return Double(dot / denominator)
    }

    /// Folds one new embedding into `centroids`, mutating it in place: seeds
    /// a fresh centroid (weight 1) while under `maxClusters`, otherwise
    /// nudges the nearest existing centroid toward the new point
    /// (`c += (1/weight) * (x - c)`, an incremental running mean for that
    /// cluster) and re-normalizes so cosine scoring stays meaningful.
    static func update(_ centroids: inout [VisualCentroid], with vector: [Float]) {
        guard !vector.isEmpty else { return }

        if centroids.count < maxClusters {
            centroids.append(VisualCentroid(vector: vector, weight: 1))
            return
        }

        var bestIndex = 0
        var bestSimilarity = -Double.infinity
        for (index, centroid) in centroids.enumerated() {
            let similarity = cosineSimilarity(centroid.vector, vector)
            if similarity > bestSimilarity {
                bestSimilarity = similarity
                bestIndex = index
            }
        }

        var nearest = centroids[bestIndex]
        nearest.weight += 1
        let step = Float(1.0 / nearest.weight)
        var updated = nearest.vector
        if updated.count == vector.count {
            for i in 0..<updated.count {
                let delta: Float = step * (vector[i] - updated[i])
                updated[i] += delta
            }
        } else {
            // Dimension mismatch (e.g. the embedding model was swapped
            // mid-history) — reseed rather than crash or silently corrupt
            // the centroid.
            updated = vector
        }
        nearest.vector = Self.l2Normalized(updated)
        centroids[bestIndex] = nearest
    }
}

/// Learned visual taste: up to `VisualClusterUpdater.maxClusters` centroids
/// per side, re-ranking candidate items by how close a cached embedding
/// (`Models/SwipeDiscovery.swift`'s `WardrobeItemEmbedding`) is to the liked
/// centroids versus the disliked ones.
struct VisualPreferenceProfile {
    var likedCentroids: [VisualCentroid] = []
    var dislikedCentroids: [VisualCentroid] = []

    /// Bounds how far this bonus can push a score — same magnitude and
    /// rationale as `AttributePreferenceProfile.maxBonusMagnitude`: visual
    /// taste can re-rank candidates but never overwhelm the deterministic
    /// aesthetic prior or the existing preference terms.
    static let maxBonusMagnitude: Double = 0.3

    /// How much more a disliked-side match is penalized relative to how much
    /// a liked-side match is rewarded — >1 so a strong dislike match can
    /// outweigh an equally strong liked match, matching a left swipe being
    /// at least as strong a signal as a right swipe.
    static let dislikePenaltyWeight: Double = 1.2

    /// Bounded, NaN-safe bias term for one item's embedding, centered at 0
    /// (neutral). `nil`/empty embedding (no cached photo yet — including
    /// ghost elements, which never have one) returns 0: the natural,
    /// non-special-cased way ghost elements score through the identical path
    /// as real items (Domain/CLAUDE.md) — they simply never have an
    /// embedding to score against.
    func affinityBonus(forEmbedding embedding: [Float]?) -> Double {
        guard let embedding, !embedding.isEmpty else { return 0 }
        guard !likedCentroids.isEmpty || !dislikedCentroids.isEmpty else { return 0 }

        let likedMax = likedCentroids
            .map { VisualClusterUpdater.cosineSimilarity($0.vector, embedding) }
            .max() ?? 0
        let dislikedMax = dislikedCentroids
            .map { VisualClusterUpdater.cosineSimilarity($0.vector, embedding) }
            .max() ?? 0

        let raw = likedMax - Self.dislikePenaltyWeight * dislikedMax
        // Cosine similarity is already bounded to [-1, 1]; scale directly
        // into the bonus's magnitude rather than clamping a much larger raw
        // value.
        return (raw * Self.maxBonusMagnitude).clamped(to: -Self.maxBonusMagnitude...Self.maxBonusMagnitude)
    }

    /// Offline reconstruction from a flat list of liked/disliked embeddings —
    /// used by tests and as a recovery path if `VisualPreferenceState` is
    /// ever lost while `SwipeEvent` history survives (both are event-sourced,
    /// see `Models/SwipeDiscovery.swift`). Runs the same incremental
    /// `VisualClusterUpdater.update` in swipe order, so replaying history
    /// reproduces the same centroids the incremental `recordSwipe` path
    /// would have produced.
    static func build(from likedEmbeddings: [[Float]], dislikedEmbeddings: [[Float]]) -> VisualPreferenceProfile {
        var profile = VisualPreferenceProfile()
        for vector in likedEmbeddings {
            VisualClusterUpdater.update(&profile.likedCentroids, with: vector)
        }
        for vector in dislikedEmbeddings {
            VisualClusterUpdater.update(&profile.dislikedCentroids, with: vector)
        }
        return profile
    }
}
