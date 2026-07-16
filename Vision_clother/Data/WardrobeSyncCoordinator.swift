//
//  WardrobeSyncCoordinator.swift
//  Vision_clother
//
//  Cloud Sync (docs/decisions/resolved-v1.md's "Cloud Sync" section): owns
//  every account-switch bulk `ModelContext` mutation — bootstrap
//  (push-local-up vs. wipe-and-pull, depending on whether the account has
//  any cloud history yet), the foreground delta-reconcile safety net, and
//  the local-mirror wipe when switching to a different account. Constructed
//  once in `Vision_clotherApp.swift` and retained for the app's lifetime so
//  its `AuthService.shared.$uid` subscription stays alive.
//
//  Deliberately holds a *plain* `SwiftDataWardrobeRepository`, not the
//  `SyncingWardrobeRepository` decorator — routing bulk pull-applied writes
//  back through the decorator would re-mark every pulled row dirty and push
//  it right back to Firestore, an infinite no-op loop.
//
//  Tracks which account's data currently sits in local SwiftData via a
//  single `UserDefaults` value (`currentMirrorUID`), not a per-uid history
//  flag — this is what lets a user sign out and back into the *same*
//  account without a wipe (local data isn't cleared on sign-out at all,
//  matching this app's existing "sign-in is optional, not a hard gate"
//  posture — signing out just stops syncing, it doesn't erase your closet),
//  while still guaranteeing a *different* incoming account can never see a
//  stale mix of the previous account's rows: the wipe happens lazily, right
//  before that different account's data would otherwise be loaded.
//

import Foundation
import SwiftData
import Combine

@MainActor
final class WardrobeSyncCoordinator {
    private let modelContext: ModelContext
    private let repository: SwiftDataWardrobeRepository
    private let syncService: WardrobeSyncService
    private var cancellable: AnyCancellable?

    private static let currentMirrorUIDKey = "WardrobeSyncCoordinator.currentMirrorUID"
    /// Delta-pull watermark safety margin — `PulledWardrobeDelta.queryStartTime`
    /// is a client clock value; subtracting this before persisting it as the
    /// next pull's `since` bound trades a little redundant re-fetching for a
    /// guarantee against silently missing a doc written in the narrow gap
    /// around a skewed device clock. See `FirestoreDTOs.swift`'s
    /// `SyncStatusDTO` doc comment for the full reasoning.
    private static let watermarkSafetyMargin: TimeInterval = 120

    private static var currentMirrorUID: String? {
        get { UserDefaults.standard.string(forKey: currentMirrorUIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: currentMirrorUIDKey) }
    }

    init(modelContext: ModelContext, syncService: WardrobeSyncService) {
        self.modelContext = modelContext
        self.repository = SwiftDataWardrobeRepository(modelContext: modelContext)
        self.syncService = syncService

        cancellable = AuthService.shared.$uid
            .removeDuplicates()
            .sink { [weak self] uid in
                Task { await self?.handleUIDChange(uid) }
            }
    }

    /// Foreground safety-net entry point (`Vision_clotherApp.swift`'s
    /// `scenePhase` hook) — a bounded delta reconcile, not a full pull, for
    /// whichever account is currently signed in. No-op if signed out.
    func reconcileIfSignedIn() async {
        guard let uid = AuthService.shared.uid, Self.currentMirrorUID == uid else { return }
        await reconcile(uid: uid)
    }

    // MARK: - Account-switch handling

    private func handleUIDChange(_ uid: String?) async {
        guard let uid else { return }
        await handleSignIn(uid: uid)
    }

    private func handleSignIn(uid: String) async {
        if Self.currentMirrorUID == uid {
            // Already the account whose data is locally mirrored — a normal
            // app-launch-while-signed-in event, not a fresh sign-in. Just
            // catch up on anything that changed since last time.
            await reconcile(uid: uid)
            return
        }

        if Self.currentMirrorUID != nil {
            wipeLocalMirror()
        }

        let remoteStatus = try? await syncService.fetchSyncStatus(uid: uid)
        if remoteStatus?.hasCompletedInitialSync == true {
            // Returning account (another device, or a reinstall) — cloud
            // already has this account's data; local wins nothing here.
            await fullPull(uid: uid)
        } else {
            // First sign-in ever for this account — this device's existing
            // local data (if any) becomes the source of truth.
            await pushEverythingLocal(uid: uid)
            try? await syncService.initializeSyncStatus(uid: uid)
        }
        Self.currentMirrorUID = uid
    }

