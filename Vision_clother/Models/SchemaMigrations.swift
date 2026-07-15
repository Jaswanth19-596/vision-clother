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
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self] }

    static var stages: [MigrationStage] { [migrateV1toV2, migrateV2toV3, migrateV3toV4] }

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
}
