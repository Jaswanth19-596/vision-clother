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

    /// Rows per `WriteBatch` — Firestore's hard cap on operations in a single
    /// batch (`FirestoreWardrobeSyncService.maxBatchSize`, mirrored here so
    /// this file doesn't need a `FirebaseFirestore` import just to read a
    /// constant).
    private static let maxBatchSize = 500

    /// Bounds how many chunk-level `WriteBatch` commits run concurrently in
    /// one `drainNow` pass — see the fan-out in `drainNow` below.
    private static let maxConcurrentBatches = 4

    private enum PushOutcome {
        case pushed
        case failed
    }

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
        var eligibleRows: [SyncMetadata] = []
        var backedOffCount = 0
        for row in dirtyRows {
            if let lastAttemptAt = row.lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.backoffSeconds(attemptCount: row.attemptCount) {
                backedOffCount += 1
            } else {
                eligibleRows.append(row)
            }
        }

        var pushedCount = 0
        var failedCount = 0

        // Legacy `SwipeEvent` rows never reach Firestore (see the doc
        // comment on `.swipeEvent` below) — drain them locally before
        // building batches so they never occupy a slot in a `WriteBatch`.
        var batchableRows: [SyncMetadata] = []
        for row in eligibleRows {
            if row.entityType == .swipeEvent {
                AppLog.debug(.sync, "drainNow: dropping legacy swipeEvent outbox row \(row.entityID)")
                finalizeSuccess(row)
                pushedCount += 1
            } else {
                batchableRows.append(row)
            }
        }

        let chunks = stride(from: 0, to: batchableRows.count, by: Self.maxBatchSize).map {
            Array(batchableRows[$0..<min($0 + Self.maxBatchSize, batchableRows.count)])
        }

        // Bounded fan-out — each chunk's `WriteBatch` commit is an
        // independent network request, so running up to
        // `maxConcurrentBatches` at once cuts wall-clock drain time for a
        // large backlog (e.g. after being offline a while, or the bootstrap
        // push's dirty rows) instead of one batch at a time. The
        // `ModelContext` mutations in `attemptCommitBatch` still only ever
        // run on this actor, one chunk at a time, same as before.
        await withTaskGroup(of: (count: Int, outcome: PushOutcome).self) { group in
            var index = 0
            func addNext() {
                guard index < chunks.count else { return }
                let chunk = chunks[index]
                index += 1
                group.addTask { [weak self] in
                    let outcome = await self?.attemptCommitBatch(chunk, uid: uid, now: now) ?? .failed
                    return (chunk.count, outcome)
                }
            }
            for _ in 0..<min(Self.maxConcurrentBatches, chunks.count) {
                addNext()
            }
            while let (count, outcome) = await group.next() {
                switch outcome {
                case .pushed: pushedCount += count
                case .failed: failedCount += count
                }
                addNext()
            }
        }

        let didChangeAnything = pushedCount > 0 || failedCount > 0
        if didChangeAnything {
            try? modelContext.save()
        }
        let allSucceeded = failedCount == 0 && backedOffCount == 0
        AppLog.info(.sync, "drainNow: finished pushed=\(pushedCount) failed=\(failedCount) backedOff=\(backedOffCount) allSucceeded=\(allSucceeded)")
        return allSucceeded
    }

    /// Commits one chunk (≤`maxBatchSize` rows) as a single Firestore
    /// `WriteBatch`. A `WriteBatch` is atomic as a whole — either every row
    /// in `chunk` lands or none do — so local `SyncMetadata` state is only
    /// ever updated *after* that commit resolves (never optimistically
    /// beforehand): on success every row in the chunk is marked clean
    /// together; on failure every row in the chunk gets its own
    /// `attemptCount`/`lastAttemptAt` bumped individually, so each keeps its
    /// own backoff schedule (`backoffSeconds(attemptCount:)`) on the next
    /// drain rather than the whole chunk being retried in lockstep forever.
    private func attemptCommitBatch(_ chunk: [SyncMetadata], uid: String, now: Date) async -> PushOutcome {
        let operations = chunk.map {
            SyncBatchOperation(entityType: $0.entityType, entityID: $0.entityID, operation: $0.operation, payload: $0.payload)
        }
        do {
            try await syncService.commitBatch(operations, uid: uid)
            for row in chunk {
                finalizeSuccess(row)
            }
            return .pushed
        } catch {
            for row in chunk {
                row.attemptCount += 1
                row.lastAttemptAt = now
                AppLog.error(.sync, "drainNow: batch commit failed for \(row.entityType) \(row.entityID) (attempt \(row.attemptCount)) — \(String(describing: error))")
            }
            return .failed
        }
    }

    private func finalizeSuccess(_ row: SyncMetadata) {
        if row.operation == .delete {
            modelContext.delete(row)
        } else {
            row.isDirty = false
            row.attemptCount = 0
            row.lastAttemptAt = nil
        }
    }

    /// `2^attemptCount` seconds, capped at 30 minutes — a persistently
    /// failing push (e.g. genuinely offline) backs off instead of retrying
    /// on every single foreground/mutation.
    private static func backoffSeconds(attemptCount: Int) -> TimeInterval {
        min(pow(2.0, Double(attemptCount)), 30 * 60)
    }
}