    private func wipeLocalMirror() {
        let syncedAndLocalOnlyTypes: [any PersistentModel.Type] = [
            WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self,
            ItemRating.self, SavedCombination.self, UserStyleProfile.self, SwipeEvent.self,
            VisualPreferenceState.self, WardrobeItemEmbedding.self, RecommendationImpressionEvent.self,
            SyncMetadata.self,
        ]
        for type in syncedAndLocalOnlyTypes {
            try? modelContext.delete(model: type)
        }
        try? modelContext.save()
        try? ImageStorage.wipeAll()
    }

    // MARK: - Bootstrap: push everything local up (first sign-in ever for this account)

    private func pushEverythingLocal(uid: String) async {
        for item in (try? repository.fetchInventory()) ?? [] {
            try? await syncService.pushWardrobeItem(WardrobeItemDTO.from(item), uid: uid)
        }
        for feedback in (try? modelContext.fetch(FetchDescriptor<OutfitFeedback>())) ?? [] {
            try? await syncService.pushOutfitFeedback(OutfitFeedbackDTO.from(feedback), uid: uid)
        }
        for feedback in (try? modelContext.fetch(FetchDescriptor<ItemFeedback>())) ?? [] {
            try? await syncService.pushItemFeedback(ItemFeedbackDTO.from(feedback), uid: uid)
        }
        for feedback in (try? modelContext.fetch(FetchDescriptor<PairFeedback>())) ?? [] {
            try? await syncService.pushPairFeedback(PairFeedbackDTO.from(feedback), uid: uid)
        }
        for rating in (try? modelContext.fetch(FetchDescriptor<ItemRating>())) ?? [] {
            try? await syncService.pushItemRating(ItemRatingDTO.from(rating), uid: uid)
        }
        for combination in (try? repository.fetchSavedCombinations()) ?? [] {
            try? await syncService.pushSavedCombination(SavedCombinationDTO.from(combination), uid: uid)
        }
        for event in (try? modelContext.fetch(FetchDescriptor<SwipeEvent>())) ?? [] {
            try? await syncService.pushSwipeEvent(SwipeEventDTO.from(event), uid: uid)
        }
        if let profile = try? repository.fetchUserProfile() {
            try? await syncService.pushUserStyleProfile(UserStyleProfileDTO.from(profile), uid: uid)
        }
        if let state = try? repository.fetchVisualPreferenceState() {
            try? await syncService.pushVisualPreferenceState(VisualPreferenceStateDTO.from(state), uid: uid)
        }

        await uploadAllLocalPhotos(uid: uid)
    }

    private func uploadAllLocalPhotos(uid: String) async {
        for item in (try? repository.fetchInventory()) ?? [] {
            guard let assetName = item.imageAssetName, let data = ImageStorage.loadData(for: assetName) else { continue }
            try? await syncService.uploadImage(filename: assetName, data: ImageStorage.downscaledPNGForUpload(data), uid: uid)
        }
        for combination in (try? repository.fetchSavedCombinations()) ?? [] {
            guard let data = ImageStorage.loadData(for: combination.imageAssetName) else { continue }
            try? await syncService.uploadImage(filename: combination.imageAssetName, data: ImageStorage.downscaledJPEGForUpload(data), uid: uid)
        }
    }

    // MARK: - Pull (bootstrap full pull and steady-state delta reconcile share this)

    private func fullPull(uid: String) async {
        await pullAndApply(uid: uid, since: nil)
    }

    private func reconcile(uid: String) async {
        let since = (try? await syncService.fetchSyncStatus(uid: uid))?.lastPulledAt
        await pullAndApply(uid: uid, since: since)
    }

