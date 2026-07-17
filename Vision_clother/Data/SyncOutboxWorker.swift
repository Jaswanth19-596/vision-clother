//
//  SyncOutboxWorker.swift
//  Vision_clother
//
//  Cloud Sync (docs/decisions/resolved-v1.md's "Cloud Sync" section): drains
//  `SyncMetadata` rows marked `isDirty` — the durable retry queue behind
//  `Data/SyncingWardrobeRepository.swift`'s best-effort pushes. Runs
//  immediately (best-effort) after every local mutation and again on every
//  foreground (`Data/WardrobeSyncCoordinator.swift`'s `reconcileIfSignedIn`),
//  so a push that failed offline/mid-flight gets retried rather than
//  silently dropped, with exponential backoff so a persistently-failing push
//  doesn't hammer Firestore every time the app foregrounds.
//

import Foundation
import SwiftData

@MainActor
final class SyncOutboxWorker {
    private let modelContext: ModelContext
    private let syncService: WardrobeSyncService
    /// Reentrancy guard — `drainNow` can be fired in quick succession (one
    /// per mutation, plus a foreground reconcile); a drain already in flight
    /// will naturally pick up anything new on its next scheduled pass, so a
    /// second concurrent pass is redundant, not incorrect, but skipped to
    /// avoid two passes racing to update the same `SyncMetadata` rows.
    private var isDraining = false

    init(modelContext: ModelContext, syncService: WardrobeSyncService) {
        self.modelContext = modelContext
        self.syncService = syncService
    }

    /// Drains every eligible dirty row to `uid`'s Firestore/Storage paths.
    /// `uid` is always supplied by the caller (never read from
    /// `AuthService.shared` internally) — see
    /// `Data/SyncingWardrobeRepository.swift`'s note on why the uid must be
    /// captured synchronously at the mutation site, not re-read later after
    /// a possible account switch.
    ///
    /// Returns `true` iff zero dirty rows remain afterward — callers that
    /// need to know sync actually finished (e.g.
    /// `Data/WardrobeSyncCoordinator.swift`'s bootstrap push and
    /// drain-before-wipe) use this instead of assuming a single pass always
    /// succeeds; a row skipped due to backoff or a failed push leaves this
    /// `false`.
    @discardableResult
    func drainNow(uid: String) async -> Bool {
        guard !isDraining else {
            AppLog.debug(.sync, "drainNow: already draining, skipped")
            return false
        }
        isDraining = true
        defer { isDraining = false }

        let descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.isDirty })
        guard let dirtyRows = try? modelContext.fetch(descriptor), !dirtyRows.isEmpty else {
            AppLog.debug(.sync, "drainNow: no dirty rows")
            return true
        }
        AppLog.info(.sync, "drainNow: starting, dirtyRows=\(dirtyRows.count)")

        let now = Date()
        var didChangeAnything = false
        var allSucceeded = true
        var pushedCount = 0
        var backedOffCount = 0
        var failedCount = 0

        for row in dirtyRows {
            if let lastAttemptAt = row.lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.backoffSeconds(attemptCount: row.attemptCount) {
                allSucceeded = false
                backedOffCount += 1
                continue
            }

            do {
                try await push(row, uid: uid)
                didChangeAnything = true
                pushedCount += 1
                if row.operation == .delete {
                    modelContext.delete(row)
                } else {
                    row.isDirty = false
                    row.attemptCount = 0
                    row.lastAttemptAt = nil
                }
            } catch {
                didChangeAnything = true
                allSucceeded = false
                failedCount += 1
                row.attemptCount += 1
                row.lastAttemptAt = now
                AppLog.error(.sync, "drainNow: push failed for \(row.entityType) \(row.entityID) (attempt \(row.attemptCount)) — \(String(describing: error))")
            }
        }

        if didChangeAnything {
            try? modelContext.save()
        }
        AppLog.info(.sync, "drainNow: finished pushed=\(pushedCount) failed=\(failedCount) backedOff=\(backedOffCount) allSucceeded=\(allSucceeded)")
        return allSucceeded
    }

    private func push(_ row: SyncMetadata, uid: String) async throws {
        if row.operation == .delete {
            try await syncService.deleteEntity(type: row.entityType, id: row.entityID, uid: uid)
            return
        }

        guard let payload = row.payload else { return }
        let decoder = JSONDecoder()

        switch row.entityType {
        case .wardrobeItem:
            try await syncService.pushWardrobeItem(decoder.decode(WardrobeItemDTO.self, from: payload), uid: uid)
        case .outfitFeedback:
            try await syncService.pushOutfitFeedback(decoder.decode(OutfitFeedbackDTO.self, from: payload), uid: uid)
        case .itemFeedback:
            try await syncService.pushItemFeedback(decoder.decode(ItemFeedbackDTO.self, from: payload), uid: uid)
        case .pairFeedback:
            try await syncService.pushPairFeedback(decoder.decode(PairFeedbackDTO.self, from: payload), uid: uid)
        case .itemRating:
            try await syncService.pushItemRating(decoder.decode(ItemRatingDTO.self, from: payload), uid: uid)
        case .savedCombination:
            try await syncService.pushSavedCombination(decoder.decode(SavedCombinationDTO.self, from: payload), uid: uid)
        case .userStyleProfile:
            try await syncService.pushUserStyleProfile(decoder.decode(UserStyleProfileDTO.self, from: payload), uid: uid)
        case .swipeEvent:
            try await syncService.pushSwipeEvent(decoder.decode(SwipeEventDTO.self, from: payload), uid: uid)
        case .visualPreferenceState:
            try await syncService.pushVisualPreferenceState(decoder.decode(VisualPreferenceStateDTO.self, from: payload), uid: uid)
        }
    }

    /// `2^attemptCount` seconds, capped at 30 minutes — a persistently
    /// failing push (e.g. genuinely offline) backs off instead of retrying
    /// on every single foreground/mutation.
    private static func backoffSeconds(attemptCount: Int) -> TimeInterval {
        min(pow(2.0, Double(attemptCount)), 30 * 60)
    }
}
