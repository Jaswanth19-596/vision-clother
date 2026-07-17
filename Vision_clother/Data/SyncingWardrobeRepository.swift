//
//  SyncingWardrobeRepository.swift
//  Vision_clother
//
//  Cloud Sync (docs/decisions/resolved-v1.md's "Cloud Sync" section):
//  decorates `WardrobeRepository` so every local mutation also durably
//  queues a Firestore/Storage push — same decorator-over-protocol idiom as
//  `Services/CachedTryOnRenderService.swift`. Every call site that currently
//  constructs `SwiftDataWardrobeRepository(modelContext:)` becomes a pure
//  rename to `SyncingWardrobeRepository(modelContext:)` via the convenience
//  initializer below; nothing else about the call site changes.
//
//  Reads pass straight through to `underlying`, unmodified. Writes call
//  `underlying` first (local behavior/error surface is unchanged), then
//  upsert a `SyncMetadata` row (the durable outbox — see that model's doc
//  comment) and kick a best-effort immediate drain via `SyncOutboxWorker`.
//  A handful of `WardrobeRepository` methods derive persisted state
//  internally and don't return it (e.g. `recordItemFeedback` mints its own
//  id) — for those, this decorator either re-fetches the just-written row
//  through an existing query method when one exists (`recordItemRating` via
//  `fetchItemRatings(for:)`), or builds the DTO directly from its own input
//  parameters when no such method exists (`recordItemFeedback`,
//  `recordPairFeedback`, `recordSwipe`'s `SwipeEvent`) — safe because
//  nothing in this codebase ever looks up those three types by their own
//  row id, only by the foreign keys already present as inputs.
//
//  `WardrobeItemEmbedding` and `RecommendationImpressionEvent` are
//  deliberately never marked dirty here — the Cloud Sync architecture keeps
//  both local-only (cheap to recompute / meaningless across an account
//  switch, respectively).
//

import Foundation
import SwiftData

@MainActor
final class SyncingWardrobeRepository: WardrobeRepository {
    private let underlying: WardrobeRepository
    private let modelContext: ModelContext
    private let syncService: WardrobeSyncService
    private let outboxWorker: SyncOutboxWorker

    init(underlying: WardrobeRepository, modelContext: ModelContext, syncService: WardrobeSyncService, outboxWorker: SyncOutboxWorker) {
        self.underlying = underlying
        self.modelContext = modelContext
        self.syncService = syncService
        self.outboxWorker = outboxWorker
    }

    convenience init(modelContext: ModelContext) {
        let syncService = ServiceFactory.makeWardrobeSyncService()
        self.init(
            underlying: SwiftDataWardrobeRepository(modelContext: modelContext),
            modelContext: modelContext,
            syncService: syncService,
            outboxWorker: SyncOutboxWorker(modelContext: modelContext, syncService: syncService)
        )
    }

    // MARK: - Wardrobe items

    func fetchInventory() throws -> [WardrobeItem] {
        try underlying.fetchInventory()
    }

    func save(_ item: WardrobeItem) throws {
        try underlying.save(item)
        markDirty(.wardrobeItem, entityID: item.id, dto: WardrobeItemDTO.from(item))
        uploadImageIfNeeded(assetName: item.imageAssetName, kind: .wardrobeItemCutout)
        adjustItemCountIfNeeded(slot: item.slot, delta: 1)
    }

    func update(_ item: WardrobeItem) throws {
        try underlying.update(item)
        markDirty(.wardrobeItem, entityID: item.id, dto: WardrobeItemDTO.from(item))
        uploadImageIfNeeded(assetName: item.imageAssetName, kind: .wardrobeItemCutout)
    }

    func delete(_ item: WardrobeItem) throws {
        try underlying.delete(item)
        markDeleted(.wardrobeItem, entityID: item.id)
        adjustItemCountIfNeeded(slot: item.slot, delta: -1)
    }

    // MARK: - Feedback history (read-only aggregate)

    func fetchFeedbackHistory() async throws -> FeedbackHistory {
        try await underlying.fetchFeedbackHistory()
    }

    // MARK: - Simple feedback (no fetch-by-own-id method exists — DTO built from inputs)

    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {
        try underlying.recordOutfitFeedback(outfitID: outfitID, likedOverall: likedOverall)
        if let feedback = try underlying.fetchOutfitFeedback(for: outfitID).first {
            markDirty(.outfitFeedback, entityID: feedback.id, dto: OutfitFeedbackDTO.from(feedback))
        }
    }

    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {
        try underlying.recordItemFeedback(itemID: itemID, likedFit: likedFit)
        let entityID = UUID()
        let dto = ItemFeedbackDTO(id: entityID.uuidString, itemID: itemID.uuidString, likedFit: likedFit, recordedAt: .now)
        markDirty(.itemFeedback, entityID: entityID, dto: dto)
    }

    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {
        try underlying.recordPairFeedback(itemAID: itemAID, itemBID: itemBID, likedTogether: likedTogether)
        // Mirrors `SwiftDataWardrobeRepository.PairFeedback.init`'s order-independent
        // (min/max) id storage, so the pushed DTO matches what was actually persisted.
        let ordered = [itemAID, itemBID].sorted { $0.uuidString < $1.uuidString }
        let entityID = UUID()
        let dto = PairFeedbackDTO(
            id: entityID.uuidString,
            itemAID: ordered[0].uuidString,
            itemBID: ordered[1].uuidString,
            likedTogether: likedTogether,
            recordedAt: .now
        )
        markDirty(.pairFeedback, entityID: entityID, dto: dto)
    }