    private func pullAndApply(uid: String, since: Date?) async {
        guard let delta = try? await syncService.pullChanges(uid: uid, since: since) else { return }

        for change in delta.wardrobeItems { applyWardrobeItemChange(change) }
        for change in delta.outfitFeedback { applyOutfitFeedbackChange(change) }
        for change in delta.itemFeedback { applyItemFeedbackChange(change) }
        for change in delta.pairFeedback { applyPairFeedbackChange(change) }
        for change in delta.itemRatings { applyItemRatingChange(change) }
        for change in delta.savedCombinations { applySavedCombinationChange(change) }
        for change in delta.swipeEvents { applySwipeEventChange(change) }

        if let update = delta.userStyleProfile { applyUserStyleProfileUpdate(update) }
        if let update = delta.visualPreferenceState { applyVisualPreferenceStateUpdate(update) }

        try? modelContext.save()

        let newWatermark = delta.queryStartTime.addingTimeInterval(-Self.watermarkSafetyMargin)
        try? await syncService.updateLastPulledAt(uid: uid, date: newWatermark)

        // Deliberately not awaited — per the "background prefetch, not
        // blocking sign-in/foreground" design (docs/decisions/resolved-v1.md's
        // "Cloud Sync" section): item/combination metadata is already usable
        // (applied above), so `reconcileIfSignedIn`/the bootstrap flow can
        // return promptly while photos trickle in behind it. Every existing
        // image-rendering call site already tolerates a missing local file
        // (the same "no image" placeholder path ghost elements already hit).
        let service = syncService
        Task { await self.downloadMissingPhotos(uid: uid, syncService: service) }
    }

    /// `true` if an unpushed local edit for this entity is at least as new
    /// as the incoming remote change — the pull must not silently clobber it
    /// (it'll win once its own outbox push lands). Shared by every
    /// `apply*Change`/`apply*Update` method below.
    private func shouldSkipDueToLocalDirty(_ entityType: SyncEntityType, entityID: UUID, remoteUpdatedAt: Date) -> Bool {
        guard let localMeta = fetchSyncMetadata(entityType: entityType, entityID: entityID) else { return false }
        return localMeta.isDirty && localMeta.localUpdatedAt >= remoteUpdatedAt
    }

