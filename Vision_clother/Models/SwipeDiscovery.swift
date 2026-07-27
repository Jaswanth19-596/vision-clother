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

/// 4-point sentiment scale for a swipe (distance-based drag + 4-button
/// fallback, `Features/SwipeDiscovery/SwipeDiscoveryView.swift`) — replaces
/// the original flat like/dislike binary with intensity. `ratingValue` is
/// symmetric around the existing neutral 0.5 that every other affinity signal
/// in `Domain/AttributePreferenceProfile.swift` already centers on: love/hate
/// are the strongest signals, like/dislike the moderate ones (also what a
/// legacy pre-migration binary swipe maps to — see `SchemaMigrations.swift`'s
/// `migrateV15toV16`). `liked` is a back-compat computed bucket for any call
/// site that only needs the coarse direction (e.g. `Domain/InsightsSummaryBuilder.swift`
/// precedent elsewhere in the app).
enum SwipeSentiment: String, Codable, CaseIterable {
    case love, like, dislike, hate

    var ratingValue: Double {
        switch self {
        case .love: return 1.0
        case .like: return 0.75
        case .dislike: return 0.25
        case .hate: return 0.0
        }
    }

    var liked: Bool {
        switch self {
        case .love, .like: return true
        case .dislike, .hate: return false
        }
    }
}

/// One swipe on a stock fashion photo, captured in the app's **structured
/// attribute space** rather than as a pixel embedding. Where `SwipeEvent`
/// stores a `VNGenerateImageFeaturePrint` vector of the whole (often noisy,
/// background-heavy) photo, this stores one detected garment's attributes as
/// extracted by the vision LLM's scene tagging
/// (`Services/VisionMetadataExtractionService.swift`'s `extractSceneMetadata`)
/// — so a swipe teaches the same `Domain/AttributePreferenceProfile.swift`
/// affinities that item ratings and outfit feedback already drive, and thus
/// flows straight into recommendations/Insights instead of an opaque re-rank.
/// Event-sourced and append-only like `SwipeEvent`; the sentiment lives in
/// `sentiment`, the attribute *values* come from the extraction. A single
/// swiped photo now yields one row per detected garment, so the dedupe key
/// is conceptually `(sourcePhotoID, slot)`, not `sourcePhotoID` alone — a
/// full-outfit photo can (and should) produce multiple rows. Local-only for
/// now (not synced) — the derived affinities are rebuilt on read in
/// `WardrobeRepository.fetchFeedbackHistory()`.
@Model
final class SwipeAttributeEvent {
    @Attribute(.unique) var id: UUID
    /// Stock-photo id (`StockPhoto.id`) — paired with `slot` as the dedupe key
    /// so a re-shown photo isn't re-tagged (an extra LLM call) on a later
    /// deck refill.
    var sourcePhotoID: String
    var imageURLString: String
    /// `= SwipeSentiment.like` default needed for the V15->V16 schema
    /// migration to backfill a value before `willMigrate`/`didMigrate`
    /// overwrite it per legacy row — fully qualified because SwiftData's
    /// `@Model` macro can't resolve a bare `.like` shorthand default.
    var sentiment: SwipeSentiment = SwipeSentiment.like
    /// Back-compat bucket — see `SwipeSentiment.liked`.
    var liked: Bool { sentiment.liked }
    // Garment attributes extracted from the worn-in-scene photo. Mirrors the
    // subset `AttributePreferenceProfile.build`'s `RatedAttributes` reads.
    var colorVibe: ColorVibe
    var pattern: GarmentPattern
    var formalityBand: Int
    var fabricWeight: FabricWeight
    var slot: Slot
    var styleTags: [String]
    var silhouette: String?
    // Extended attribute set (added 2026-07-24, `SchemaV14`) so a swipe teaches
    // the same undertone/material/texture/fit affinities owned-item ratings do
    // — the vision LLM already extracts these, they were just being dropped.
    // All optional (`nil` for rows that predate the column or a photo whose
    // tagging couldn't classify that attribute).
    var undertone: Undertone?
    var material: String?
    var texture: String?
    var fit: String?
    /// Credit-assignment weight for this row, `1.0 / N` where `N` is the
    /// number of garments detected in the source photo — a 3-garment outfit
    /// swipe no longer injects 3x the signal of a 1-garment swipe for the
    /// same sentiment (added 2026-07-27). `= 1.0` default so pre-existing
    /// rows (all single-row-per-photo era, or otherwise already full-weight)
    /// read as full strength under SwiftData's lightweight migration.
    var weight: Double = 1.0
    var recordedAt: Date

