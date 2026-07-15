//
//  SchemaV4MigrationTests.swift
//  Vision_clotherTests
//
//  Covers `Models/SchemaMigrations.swift`'s V3 -> V4 stage (Swipe-to-Learn
//  Visual Taste: `SwipeEvent`, `VisualPreferenceState`, `WardrobeItemEmbedding`)
//  — a purely additive change (three brand-new tables, no existing type
//  changes), so a pre-existing V3 row must survive migration untouched and
//  the new tables must be immediately queryable (empty) afterward. Mirrors
//  `SavedCombinationMigrationTests.swift`'s real file-backed store pattern —
//  migrations don't apply to fresh in-memory stores.
//

import Foundation
import SwiftData
import Testing
@testable import Vision_clother

struct SchemaV4MigrationTests {

    private func makeStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SchemaV4MigrationTest-\(UUID().uuidString).sqlite")
    }

    private func removeStore(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    @Test func migratesV3RowsToV4WithNewTablesEmptyAndQueryable() throws {
        let storeURL = makeStoreURL()
        defer { removeStore(at: storeURL) }

        let v3Schema = Schema(versionedSchema: SchemaV3.self)
        let v3Container = try ModelContainer(
            for: v3Schema,
            configurations: ModelConfiguration(schema: v3Schema, url: storeURL)
        )
        let v3Context = ModelContext(v3Container)

        let existing = SavedCombination(
            imageAssetName: "pre-v4.png",
            itemIDsBySlot: [.top: UUID(), .bottom: UUID()],
            labelsBySlot: [.top: "Top", .bottom: "Bottom"],
            origin: "pairing"
        )
        v3Context.insert(existing)
        try v3Context.save()
        let existingID = existing.id

        let v4Schema = Schema(versionedSchema: SchemaV4.self)
        let v4Container = try ModelContainer(
            for: v4Schema,
            migrationPlan: SavedCombinationMigrationPlan.self,
            configurations: ModelConfiguration(schema: v4Schema, url: storeURL)
        )
        let v4Context = ModelContext(v4Container)

        // Pre-existing data survives, untouched.
        let migrated = try v4Context.fetch(FetchDescriptor<SavedCombination>())
        #expect(migrated.count == 1)
        #expect(migrated.first?.id == existingID)
        #expect(migrated.first?.imageAssetName == "pre-v4.png")

        // New tables exist and are queryable (empty — nothing was ever
        // written to them under V3, since they didn't exist yet).
        #expect(try v4Context.fetch(FetchDescriptor<SwipeEvent>()).isEmpty)
        #expect(try v4Context.fetch(FetchDescriptor<VisualPreferenceState>()).isEmpty)
        #expect(try v4Context.fetch(FetchDescriptor<WardrobeItemEmbedding>()).isEmpty)

        // The new tables are also writable post-migration.
        v4Context.insert(SwipeEvent(
            sourcePhotoID: "photo-1",
            imageURLString: "https://example.com/photo-1.jpg",
            liked: true,
            embedding: [1, 0, 0]
        ))
        try v4Context.save()
        #expect(try v4Context.fetch(FetchDescriptor<SwipeEvent>()).count == 1)
    }
}
