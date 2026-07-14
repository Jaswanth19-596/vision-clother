//
//  SavedCombination.swift
//  Vision_clother
//
//  A user-confirmed "Save this outfit?" from either the Manual Pairing or
//  Daily Assistant try-on flow. Unlike `OutfitCombination` (in-memory,
//  scoring-time only), this is the durable record: the generated preview
//  image itself (via `ImageStorage`), plus which items produced it.
//  Labels are denormalized so the Combinations tab still renders correctly
//  even if the source `WardrobeItem` is later deleted from the closet.
//
//  Slot-keyed since the 7-slot expansion (Models/SchemaMigrations.swift
//  documents the SwiftData migration from the old named-field shape).
//  Manual Pairing saves only ever populate `.top`/`.bottom`; Daily Assistant
//  saves populate every slot its source `OutfitCombination` resolved
//  (Stylist Intelligence Engine Phase 1: needed so `RateCombinationView`'s
//  Favorite/Weakest Item picker can offer every real slot in the outfit).
//

import Foundation
import SwiftData

@Model
final class SavedCombination {
    @Attribute(.unique) var id: UUID
    /// `ImageStorage` filename for the generated try-on image — resolve with
    /// `ImageStorage.url(for:)` at render time, same as `WardrobeItem.imageAssetName`.
    var imageAssetName: String
    var itemIDsBySlot: [Slot: UUID] = [:]
    var labelsBySlot: [Slot: String] = [:]
    var savedAt: Date
    /// Which flow produced this: "pairing" (Manual Pairing) or "assistant"
    /// (Daily Assistant). Plain String to stay Codable-simple — no enum column.
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

    /// Slot-order label summary for list/detail row titles, e.g. "Top + Bottom".
    var displayTitle: String {
        Slot.allCases.compactMap { labelsBySlot[$0] }.joined(separator: " + ")
    }
}