    init(
        id: UUID = UUID(),
        sourcePhotoID: String,
        imageURLString: String,
        sentiment: SwipeSentiment,
        colorVibe: ColorVibe,
        pattern: GarmentPattern,
        formalityBand: Int,
        fabricWeight: FabricWeight,
        slot: Slot,
        styleTags: [String],
        silhouette: String?,
        undertone: Undertone? = nil,
        material: String? = nil,
        texture: String? = nil,
        fit: String? = nil,
        weight: Double = 1.0,
        recordedAt: Date = .now
    ) {
        self.id = id
        self.sourcePhotoID = sourcePhotoID
        self.imageURLString = imageURLString
        self.sentiment = sentiment
        self.colorVibe = colorVibe
        self.pattern = pattern
        self.formalityBand = formalityBand
        self.fabricWeight = fabricWeight
        self.slot = slot
        self.styleTags = styleTags
        self.silhouette = silhouette
        self.undertone = undertone
        self.material = material
        self.texture = texture
        self.fit = fit
        self.weight = weight
        self.recordedAt = recordedAt
    }
}

/// One swiped photo that showed 2+ garments — the whole-look signal
/// (`Models/SceneMetadata.swift`'s `CombinationMetadata`), separate from the
/// per-garment `SwipeAttributeEvent` rows the same swipe also produces.
/// Feeds `Domain/AttributePreferenceProfile.swift`'s `colorHarmonyAffinity`
/// and `Domain/OutfitChemistryAggregator.swift` (Chemistry Insights tab).
/// Local-only (not synced), same posture as `SwipeAttributeEvent`. Upserted
/// by `sourcePhotoID` so a re-shown photo doesn't duplicate.
@Model
final class SwipeCombinationEvent {
    @Attribute(.unique) var id: UUID
    var sourcePhotoID: String
    var sentiment: SwipeSentiment
    var colorHarmony: ColorHarmonyDescriptor
    var styleCoherenceTags: [String]
    var formalityConsistency: FormalityConsistency
    var rationale: String

    // Relational styling attributes, round 2 (added 2026-07-27) — mirrors
    // `CombinationMetadata`'s expanded schema. Optional/raw-string-backed
    // (SwiftData-storable enums, same posture as `SwipeAttributeEvent`'s
    // `undertone`) so pre-existing rows decode as `nil` under the lightweight
    // migration.
    var paletteArchetypeRaw: String?
    var contrastLevelRaw: String?
    var colorSandwiching: Bool?
    var colorDistribution: String?
    var proportionRatioRaw: String?
    var volumeBalanceRaw: String?
    var textureContrastRaw: String?
    var formalityBridgeRaw: String?
    var overallAestheticVibe: String?
    var complexityScore: Int?

    var recordedAt: Date

    init(
        id: UUID = UUID(),
        sourcePhotoID: String,
        sentiment: SwipeSentiment,
        colorHarmony: ColorHarmonyDescriptor,
        styleCoherenceTags: [String],
        formalityConsistency: FormalityConsistency,
        rationale: String,
        paletteArchetype: PaletteArchetype? = nil,
        contrastLevel: ContrastLevel? = nil,
        colorSandwiching: Bool? = nil,
        colorDistribution: String? = nil,
        proportionRatio: ProportionRatio? = nil,
        volumeBalance: VolumeBalance? = nil,
        textureContrast: TextureContrast? = nil,
        formalityBridge: FormalityBridge? = nil,
        overallAestheticVibe: String? = nil,
        complexityScore: Int? = nil,
        recordedAt: Date = .now
    ) {
        self.id = id
        self.sourcePhotoID = sourcePhotoID
        self.sentiment = sentiment
        self.colorHarmony = colorHarmony
        self.styleCoherenceTags = styleCoherenceTags
        self.formalityConsistency = formalityConsistency
        self.rationale = rationale
        self.paletteArchetypeRaw = paletteArchetype?.rawValue
        self.contrastLevelRaw = contrastLevel?.rawValue
        self.colorSandwiching = colorSandwiching
        self.colorDistribution = colorDistribution
        self.proportionRatioRaw = proportionRatio?.rawValue
        self.volumeBalanceRaw = volumeBalance?.rawValue
        self.textureContrastRaw = textureContrast?.rawValue
        self.formalityBridgeRaw = formalityBridge?.rawValue
        self.overallAestheticVibe = overallAestheticVibe
        self.complexityScore = complexityScore
        self.recordedAt = recordedAt
    }

    var paletteArchetype: PaletteArchetype? {
        paletteArchetypeRaw.flatMap(PaletteArchetype.init(rawValue:))
    }

    var contrastLevel: ContrastLevel? {
        contrastLevelRaw.flatMap(ContrastLevel.init(rawValue:))
    }

    var proportionRatio: ProportionRatio? {
        proportionRatioRaw.flatMap(ProportionRatio.init(rawValue:))
    }

    var volumeBalance: VolumeBalance? {
        volumeBalanceRaw.flatMap(VolumeBalance.init(rawValue:))
    }

    var textureContrast: TextureContrast? {
        textureContrastRaw.flatMap(TextureContrast.init(rawValue:))
    }

    var formalityBridge: FormalityBridge? {
        formalityBridgeRaw.flatMap(FormalityBridge.init(rawValue:))
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
