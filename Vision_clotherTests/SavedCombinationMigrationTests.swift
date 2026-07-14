//
//  SavedCombinationMigrationTests.swift
//  Vision_clotherTests
//
//  Covers `Models/SchemaMigrations.swift` — this app's first SwiftData
//  schema migration, converting `SavedCombination`'s old named
//  top/bottom/footwear/outerwear fields into the slot-keyed
//  `itemIDsBySlot`/`labelsBySlot` shape. Uses a real file-backed store
//  (migrations don't apply to fresh in-memory stores, which have no prior
//  data to migrate) seeded under `SchemaV1`, then reopened under `SchemaV2`
//  with `SavedCombinationMigrationPlan` to force the migration to run.
//

import Foundation
import SwiftData
import Testing
@testable import Vision_clother

struct SavedCombinationMigrationTests {

    private func makeStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SavedCombinationMigrationTest-\(UUID().uuidString).sqlite")
    }

    private func removeStore(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    @Test func migratesLegacyNamedFieldsIntoSlotKeyedDictionaries() throws {
        let storeURL = makeStoreURL()
        defer { removeStore(at: storeURL) }

        // 1. Seed a v1-shaped store with the old named fields.
        let v1Schema = Schema(versionedSchema: SchemaV1.self)
        let v1Container = try ModelContainer(
            for: v1Schema,
            configurations: ModelConfiguration(schema: v1Schema, url: storeURL)
        )
        let v1Context = ModelContext(v1Container)

        let footwearID = UUID()
        let outerwearID = UUID()
        let legacy = SchemaV1.SavedCombination(
            imageAssetName: "legacy.png",
            topItemID: UUID(),
            bottomItemID: UUID(),
            topLabel: "Legacy Top",
            bottomLabel: "Legacy Bottom",
            footwearItemID: footwearID,
            footwearLabel: "Legacy Shoe",
            outerwearItemID: outerwearID,
            outerwearLabel: "Legacy Jacket",
            origin: "assistant"
        )
        v1Context.insert(legacy)
        try v1Context.save()
        let legacyID = legacy.id
        let legacyTopID = legacy.topItemID
        let legacyBottomID = legacy.bottomItemID

        // 2. Reopen the *same* store under SchemaV2 + the migration plan —
        // this is what actually triggers the custom migration stage.
        let v2Schema = Schema(versionedSchema: SchemaV2.self)
        let v2Container = try ModelContainer(
            for: v2Schema,
            migrationPlan: SavedCombinationMigrationPlan.self,
            configurations: ModelConfiguration(schema: v2Schema, url: storeURL)
        )
        let v2Context = ModelContext(v2Container)

        let migrated = try v2Context.fetch(FetchDescriptor<SavedCombination>())
        #expect(migrated.count == 1)
        let combo = try #require(migrated.first)

        #expect(combo.id == legacyID)
        #expect(combo.imageAssetName == "legacy.png")
        #expect(combo.origin == "assistant")
        #expect(combo.itemIDsBySlot[.top] == legacyTopID)
        #expect(combo.itemIDsBySlot[.bottom] == legacyBottomID)
        #expect(combo.itemIDsBySlot[.footwear] == footwearID)
        #expect(combo.itemIDsBySlot[.outerwear] == outerwearID)
        #expect(combo.labelsBySlot[.top] == "Legacy Top")
        #expect(combo.labelsBySlot[.bottom] == "Legacy Bottom")
        #expect(combo.labelsBySlot[.footwear] == "Legacy Shoe")
        #expect(combo.labelsBySlot[.outerwear] == "Legacy Jacket")
    }

    @Test func migratesAPairingSaveThatNeverPopulatedFootwearOrOuterwear() throws {
        // Manual Pairing saves only ever set top/bottom — the migration must
        // not synthesize footwear/outerwear entries for those rows.
        let storeURL = makeStoreURL()
        defer { removeStore(at: storeURL) }

        let v1Schema = Schema(versionedSchema: SchemaV1.self)
        let v1Container = try ModelContainer(
            for: v1Schema,
            configurations: ModelConfiguration(schema: v1Schema, url: storeURL)
        )
        let v1Context = ModelContext(v1Container)

        let legacy = SchemaV1.SavedCombination(
            imageAssetName: "pairing.png",
            topItemID: UUID(),
            bottomItemID: UUID(),
            topLabel: "Top",
            bottomLabel: "Bottom",
            origin: "pairing"
        )
        v1Context.insert(legacy)
        try v1Context.save()

        let v2Schema = Schema(versionedSchema: SchemaV2.self)
        let v2Container = try ModelContainer(
            for: v2Schema,
            migrationPlan: SavedCombinationMigrationPlan.self,
            configurations: ModelConfiguration(schema: v2Schema, url: storeURL)
        )
        let v2Context = ModelContext(v2Container)

        let migrated = try v2Context.fetch(FetchDescriptor<SavedCombination>())
        let combo = try #require(migrated.first)

        #expect(combo.itemIDsBySlot.count == 2)
        #expect(combo.itemIDsBySlot[.footwear] == nil)
        #expect(combo.itemIDsBySlot[.outerwear] == nil)
    }

    @Test func migratesV2RowsToV3WithNoBasePortraitFingerprint() throws {
        // V2 -> V3 only adds `basePortraitFingerprint` (an optional column
        // powering `Services/CachedTryOnRenderService.swift`) — a purely
        // additive change, so a pre-existing row must survive with the field
        // `nil` rather than the migration crashing or fabricating a value.
        let storeURL = makeStoreURL()
        defer { removeStore(at: storeURL) }

        let v2Schema = Schema(versionedSchema: SchemaV2.self)
        let v2Container = try ModelContainer(
            for: v2Schema,
            configurations: ModelConfiguration(schema: v2Schema, url: storeURL)
        )
        let v2Context = ModelContext(v2Container)

        let existing = SavedCombination(
            imageAssetName: "pre-migration.png",
            itemIDsBySlot: [.top: UUID(), .bottom: UUID()],
            labelsBySlot: [.top: "Top", .bottom: "Bottom"],
            origin: "pairing"
        )
        v2Context.insert(existing)
        try v2Context.save()
        let existingID = existing.id

        let v3Schema = Schema(versionedSchema: SchemaV3.self)
        let v3Container = try ModelContainer(
            for: v3Schema,
            migrationPlan: SavedCombinationMigrationPlan.self,
            configurations: ModelConfiguration(schema: v3Schema, url: storeURL)
        )
        let v3Context = ModelContext(v3Container)

        let migrated = try v3Context.fetch(FetchDescriptor<SavedCombination>())
        #expect(migrated.count == 1)
        let combo = try #require(migrated.first)

        #expect(combo.id == existingID)
        #expect(combo.imageAssetName == "pre-migration.png")
        #expect(combo.basePortraitFingerprint == nil)
    }
}
