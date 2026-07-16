//
//  SwipeDiscovery.swift
//  Vision_clother
//
//  Swipe-to-Learn Visual Taste: append-only swipe history plus the learned
//  visual-taste state derived from it. Backed by SwiftData (CLAUDE.md
//  guardrail #3). Mirrors the `ItemRating`/`UserStyleProfile` split:
//  `SwipeEvent` is event-sourced audit/recovery history, `VisualPreferenceState`
//  is the single-row upsert `Data/WardrobeRepository.swift.fetchFeedbackHistory()`
//  actually reads at recommendation time — see `Domain/VisualPreferenceProfile.swift`
//  for the pure math this state feeds.
//

import Foundation
import SwiftData

/// One like/dislike swipe on a stock fashion photo
/// (`Services/StockImageFeedService.swift`). Event-sourced like
/// `Models/FeedbackEvent.swift`'s tables — append-only, never mutated — so
/// the k-means state in `VisualPreferenceState` can be rebuilt from scratch
/// if it's ever lost or corrupted (`VisualPreferenceProfile.build(from:dislikedEmbeddings:)`).
@Model
final class SwipeEvent {
    @Attribute(.unique) var id: UUID
    var sourcePhotoID: String
    var imageURLString: String
    var liked: Bool
    /// L2-normalized embedding from `ImageEmbeddingService` — same raw
    /// representation as `WardrobeItemEmbedding.vector`.
    var embedding: [Float]
    var recordedAt: Date

    init(
        id: UUID = UUID(),
        sourcePhotoID: String,
        imageURLString: String,
        liked: Bool,
        embedding: [Float],
        recordedAt: Date = .now
    ) {
        self.id = id
        self.sourcePhotoID = sourcePhotoID
        self.imageURLString = imageURLString
        self.liked = liked
        self.embedding = embedding
        self.recordedAt = recordedAt
    }
}

/// One k-means centroid on the liked or disliked side of a
/// `VisualPreferenceState` — plain `Codable` value type embedded on the
/// model, same posture as `WardrobeItem.colorProfile`. `weight` is the
/// running count of swipes folded into this centroid so far, needed by
/// `VisualClusterUpdater`'s incremental mean-update formula
/// (`c += (1/weight) * (x - c)`).
struct VisualCentroid: Codable, Hashable {
    var vector: [Float]
    var weight: Double
}

/// Single-row upsert of the user's learned visual taste (mirrors
/// `UserStyleProfile`'s "one row" posture) — what
/// `WardrobeRepository.fetchFeedbackHistory()` reads at recommendation time,
/// updated incrementally by `recordSwipe` rather than replayed from
/// `SwipeEvent` on every read.
@Model
final class VisualPreferenceState {
    @Attribute(.unique) var id: UUID
    var likedCentroids: [VisualCentroid]
    var dislikedCentroids: [VisualCentroid]
    var embeddingDimension: Int
    var updatedAt: Date
    /// Count of *explicit* deck swipes only (`recordSwipe`) — not nudged by
    /// `applyImplicitSwipe`'s rating-derived updates, which are a gentler,
    /// ambient signal rather than a deliberate taste-calibration action.
    /// Drives `calibrationProgress`/`isTrained` below. The inline `= 0`
    /// (not just the initializer default) is required so SwiftData's
    /// lightweight V4->V5 migration (`Models/SchemaMigrations.swift`) can
    /// infer a backfill value for rows that predate this column — same
    /// pattern as `SchemaV2.SavedCombination.itemIDsBySlot: [Slot: UUID] = [:]`.
    var totalSwipes: Int = 0

    init(
        id: UUID = UUID(),
        likedCentroids: [VisualCentroid] = [],
        dislikedCentroids: [VisualCentroid] = [],
        embeddingDimension: Int = 0,
        updatedAt: Date = .now,
        totalSwipes: Int = 0
    ) {
        self.id = id
        self.likedCentroids = likedCentroids
        self.dislikedCentroids = dislikedCentroids
        self.embeddingDimension = embeddingDimension
        self.updatedAt = updatedAt
        self.totalSwipes = totalSwipes
    }

    /// Gamified calibration meter for `Features/SwipeDiscovery/`'s progress
    /// ring — linear in `totalSwipes` up to the 20-swipe `isTrained`
    /// threshold, capped at 1.0 rather than exposing the raw count (which
    /// could keep climbing past 20 and read as "over 100%" in the UI).
    var calibrationProgress: Double {
        min(Double(totalSwipes) / 20.0, 1.0)
    }

    /// Whether the deck has seen enough explicit swipes for the visual-taste
    /// centroids to be considered calibrated. Simple threshold on
    /// `calibrationProgress` — see docs/decisions/stylist-intelligence-engine.md
    /// for why this doesn't also gate on update "stability."
    var isTrained: Bool {
        calibrationProgress >= 1.0
    }
}

/// Cached embedding for one `WardrobeItem`'s photo — a sidecar table, not a
/// field on `WardrobeItem` itself, so the hot/widely-touched item type stays
/// unbloated (same reasoning that already kept `ItemRating` a separate model
/// from `ItemFeedback`). Recomputing an embedding is cheap (on-device Vision,
/// no network) but not free, so this cache is invalidated by
/// `sourceFingerprint` (`ImageStorage.fingerprint`) rather than recomputed on
/// every fetch.
@Model
final class WardrobeItemEmbedding {
    @Attribute(.unique) var itemID: UUID
    var vector: [Float]
    var sourceFingerprint: String
    var computedAt: Date

    init(
        itemID: UUID,
        vector: [Float],
        sourceFingerprint: String,
        computedAt: Date = .now
    ) {
        self.itemID = itemID
        self.vector = vector
        self.sourceFingerprint = sourceFingerprint
        self.computedAt = computedAt
    }
}