    private func applyWardrobeItemChange(_ change: PulledChange<WardrobeItemDTO>) {
        let (idString, remoteUpdatedAt, dto) = unpack(change)
        guard let entityID = UUID(uuidString: idString) else { return }
        guard !shouldSkipDueToLocalDirty(.wardrobeItem, entityID: entityID, remoteUpdatedAt: remoteUpdatedAt) else { return }

        let descriptor = FetchDescriptor<WardrobeItem>(predicate: #Predicate { $0.id == entityID })
        if let existing = try? modelContext.fetch(descriptor).first {
            if let assetName = existing.imageAssetName { ImageStorage.delete(assetName) }
            modelContext.delete(existing)
        }
        if let dto, let model = dto.toModel() {
            modelContext.insert(model)
        }
        upsertCleanSyncMetadata(entityType: .wardrobeItem, entityID: entityID, localUpdatedAt: remoteUpdatedAt)
    }

    private func applyOutfitFeedbackChange(_ change: PulledChange<OutfitFeedbackDTO>) {
        let (idString, remoteUpdatedAt, dto) = unpack(change)
        guard let entityID = UUID(uuidString: idString) else { return }
        guard !shouldSkipDueToLocalDirty(.outfitFeedback, entityID: entityID, remoteUpdatedAt: remoteUpdatedAt) else { return }

        let descriptor = FetchDescriptor<OutfitFeedback>(predicate: #Predicate { $0.id == entityID })
        if let existing = try? modelContext.fetch(descriptor).first { modelContext.delete(existing) }
        if let dto, let model = dto.toModel() { modelContext.insert(model) }
        upsertCleanSyncMetadata(entityType: .outfitFeedback, entityID: entityID, localUpdatedAt: remoteUpdatedAt)
    }

    private func applyItemFeedbackChange(_ change: PulledChange<ItemFeedbackDTO>) {
        let (idString, remoteUpdatedAt, dto) = unpack(change)
        guard let entityID = UUID(uuidString: idString) else { return }
        guard !shouldSkipDueToLocalDirty(.itemFeedback, entityID: entityID, remoteUpdatedAt: remoteUpdatedAt) else { return }

        let descriptor = FetchDescriptor<ItemFeedback>(predicate: #Predicate { $0.id == entityID })
        if let existing = try? modelContext.fetch(descriptor).first { modelContext.delete(existing) }
        if let dto, let model = dto.toModel() { modelContext.insert(model) }
        upsertCleanSyncMetadata(entityType: .itemFeedback, entityID: entityID, localUpdatedAt: remoteUpdatedAt)
    }

    private func applyPairFeedbackChange(_ change: PulledChange<PairFeedbackDTO>) {
        let (idString, remoteUpdatedAt, dto) = unpack(change)
        guard let entityID = UUID(uuidString: idString) else { return }
        guard !shouldSkipDueToLocalDirty(.pairFeedback, entityID: entityID, remoteUpdatedAt: remoteUpdatedAt) else { return }

        let descriptor = FetchDescriptor<PairFeedback>(predicate: #Predicate { $0.id == entityID })
        if let existing = try? modelContext.fetch(descriptor).first { modelContext.delete(existing) }
        if let dto, let model = dto.toModel() { modelContext.insert(model) }
        upsertCleanSyncMetadata(entityType: .pairFeedback, entityID: entityID, localUpdatedAt: remoteUpdatedAt)
    }

    private func applyItemRatingChange(_ change: PulledChange<ItemRatingDTO>) {
        let (idString, remoteUpdatedAt, dto) = unpack(change)
        guard let entityID = UUID(uuidString: idString) else { return }
        guard !shouldSkipDueToLocalDirty(.itemRating, entityID: entityID, remoteUpdatedAt: remoteUpdatedAt) else { return }

        let descriptor = FetchDescriptor<ItemRating>(predicate: #Predicate { $0.id == entityID })
        if let existing = try? modelContext.fetch(descriptor).first { modelContext.delete(existing) }
        if let dto, let model = dto.toModel() { modelContext.insert(model) }
        upsertCleanSyncMetadata(entityType: .itemRating, entityID: entityID, localUpdatedAt: remoteUpdatedAt)
    }

    private func applySavedCombinationChange(_ change: PulledChange<SavedCombinationDTO>) {
        let (idString, remoteUpdatedAt, dto) = unpack(change)
        guard let entityID = UUID(uuidString: idString) else { return }
        guard !shouldSkipDueToLocalDirty(.savedCombination, entityID: entityID, remoteUpdatedAt: remoteUpdatedAt) else { return }

        let descriptor = FetchDescriptor<SavedCombination>(predicate: #Predicate { $0.id == entityID })
        if let existing = try? modelContext.fetch(descriptor).first {
            ImageStorage.delete(existing.imageAssetName)
            modelContext.delete(existing)
        }
        if let dto, let model = dto.toModel() { modelContext.insert(model) }
        upsertCleanSyncMetadata(entityType: .savedCombination, entityID: entityID, localUpdatedAt: remoteUpdatedAt)
    }

    private func applySwipeEventChange(_ change: PulledChange<SwipeEventDTO>) {
        let (idString, remoteUpdatedAt, dto) = unpack(change)
        guard let entityID = UUID(uuidString: idString) else { return }
        guard !shouldSkipDueToLocalDirty(.swipeEvent, entityID: entityID, remoteUpdatedAt: remoteUpdatedAt) else { return }

        let descriptor = FetchDescriptor<SwipeEvent>(predicate: #Predicate { $0.id == entityID })
        if let existing = try? modelContext.fetch(descriptor).first { modelContext.delete(existing) }
        if let dto, let model = dto.toModel() { modelContext.insert(model) }
        upsertCleanSyncMetadata(entityType: .swipeEvent, entityID: entityID, localUpdatedAt: remoteUpdatedAt)
    }

    /// Splits a `PulledChange` into its common parts — `dto` is `nil` for
    /// `.deleted`, since a tombstone has nothing to materialize.
    private func unpack<DTO>(_ change: PulledChange<DTO>) -> (id: String, updatedAt: Date, dto: DTO?) {
        switch change {
        case .upsert(let dto, let updatedAt): return ((dto as? any IdentifiableDTOField)?.idValue ?? "", updatedAt, dto)
        case .deleted(let id, let updatedAt): return (id, updatedAt, nil)
        }
    }

    private func applyUserStyleProfileUpdate(_ update: RemoteMetaUpdate<UserStyleProfileDTO>) {
        guard let entityID = UUID(uuidString: update.dto.id) else { return }
        guard !shouldSkipDueToLocalDirty(.userStyleProfile, entityID: entityID, remoteUpdatedAt: update.updatedAt) else { return }

        if let existing = try? repository.fetchUserProfile() { modelContext.delete(existing) }
        if let model = update.dto.toModel() { modelContext.insert(model) }
        upsertCleanSyncMetadata(entityType: .userStyleProfile, entityID: entityID, localUpdatedAt: update.updatedAt)
    }

    private func applyVisualPreferenceStateUpdate(_ update: RemoteMetaUpdate<VisualPreferenceStateDTO>) {
        guard let entityID = UUID(uuidString: update.dto.id) else { return }
        guard !shouldSkipDueToLocalDirty(.visualPreferenceState, entityID: entityID, remoteUpdatedAt: update.updatedAt) else { return }

        if let existing = try? repository.fetchVisualPreferenceState() { modelContext.delete(existing) }
        if let model = update.dto.toModel() { modelContext.insert(model) }
        upsertCleanSyncMetadata(entityType: .visualPreferenceState, entityID: entityID, localUpdatedAt: update.updatedAt)
    }

    private func fetchSyncMetadata(entityType: SyncEntityType, entityID: UUID) -> SyncMetadata? {
        let key = SyncMetadata.compositeKey(entityType: entityType, entityID: entityID)
        let descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.compositeKey == key })
        return try? modelContext.fetch(descriptor).first
    }

    private func upsertCleanSyncMetadata(entityType: SyncEntityType, entityID: UUID, localUpdatedAt: Date) {
        if let existing = fetchSyncMetadata(entityType: entityType, entityID: entityID) {
            existing.isDirty = false
            existing.localUpdatedAt = localUpdatedAt
            existing.payload = nil
        } else {
            modelContext.insert(SyncMetadata(entityType: entityType, entityID: entityID, operation: .upsert, isDirty: false, localUpdatedAt: localUpdatedAt))
        }
    }

    // MARK: - Background photo prefetch

    /// Runs after a pull applies fresh item/combination metadata locally —
    /// downloads whatever photos that metadata references but this device
    /// doesn't have bytes for yet (a fresh pull on a new device references
    /// every photo up front, but none of the bytes; this backfills them
    /// without blocking on the full transfer first). `syncService` is passed
    /// explicitly (not read from `self.syncService`) since this runs inside
    /// a detached `Task` after `pullAndApply` already returned.
    private func downloadMissingPhotos(uid: String, syncService: WardrobeSyncService) async {
        var missingFilenames: Set<String> = []

        for item in (try? repository.fetchInventory()) ?? [] {
            guard let assetName = item.imageAssetName, ImageStorage.loadData(for: assetName) == nil else { continue }
            missingFilenames.insert(assetName)
        }
        for combination in (try? repository.fetchSavedCombinations()) ?? [] {
            guard ImageStorage.loadData(for: combination.imageAssetName) == nil else { continue }
            missingFilenames.insert(combination.imageAssetName)
        }

        for filename in missingFilenames {
            guard let data = try? await syncService.downloadImage(filename: filename, uid: uid) else { continue }
            try? ImageStorage.write(data, filename: filename)
        }
    }
}

/// Lets `WardrobeSyncCoordinator.unpack(_:)` read a pulled DTO's `id`
/// generically across all 7 row-per-entity DTO types without a per-type switch.
private protocol IdentifiableDTOField {
    var idValue: String { get }
}
extension WardrobeItemDTO: IdentifiableDTOField { var idValue: String { id } }
extension OutfitFeedbackDTO: IdentifiableDTOField { var idValue: String { id } }
extension ItemFeedbackDTO: IdentifiableDTOField { var idValue: String { id } }
extension PairFeedbackDTO: IdentifiableDTOField { var idValue: String { id } }
extension ItemRatingDTO: IdentifiableDTOField { var idValue: String { id } }
extension SavedCombinationDTO: IdentifiableDTOField { var idValue: String { id } }
extension SwipeEventDTO: IdentifiableDTOField { var idValue: String { id } }
