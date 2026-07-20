//
//  RecommendationAnalyticsSnapshot.swift
//  Vision_clother
//
//  Analytics & Insights — internal-only Recommendation Analytics (per the
//  spec: "implemented internally but should not yet become a major
//  user-facing feature"). A low-frequency, aggregated rollup of the
//  shown/selected funnel already captured per-candidate in
//  `RecommendationImpressionEvent` (`DailyAssistantViewModel.sendTurn`/
//  `startTryOn`) — that table stays local-only and unsynced (per its own doc
//  comment) since syncing every raw impression row would be a real volume
//  risk at scale. This table syncs instead: one small row per period with
//  just the counts, giving cross-device/backend visibility into acceptance
//  rate without ever transporting per-impression detail.
//
//  Explicit fields (not an opaque JSON blob like `AnalyticsSnapshot`) since
//  this shape is small and stable — a shown/selected funnel count, not a
//  growing set of visual insights.
//

import Foundation
import SwiftData

@Model
final class RecommendationAnalyticsSnapshot {
    @Attribute(.unique) var id: UUID
    /// ISO week key, e.g. `"2026-W29"` — one row per period.
    var periodKey: String
    var shownCount: Int
    var selectedCount: Int
    var computedAt: Date

    init(id: UUID = UUID(), periodKey: String, shownCount: Int, selectedCount: Int, computedAt: Date = .now) {
        self.id = id
        self.periodKey = periodKey
        self.shownCount = shownCount
        self.selectedCount = selectedCount
        self.computedAt = computedAt
    }
}
