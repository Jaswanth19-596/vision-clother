//
//  SchemaMigrations.swift
//  Vision_clother
//
//  This app's first SwiftData `SchemaMigrationPlan`. Only `SavedCombination`
//  changed shape (named top/bottom/footwear/outerwear fields -> slot-keyed
//  dictionaries, part of the headwear/accessory/bag slot expansion); the
//  other six `@Model` types are unchanged and are referenced directly by
//  both schema versions, per SwiftData's versioning model (a type only needs
//  a version-specific redeclaration when its own shape changes).
//
//  `SchemaV1.SavedCombination` is a frozen snapshot of the pre-migration
//  shape purely so `.custom`'s `willMigrate` closure can read the old
//  columns before they're dropped — it must never be edited to track the
//  live `SavedCombination` type.
//

import Foundation
import SwiftData

enum SchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            WardrobeItem.self,
            OutfitFeedback.self,
            ItemFeedback.self,
            PairFeedback.self,
            SavedCombination.self,
            ItemRating.self,
            UserStyleProfile.self,
        ]
    }

    @Model
    final class SavedCombination {
        @Attribute(.unique) var id: UUID
        var imageAssetName: String
        var topItemID: UUID
        var bottomItemID: UUID
        var topLabel: String
        var bottomLabel: String
        var footwearItemID: UUID?
        var footwearLabel: String?
        var outerwearItemID: UUID?
        var outerwearLabel: String?
        var savedAt: Date
        var origin: String

        init(
            id: UUID = UUID(),
            imageAssetName: String,
            topItemID: UUID,
            bottomItemID: UUID,
            topLabel: String,
            bottomLabel: String,
            footwearItemID: UUID? = nil,
            footwearLabel: String? = nil,
            outerwearItemID: UUID? = nil,
            outerwearLabel: String? = nil,
            savedAt: Date = .now,
            origin: String
        ) {
            self.id = id
            self.imageAssetName = imageAssetName
            self.topItemID = topItemID
            self.bottomItemID = bottomItemID
            self.topLabel = topLabel
            self.bottomLabel = bottomLabel
            self.footwearItemID = footwearItemID
            self.footwearLabel = footwearLabel
            self.outerwearItemID = outerwearItemID
            self.outerwearLabel = outerwearLabel
            self.savedAt = savedAt
            self.origin = origin
        }
    }
}

enum SchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            WardrobeItem.self,
            OutfitFeedback.self,
            ItemFeedback.self,
            PairFeedback.self,
            SavedCombination.self,
            ItemRating.self,
            UserStyleProfile.self,
        ]
    }

    /// Frozen snapshot of the post-`.custom`-migration, pre-`basePortraitFingerprint`
    /// shape — same reason `SchemaV1.SavedCombination` exists: SwiftData computes a
    /// `VersionedSchema`'s checksum from its own `models` array, so if this schema
    /// version's `SavedCombination.self` resolved to the live (current, V3) class
    /// instead of this nested one, SchemaV2 and SchemaV3 would produce byte-identical
    /// checksums and SwiftData throws "Duplicate version checksums across stages
    /// detected" at migration-plan validation time. Must never be edited to track the
    /// live `SavedCombination` type.
    @Model
    final class SavedCombination {
        @Attribute(.unique) var id: UUID
        var imageAssetName: String
        var itemIDsBySlot: [Slot: UUID] = [:]
        var labelsBySlot: [Slot: String] = [:]
        var savedAt: Date
        var origin: String

        init(
            id: UUID = UUID(),
            imageAssetName: String,
            itemIDsBySlot: [Slot: UUID],
            labelsBySlot: [Slot: String],
            savedAt: Date = .now,
            origin: String
        ) {
            self.id = id
            self.imageAssetName = imageAssetName
            self.itemIDsBySlot = itemIDsBySlot
            self.labelsBySlot = labelsBySlot
            self.savedAt = savedAt
            self.origin = origin
        }
    }
}

