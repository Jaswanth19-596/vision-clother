//
//  SyncMetadata.swift
//  Vision_clother
//
//  Cloud Sync (docs/decisions/resolved-v1.md's "Cloud Sync" section): the
//  local half of the durable outbox + conflict-resolution mechanism.
//  `Data/SyncingWardrobeRepository.swift` upserts one row per synced entity
//  on every local mutation (`isDirty = true`); `Data/SyncOutboxWorker.swift`
//  drains dirty rows to Firestore/Storage with retry/backoff and, on
//  confirmed push, stores the resolved server timestamp back into
//  `localUpdatedAt` and clears `isDirty`. Rows are kept (not deleted) after a
//  successful push — they double as the local side of pull-time conflict
//  comparison (`Data/WardrobeSyncCoordinator.swift`), so a stale pull can
//  never silently clobber a newer, not-yet-pushed local edit.
//
//  Local-only — never synced itself. Deliberately one small independent
//  table rather than an `isDirty` column added to each of the 9 synced
//  `@Model` types, to keep those schemas untouched by this feature.
//
//  `payload` makes the outbox self-contained: it stores the JSON-encoded DTO
//  captured at mutation time, rather than a bare pointer the worker would
//  need to re-fetch from SwiftData at drain time. That re-fetch isn't always
//  possible — `ItemFeedback`, `PairFeedback`, `OutfitFeedback`, `ItemRating`,
//  and `SwipeEvent` are only queryable through `WardrobeRepository` by a
//  foreign key (e.g. `fetchItemRatings(for itemID:)`), never by their own
//  row id. Capturing the payload up front sidesteps that gap entirely and is
//  also more crash-safe: the exact write is captured atomically alongside
//  the local mutation, with no dependency on the row still existing later.
//

import Foundation
import SwiftData

enum SyncOperation: String, Codable {
    case upsert
    case delete
}

/// Which synced `@Model` type an entity belongs to — mirrors the Firestore
/// collection names in `Data/Sync/FirestoreDTOs.swift`.
enum SyncEntityType: String, Codable {
    case wardrobeItem
    case outfitFeedback
    case itemFeedback
    case pairFeedback
    case itemRating
    case savedCombination
    case userStyleProfile
    case swipeEvent
    case visualPreferenceState
}

@Model
final class SyncMetadata {
    /// `"\(entityType.rawValue)_\(entityID.uuidString)"` — stable, derivable
    /// from the other two fields, exists purely so `@Attribute(.unique)` can
    /// enforce one row per entity without a compound-key predicate.
    @Attribute(.unique) var compositeKey: String
    var entityTypeRaw: String
    var entityID: UUID
    var operationRaw: String
    /// `true` until a push reflecting the current local state is confirmed —
    /// gates both outbox draining and pull-side conflict resolution.
    var isDirty: Bool
    /// Local write time on every local mutation; overwritten with the
    /// Firestore-resolved server timestamp once a push confirms, so it stays
    /// comparable against `updatedAt` on documents pulled later.
    var localUpdatedAt: Date
    var attemptCount: Int
    var lastAttemptAt: Date?
    /// JSON-encoded DTO snapshot, `nil` for `.delete` operations (a tombstone
    /// needs no payload, just `entityType`/`entityID`).
    var payload: Data?

    init(
        entityType: SyncEntityType,
        entityID: UUID,
        operation: SyncOperation,
        isDirty: Bool = true,
        localUpdatedAt: Date = .now,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        payload: Data? = nil
    ) {
        self.compositeKey = Self.compositeKey(entityType: entityType, entityID: entityID)
        self.entityTypeRaw = entityType.rawValue
        self.entityID = entityID
        self.operationRaw = operation.rawValue
        self.isDirty = isDirty
        self.localUpdatedAt = localUpdatedAt
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.payload = payload
    }

    static func compositeKey(entityType: SyncEntityType, entityID: UUID) -> String {
        "\(entityType.rawValue)_\(entityID.uuidString)"
    }

    var entityType: SyncEntityType {
        get { SyncEntityType(rawValue: entityTypeRaw) ?? .wardrobeItem }
        set { entityTypeRaw = newValue.rawValue }
    }

    var operation: SyncOperation {
        get { SyncOperation(rawValue: operationRaw) ?? .upsert }
        set { operationRaw = newValue.rawValue }
    }
}
