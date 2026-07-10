//
//  SavedCombination.swift
//  Vision_clother
//
//  A user-confirmed "Save this outfit?" from either the Manual Pairing or
//  Daily Assistant try-on flow. Unlike `OutfitCombination` (in-memory,
//  scoring-time only), this is the durable record: the generated preview
//  image itself (via `ImageStorage`), plus which top/bottom produced it.
//  Labels are denormalized so the Combinations tab still renders correctly
//  even if the source `WardrobeItem` is later deleted from the closet.
//

import Foundation
import SwiftData

@Model
final class SavedCombination {
    @Attribute(.unique) var id: UUID
    /// `ImageStorage` filename for the generated try-on image — resolve with
    /// `ImageStorage.url(for:)` at render time, same as `WardrobeItem.imageAssetName`.
    var imageAssetName: String
    var topItemID: UUID
    var bottomItemID: UUID
    var topLabel: String
    var bottomLabel: String
    /// `nil` for Manual Pairing saves, which only ever select a top+bottom —
    /// populated for Daily Assistant saves, whose source `OutfitCombination`
    /// always resolves a footwear item (Stylist Intelligence Engine Phase 1:
    /// needed so `RateCombinationView`'s Favorite/Weakest Item picker can
    /// offer every real slot in the outfit, not just top/bottom).
    var footwearItemID: UUID?
    var footwearLabel: String?
    /// `nil` when the outfit had no outerwear (optional slot even for Daily
    /// Assistant saves).
    var outerwearItemID: UUID?
    var outerwearLabel: String?
    var savedAt: Date
    /// Which flow produced this: "pairing" (Manual Pairing) or "assistant"
    /// (Daily Assistant). Plain String to stay Codable-simple — no enum column.
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