/// V2 -> V3 only adds `SavedCombination.basePortraitFingerprint` (an
/// optional column, powering `Services/CachedTryOnRenderService.swift`) — a
/// purely additive change, so unlike V1 -> V2 this needs no `.custom` stage
/// to backfill data; `.lightweight` lets SwiftData infer the migration.
enum SchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            WardrobeItem.self,
            OutfitFeedback.self,
            ItemFeedback.self,
            PairFeedback.self,
            SavedCombination.self,
            ItemRating.self,
            UserStyleProfile.self,
        ]
    }
}

/// V3 -> V4 adds three brand-new, independent tables (`SwipeEvent`,
/// `VisualPreferenceState`, `WardrobeItemEmbedding` — Swipe-to-Learn Visual
/// Taste) with zero changes to any existing V3 type, so like V2 -> V3 this
/// needs no `.custom` stage — `.lightweight` lets SwiftData infer the
/// migration.
enum SchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            WardrobeItem.self,
            OutfitFeedback.self,
            ItemFeedback.self,
            PairFeedback.self,
            SavedCombination.self,
            ItemRating.self,
            UserStyleProfile.self,
            SwipeEvent.self,
            VisualPreferenceState.self,
            WardrobeItemEmbedding.self,
        ]
    }

    /// Frozen pre-`totalSwipes` snapshot — same reason `SchemaV2.SavedCombination`
    /// exists: this schema version already shipped (2026-07-14's swipe-deck
    /// commit), so its checksum must keep reflecting the shape actually on
    /// disk. Must never be edited to track the live `VisualPreferenceState` type.
    /// Nested (not top-level), same as `SchemaV1.SavedCombination` — Swift
    /// resolves the unqualified `VisualPreferenceState.self` reference in
    /// `models` above to *this* nested type, not the live top-level one.
    @Model
    final class VisualPreferenceState {
        @Attribute(.unique) var id: UUID
        var likedCentroids: [VisualCentroid]
        var dislikedCentroids: [VisualCentroid]
        var embeddingDimension: Int
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            likedCentroids: [VisualCentroid] = [],
            dislikedCentroids: [VisualCentroid] = [],
            embeddingDimension: Int = 0,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.likedCentroids = likedCentroids
            self.dislikedCentroids = dislikedCentroids
            self.embeddingDimension = embeddingDimension
            self.updatedAt = updatedAt
        }
    }
}

/// V4 -> V5 adds `VisualPreferenceState.totalSwipes` (Swipe-to-Learn
/// calibration meter, 2026-07-15) — a purely additive `Int` column with a
/// simple `= 0` default, so like V2 -> V3 this needs no `.custom` stage;
/// `.lightweight` lets SwiftData infer the migration and every pre-existing
/// row reads as "0 swipes so far," which is correct (they predate this
/// counter entirely).
enum SchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(5, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            WardrobeItem.self,
            OutfitFeedback.self,
            ItemFeedback.self,
            PairFeedback.self,
            SavedCombination.self,
            ItemRating.self,
            UserStyleProfile.self,
            SwipeEvent.self,
            VisualPreferenceState.self,
            WardrobeItemEmbedding.self,
        ]
    }
}

