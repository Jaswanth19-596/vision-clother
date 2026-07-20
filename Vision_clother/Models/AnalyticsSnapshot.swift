//
//  AnalyticsSnapshot.swift
//  Vision_clother
//
//  Analytics & Insights — Phase 2 infra. `Domain/AnalyticsAggregator.swift`
//  (later phase) computes every insight on-device from data already local
//  (`WardrobeItem`, `ItemRating`, `OutfitFeedback`, etc.); this table is
//  purely a durable cache of that computation's result, keyed by the period
//  it covers, so a cold app launch or a second device gets an instant
//  first-paint before its own recompute finishes — not a server-computed
//  aggregation pipeline (see the Analytics & Insights plan's "compute
//  on-device, sync snapshots" decision).
//
//  `payloadJSON` is an opaque JSON blob rather than typed columns
//  deliberately — the set of metrics this feature computes grows over
//  several phases (favorite colors, trends, Style DNA, ...), and a typed
//  schema would need a SwiftData migration every time a new metric is added.
//  Decoding happens in `Domain/`, this model never interprets its contents.
//
//  Synced like every other row-per-entity type (`Data/Sync/FirestoreDTOs.swift`'s
//  `AnalyticsSnapshotDTO`, `SyncEntityType.analyticsSnapshot`) via the same
//  outbox/delta machinery as `ItemRating`/`OutfitFeedback` — see
//  `Data/CLAUDE.md`'s Cloud Sync section.
//

import Foundation
import SwiftData

@Model
final class AnalyticsSnapshot {
    @Attribute(.unique) var id: UUID
    /// ISO week key, e.g. `"2026-W29"` — one row per period; callers upsert
    /// in place via `WardrobeRepository.upsertAnalyticsSnapshot(periodKey:payloadJSON:)`
    /// rather than inserting a duplicate for an already-computed period.
    var periodKey: String
    var payloadJSON: String
    var computedAt: Date

    init(id: UUID = UUID(), periodKey: String, payloadJSON: String, computedAt: Date = .now) {
        self.id = id
        self.periodKey = periodKey
        self.payloadJSON = payloadJSON
        self.computedAt = computedAt
    }
}
