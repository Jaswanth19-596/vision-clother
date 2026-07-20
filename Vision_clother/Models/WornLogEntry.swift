//
//  WornLogEntry.swift
//  Vision_clother
//
//  Analytics & Insights, Phase 3 — the "Wore this" quick action
//  (`Features/Combinations/CombinationsView.swift`'s leading swipe action on
//  a saved outfit row). Fills a real gap the Phase 1 architecture analysis
//  flagged: nothing in the app previously recorded actual real-world wear —
//  only recommendation-selection/rating proxies existed. Event-sourced,
//  append-only, one row per "I wore this" tap — deliberately not a
//  dedupe-by-day table, so wearing the same outfit twice in one day (or
//  logging it retroactively) both just add another row; Wardrobe Insights
//  (a later phase) decides how to bucket these, this table just records them.
//
//  Synced like every other row-per-entity user-authored type (unlike
//  `RecommendationImpressionEvent`, which is internal telemetry and stays
//  local-only) — see `Data/Sync/FirestoreDTOs.swift`'s `WornLogEntryDTO`,
//  `SyncEntityType.wornLogEntry`.
//

import Foundation
import SwiftData

@Model
final class WornLogEntry {
    @Attribute(.unique) var id: UUID
    /// The `SavedCombination.id` this wear applied to — never an ephemeral
    /// in-memory id, same rule as `OutfitFeedback.outfitID`.
    var savedCombinationID: UUID
    /// Denormalized snapshot of which items were actually worn (usually the
    /// full outfit, but kept independent of `SavedCombination.itemIDsBySlot`
    /// in case a future "I wore just the top" partial-wear action is added).
    var itemIDs: [UUID]
    var wornAt: Date

    init(id: UUID = UUID(), savedCombinationID: UUID, itemIDs: [UUID], wornAt: Date = .now) {
        self.id = id
        self.savedCombinationID = savedCombinationID
        self.itemIDs = itemIDs
        self.wornAt = wornAt
    }
}