/// V5 -> V6 adds one brand-new, independent table (`RecommendationImpressionEvent`
/// — Impression/Selection Event Capture) with zero changes to any existing V5
/// type, so like V3 -> V4 this needs no `.custom` stage; `.lightweight` lets
/// SwiftData infer the migration.
enum SchemaV6: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(6, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            WardrobeItem.self,
            OutfitFeedback.self,
            ItemFeedback.self,
            PairFeedback.self,
            SavedCombination.self,
            ItemRating.self,
            UserStyleProfile.self,
            SwipeEvent.self,
            VisualPreferenceState.self,
            WardrobeItemEmbedding.self,
            RecommendationImpressionEvent.self,
        ]
    }

    /// Frozen pre-`changeReasonsRaw` snapshot — same reason
    /// `SchemaV4.VisualPreferenceState` exists: this schema version already
    /// shipped (Impression/Selection Event Capture), so its checksum must
    /// keep reflecting the shape actually on disk. Must never be edited to
    /// track the live `OutfitFeedback` type. Nested (not top-level), same as
    /// `SchemaV1.SavedCombination` — Swift resolves the unqualified
    /// `OutfitFeedback.self` reference in `models` above to *this* nested
    /// type, not the live top-level one.
    @Model
    final class OutfitFeedback {
        @Attribute(.unique) var id: UUID
        var outfitID: UUID
        var likedOverall: Bool
        var recordedAt: Date
        var overallSatisfaction: Int?
        var wearAgainRaw: String?
        var confidence: Int?
        var comfort: Int?
        var occasionMatch: Int?
        var styleMatch: Int?
        var colorHarmony: Int?
        var silhouette: Int?
        var weatherSuitability: Int?
        var practicality: Int?
        var favoriteItemID: UUID?
        var weakestItemID: UUID?

        init(
            id: UUID = UUID(),
            outfitID: UUID,
            likedOverall: Bool,
            recordedAt: Date = .now,
            overallSatisfaction: Int? = nil,
            wearAgainRaw: String? = nil,
            confidence: Int? = nil,
            comfort: Int? = nil,
            occasionMatch: Int? = nil,
            styleMatch: Int? = nil,
            colorHarmony: Int? = nil,
            silhouette: Int? = nil,
            weatherSuitability: Int? = nil,
            practicality: Int? = nil,
            favoriteItemID: UUID? = nil,
            weakestItemID: UUID? = nil
        ) {
            self.id = id
            self.outfitID = outfitID
            self.likedOverall = likedOverall
            self.recordedAt = recordedAt
            self.overallSatisfaction = overallSatisfaction
            self.wearAgainRaw = wearAgainRaw
            self.confidence = confidence
            self.comfort = comfort
            self.occasionMatch = occasionMatch
            self.styleMatch = styleMatch
            self.colorHarmony = colorHarmony
            self.silhouette = silhouette
            self.weatherSuitability = weatherSuitability
            self.practicality = practicality
            self.favoriteItemID = favoriteItemID
            self.weakestItemID = weakestItemID
        }
    }
}

/// V6 -> V7 adds `OutfitFeedback.changeReasonsRaw` (Level 3 "What would you
/// change?" checklist, Stylist Intelligence Engine ADR) — a purely additive
/// `[String]` column with a `= []` default, so like V4 -> V5 this needs no
/// `.custom` stage; `.lightweight` lets SwiftData infer the migration and
/// every pre-existing row reads as "nothing flagged," which is correct (they
/// predate this checklist entirely).
enum SchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(7, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            WardrobeItem.self,
            OutfitFeedback.self,
            ItemFeedback.self,
            PairFeedback.self,
            SavedCombination.self,
            ItemRating.self,
            UserStyleProfile.self,
            SwipeEvent.self,
            VisualPreferenceState.self,
            WardrobeItemEmbedding.self,
            RecommendationImpressionEvent.self,
        ]
    }

    /// Frozen pre-supplementary-accessory snapshot — same reason
    /// `SchemaV6.OutfitFeedback` exists: this schema version already
    /// shipped (Level 3 "What would you change?" checklist), so its
    /// checksum must keep reflecting the shape actually on disk. Must never
    /// be edited to track the live `SavedCombination` type.
    @Model
    final class SavedCombination {
        @Attribute(.unique) var id: UUID
        var imageAssetName: String
        var itemIDsBySlot: [Slot: UUID] = [:]
        var labelsBySlot: [Slot: String] = [:]
        var savedAt: Date
        var origin: String
        var basePortraitFingerprint: String?

        init(
            id: UUID = UUID(),
            imageAssetName: String,
            itemIDsBySlot: [Slot: UUID],
            labelsBySlot: [Slot: String],
            savedAt: Date = .now,
            origin: String,
            basePortraitFingerprint: String? = nil
        ) {
            self.id = id
            self.imageAssetName = imageAssetName
            self.itemIDsBySlot = itemIDsBySlot
            self.labelsBySlot = labelsBySlot
            self.savedAt = savedAt
            self.origin = origin
            self.basePortraitFingerprint = basePortraitFingerprint
        }
    }
}