    // MARK: - Item ratings

    func recordItemRating(
        itemID: UUID,
        fit: FitRating,
        comfort: Int,
        colorLike: Int,
        patternLike: Int?,
        formalityFit: Int,
        styleIdentity: Int,
        wearAgain: Bool
    ) throws {
        try underlying.recordItemRating(
            itemID: itemID, fit: fit, comfort: comfort, colorLike: colorLike, patternLike: patternLike,
            formalityFit: formalityFit, styleIdentity: styleIdentity, wearAgain: wearAgain
        )
        if let rating = try underlying.fetchItemRatings(for: itemID).first {
            markDirty(.itemRating, entityID: rating.id, dto: ItemRatingDTO.from(rating))
        }
        // `recordItemRating` folds an implicit swipe into `VisualPreferenceState`
        // (`SwiftDataWardrobeRepository.applyImplicitSwipe`) — push that too.
        if let state = try? underlying.fetchVisualPreferenceState() {
            markDirty(.visualPreferenceState, entityID: state.id, dto: VisualPreferenceStateDTO.from(state))
        }
    }

    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] {
        try underlying.fetchItemRatings(for: itemID)
    }

    // MARK: - Outfit ratings

    func recordOutfitRating(outfitID: UUID, submission: OutfitRatingSubmission) throws {
        try underlying.recordOutfitRating(outfitID: outfitID, submission: submission)
        if let feedback = try underlying.fetchOutfitFeedback(for: outfitID).first {
            markDirty(.outfitFeedback, entityID: feedback.id, dto: OutfitFeedbackDTO.from(feedback))
        }
    }

    func fetchOutfitFeedback(for outfitID: UUID) throws -> [OutfitFeedback] {
        try underlying.fetchOutfitFeedback(for: outfitID)
    }

    // MARK: - Saved combinations

    func fetchSavedCombinations() throws -> [SavedCombination] {
        try underlying.fetchSavedCombinations()
    }

    func saveCombination(_ combination: SavedCombination) throws {
        try underlying.saveCombination(combination)
        markDirty(.savedCombination, entityID: combination.id, dto: SavedCombinationDTO.from(combination))
        uploadImageIfNeeded(assetName: combination.imageAssetName, kind: .combinationRender)
    }

    func deleteCombination(_ combination: SavedCombination) throws {
        try underlying.deleteCombination(combination)
        markDeleted(.savedCombination, entityID: combination.id)
    }

    // MARK: - User style profile

    func fetchUserProfile() throws -> UserStyleProfile? {
        try underlying.fetchUserProfile()
    }

    func saveUserProfile(_ wire: UserStyleProfileWire) throws {
        try underlying.saveUserProfile(wire)
        if let profile = try underlying.fetchUserProfile() {
            markDirty(.userStyleProfile, entityID: profile.id, dto: UserStyleProfileDTO.from(profile))
        }
    }

    // MARK: - Swipe-to-Learn Visual Taste

    @discardableResult
    func recordSwipe(sourcePhotoID: String, imageURLString: String, liked: Bool, embedding: [Float]) throws -> Double? {
        let drift = try underlying.recordSwipe(sourcePhotoID: sourcePhotoID, imageURLString: imageURLString, liked: liked, embedding: embedding)
        let entityID = UUID()
        let dto = SwipeEventDTO(id: entityID.uuidString, sourcePhotoID: sourcePhotoID, imageURLString: imageURLString, liked: liked, embedding: embedding, recordedAt: .now)
        markDirty(.swipeEvent, entityID: entityID, dto: dto)
        if let state = try? underlying.fetchVisualPreferenceState() {
            markDirty(.visualPreferenceState, entityID: state.id, dto: VisualPreferenceStateDTO.from(state))
        }
        return drift
    }

    func fetchVisualPreferenceState() throws -> VisualPreferenceState? {
        try underlying.fetchVisualPreferenceState()
    }

    func updateVisualPreferenceState(
        likedCentroids: [VisualCentroid],
        dislikedCentroids: [VisualCentroid],
        embeddingDimension: Int
    ) throws {
        try underlying.updateVisualPreferenceState(
            likedCentroids: likedCentroids, dislikedCentroids: dislikedCentroids, embeddingDimension: embeddingDimension
        )
        if let state = try underlying.fetchVisualPreferenceState() {
            markDirty(.visualPreferenceState, entityID: state.id, dto: VisualPreferenceStateDTO.from(state))
        }
    }

    // MARK: - Local-only (never synced — see file header)

    func fetchWardrobeItemEmbedding(itemID: UUID) throws -> WardrobeItemEmbedding? {
        try underlying.fetchWardrobeItemEmbedding(itemID: itemID)
    }

    func saveWardrobeItemEmbedding(itemID: UUID, vector: [Float], sourceFingerprint: String) throws {
        try underlying.saveWardrobeItemEmbedding(itemID: itemID, vector: vector, sourceFingerprint: sourceFingerprint)
    }

    func recordImpressions(roundID: UUID, outfits: [OutfitCombination]) throws {
        try underlying.recordImpressions(roundID: roundID, outfits: outfits)
    }

    func recordSelection(outfitID: UUID) throws {
        try underlying.recordSelection(outfitID: outfitID)
    }

    // MARK: - Outbox bookkeeping

    private func markDirty(_ type: SyncEntityType, entityID: UUID, dto: some Encodable) {
        guard let payload = try? JSONEncoder().encode(dto) else { return }
        upsertSyncMetadata(type: type, entityID: entityID, operation: .upsert, payload: payload)
        kickOutboxDrain()
    }

    private func markDeleted(_ type: SyncEntityType, entityID: UUID) {
        upsertSyncMetadata(type: type, entityID: entityID, operation: .delete, payload: nil)
        kickOutboxDrain()
    }

    private func upsertSyncMetadata(type: SyncEntityType, entityID: UUID, operation: SyncOperation, payload: Data?) {
        AppLog.debug(.sync, "outbox: enqueue \(type.rawValue) \(operation.rawValue) \(entityID)")
        let key = SyncMetadata.compositeKey(entityType: type, entityID: entityID)
        let descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.compositeKey == key })

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.operation = operation
            existing.isDirty = true
            existing.localUpdatedAt = .now
            existing.attemptCount = 0
            existing.lastAttemptAt = nil
            existing.payload = operation == .delete ? nil : payload
        } else {
            modelContext.insert(SyncMetadata(entityType: type, entityID: entityID, operation: operation, payload: operation == .delete ? nil : payload))
        }
        try? modelContext.save()
    }

    /// Captured synchronously here, on `@MainActor`, before the `Task` below
    /// starts — so an in-flight drain always targets the account that was
    /// signed in at the moment of this mutation, never whatever
    /// `AuthService.shared.uid` has become by the time the `Task` actually
    /// runs (e.g. mid account-switch). `nil` (signed out) is a no-op: the
    /// row stays queued, dirty, for the next successful sign-in's drain.
    private func kickOutboxDrain() {
        guard let uid = AuthService.shared.uid else {
            AppLog.debug(.sync, "kickOutboxDrain: no uid, staying queued for next sign-in")
            return
        }
        let worker = outboxWorker
        Task { await worker.drainNow(uid: uid) }
    }

    private enum ImageKind {
        case wardrobeItemCutout
        case combinationRender
    }

    /// Best-effort, not part of the durable outbox — a failed upload simply
    /// means the photo bytes are missing from Cloud Storage until the next
    /// successful attempt (the next `save`/`update` on this item, or a
    /// future explicit re-upload pass); the Firestore document itself (via
    /// `SyncMetadata`) is still durably retried regardless, so the item's
    /// metadata is never lost even if its photo transfer lags.
    private func uploadImageIfNeeded(assetName: String?, kind: ImageKind) {
        guard let assetName, let uid = AuthService.shared.uid, let data = ImageStorage.loadData(for: assetName) else { return }
        let uploadData: Data
        let contentType: SyncImageContentType
        switch kind {
        case .wardrobeItemCutout: uploadData = ImageStorage.downscaledPNGForUpload(data); contentType = .png
        case .combinationRender: uploadData = ImageStorage.downscaledJPEGForUpload(data); contentType = .jpeg
        }
        let service = syncService
        Task {
            do {
                try await service.uploadImage(filename: assetName, data: uploadData, contentType: contentType, uid: uid)
            } catch {
                AppLog.error(.sync, "uploadImageIfNeeded: \(assetName) failed, will retry on next save/update — \(String(describing: error))")
            }
        }
    }

    /// Best-effort, fire-and-forget — see `Services/WardrobeSyncService.swift`'s
    /// `adjustItemCount` doc comment for why this isn't atomic with the item
    /// doc write. Only `save` (+1) and `delete` (-1) call this; `update`
    /// deliberately doesn't. Known gap: `Features/Closet/EditItemView.swift`
    /// does let a user re-slot an item on edit, which this counter doesn't
    /// track (the old slot is already overwritten on `item` by the time
    /// `update` sees it, so there's no previous value to diff against here).
    /// Same posture as `backend/firestore.rules`'s own documented
    /// `meta/itemCounts` limitation — a scheduled reconciliation function
    /// against actual per-slot counts is the recommended real fix, not
    /// implemented here.
    private func adjustItemCountIfNeeded(slot: Slot, delta: Int) {
        guard let uid = AuthService.shared.uid else { return }
        let service = syncService
        Task { try? await service.adjustItemCount(slot: slot, delta: delta, uid: uid) }
    }
}