/// V7 -> V8 adds `SavedCombination.supplementaryAccessoryItemIDs`/
/// `supplementaryAccessoryLabels` (Multi-Accessory Outfits, Stylist
/// Intelligence Engine ADR) — purely additive `[UUID]`/`[String]` columns
/// with `= []` defaults, so like V6 -> V7 this needs no `.custom` stage;
/// `.lightweight` lets SwiftData infer the migration and every pre-existing
/// row reads as "no supplementary accessories," which is correct (they
/// predate this feature entirely).
enum SchemaV8: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(8, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            WardrobeItem.self,
            OutfitFeedback.self,
            ItemFeedback.self,
            PairFeedback.self,
            SavedCombination.self,
            ItemRating.self,
            UserStyleProfile.self,
            SwipeEvent.self,
            VisualPreferenceState.self,
            WardrobeItemEmbedding.self,
            RecommendationImpressionEvent.self,
        ]
    }
}

/// Bridges data across the `willMigrate`/`didMigrate` boundary of the
/// `.custom` stage below: `willMigrate` runs against the still-V1-shaped
/// store (old columns present, new ones absent), `didMigrate` runs after the
/// structural migration (new columns present, old ones dropped) — this cache
/// is the only way to carry derived values from one side to the other since
/// the two closures don't share local state.
private enum SavedCombinationMigrationCache {
    static var pendingSlotData: [UUID: (items: [Slot: UUID], labels: [Slot: String])] = [:]
}

enum SavedCombinationMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self, SchemaV5.self, SchemaV6.self, SchemaV7.self, SchemaV8.self] }

    static var stages: [MigrationStage] { [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5, migrateV5toV6, migrateV6toV7, migrateV7toV8] }

    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self,
        willMigrate: { context in
            let oldCombinations = try context.fetch(FetchDescriptor<SchemaV1.SavedCombination>())
            for combo in oldCombinations {
                var items: [Slot: UUID] = [.top: combo.topItemID, .bottom: combo.bottomItemID]
                var labels: [Slot: String] = [.top: combo.topLabel, .bottom: combo.bottomLabel]
                if let footwearItemID = combo.footwearItemID {
                    items[.footwear] = footwearItemID
                }
                if let footwearLabel = combo.footwearLabel {
                    labels[.footwear] = footwearLabel
                }
                if let outerwearItemID = combo.outerwearItemID {
                    items[.outerwear] = outerwearItemID
                }
                if let outerwearLabel = combo.outerwearLabel {
                    labels[.outerwear] = outerwearLabel
                }
                SavedCombinationMigrationCache.pendingSlotData[combo.id] = (items, labels)
            }
        },
        didMigrate: { context in
            let migratedCombinations = try context.fetch(FetchDescriptor<SchemaV2.SavedCombination>())
            for combo in migratedCombinations {
                guard let data = SavedCombinationMigrationCache.pendingSlotData[combo.id] else { continue }
                combo.itemIDsBySlot = data.items
                combo.labelsBySlot = data.labels
            }
            try context.save()
            SavedCombinationMigrationCache.pendingSlotData.removeAll()
        }
    )

    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: SchemaV2.self,
        toVersion: SchemaV3.self
    )

    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: SchemaV3.self,
        toVersion: SchemaV4.self
    )

    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: SchemaV4.self,
        toVersion: SchemaV5.self
    )

    static let migrateV5toV6 = MigrationStage.lightweight(
        fromVersion: SchemaV5.self,
        toVersion: SchemaV6.self
    )

    static let migrateV6toV7 = MigrationStage.lightweight(
        fromVersion: SchemaV6.self,
        toVersion: SchemaV7.self
    )

    static let migrateV7toV8 = MigrationStage.lightweight(
        fromVersion: SchemaV7.self,
        toVersion: SchemaV8.self
    )
}
