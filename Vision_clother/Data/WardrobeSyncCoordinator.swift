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
//  `currentMirrorUID` is only ever stamped to the incoming uid *after* its
//  remote state has been confirmed (a successful bootstrap push or a
//  successful full pull) — never on a failed/undetermined remote check. A
//  bare `try?`-and-assume-fresh here previously made a transient Firestore
//  read failure indistinguishable from "this account has no cloud history,"
//  which silently orphaned a returning account's real data behind a bogus
//  freshly-stamped sync watermark, with no self-heal (the account looked
//  permanently "already synced" on every later switch back). See
//  `handleSignIn`/`fetchSyncStatusResilient` and `reconcileIfSignedIn`'s
//  retry fallback.
//

import Foundation
import Observation
import SwiftData
import Combine

@MainActor
@Observable
final class WardrobeSyncCoordinator {
    private let modelContext: ModelContext
    private let repository: SwiftDataWardrobeRepository
    private let syncService: WardrobeSyncService
    private let outboxWorker: SyncOutboxWorker
    private var cancellable: AnyCancellable?

    /// Toggled around the full body of `handleSignIn` (drain-before-wipe,
    /// bootstrap push/pull, full pull) — lets the UI (`AccountSectionView`)
    /// show a brief "syncing…" indicator during an account switch instead of
    /// the switch looking instant while this work happens invisibly.
    private(set) var isSyncingAccountSwitch = false

    /// Set when `handleSignIn` couldn't confirm this account's remote state
    /// (see the retry/failure handling below) — surfaced by
    /// `AccountSectionView` instead of the switch silently looking like a
    /// fresh, empty account. Cleared on the next successful attempt.
    private(set) var lastSyncError: String?

    /// Bumped once whenever the background photo prefetch (`downloadMissingPhotos`)
    /// actually writes a file to disk — item/combination photos and the
    /// portrait alike. Those writes go straight to `ImageStorage`/
    /// `UserPortraitStorage`, entirely outside SwiftData, so no `@Query`
    /// ever re-fires for them; `ClosetView`/`CombinationsView`/
    /// `CombinationDetailView`/`ProfileView` key their image-bearing
    /// containers off this counter instead, forcing a re-read of whatever
    /// image file just landed. A single tick per prefetch batch, not one per
    /// file — no need for callers to redraw more than once per pull.
    private(set) var photoRefreshTick = 0

    /// Attempts before giving up on a remote status/pull check during an
    /// account switch — covers the common transient case (Firestore's
    /// client-side auth context hasn't yet caught up with a just-completed
    /// `signIn`) without retrying forever.
    private static let remoteCheckMaxAttempts = 3
    private static let remoteCheckRetryDelay: Duration = .milliseconds(600)

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
        self.outboxWorker = SyncOutboxWorker(modelContext: modelContext, syncService: syncService)

        cancellable = AuthService.shared.$uid
            .removeDuplicates()
            .sink { [weak self] uid in
                Task { await self?.handleUIDChange(uid) }
            }
    }

    /// Foreground safety-net entry point (`Vision_clotherApp.swift`'s
    /// `scenePhase` hook) — a bounded delta reconcile for the common case
    /// (whichever account is currently signed in is already the locally
    /// mirrored one). If it *isn't* — a previous `handleSignIn` bailed out
    /// after failing to confirm this account's remote state, see below —
    /// this re-attempts the full switch instead of silently no-op'ing
    /// forever, so a transient failure self-heals on the next foreground
    /// rather than leaving the closet looking permanently empty. No-op if
    /// signed out.
    func reconcileIfSignedIn() async {
        guard let uid = AuthService.shared.uid else { return }
        if Self.currentMirrorUID == uid {
            await reconcile(uid: uid)
        } else {
            await handleSignIn(uid: uid)
        }
    }

    /// Manual counterpart to `reconcileIfSignedIn`'s automatic retry —
    /// `AccountSectionView` offers this next to `lastSyncError` so a failed
    /// switch doesn't require backgrounding/foregrounding the app to retry.
    func retrySync() async {
        guard let uid = AuthService.shared.uid else { return }
        await handleSignIn(uid: uid)
    }

    // MARK: - Account-switch handling

    private func handleUIDChange(_ uid: String?) async {
        guard let uid else { return }
        await handleSignIn(uid: uid)
    }

    private func handleSignIn(uid: String) async {
        AppLog.info(.sync, "handleSignIn: uid=\(uid) currentMirrorUID=\(Self.currentMirrorUID ?? "nil")")
        isSyncingAccountSwitch = true
        defer { isSyncingAccountSwitch = false }

        if Self.currentMirrorUID == uid {
            // Already the account whose data is locally mirrored — a normal
            // app-launch-while-signed-in event, not a fresh sign-in. Just
            // catch up on anything that changed since last time.
            AppLog.debug(.sync, "handleSignIn: already mirrored, reconciling")
            await reconcile(uid: uid)
            return
        }

        if let outgoingUID = Self.currentMirrorUID {
            AppLog.notice(.sync, "handleSignIn: switching accounts, wiping local mirror for \(outgoingUID)")
            await wipeLocalMirror(outgoingUID: outgoingUID)
        }

        switch await fetchSyncStatusResilient(uid: uid) {
        case .failure(let error):
            AppLog.error(.sync, "handleSignIn: fetchSyncStatus failed after retries — \(String(describing: error))")
            // Couldn't determine whether this account has cloud history —
            // must NOT guess "no history" here (that's exactly what used to
            // silently orphan a returning account's real data: a failed
            // read looked identical to "never synced," triggering a bogus
            // bootstrap-push that stamped a fresh syncStatus watermark over
            // the real one). Leave `currentMirrorUID` unset so this uid
            // stays eligible for `reconcileIfSignedIn` to retry the full
            // switch on the next foreground.
            lastSyncError = "Couldn't sync your account — will retry automatically."
            return
        case .success(let remoteStatus):
            if remoteStatus?.hasCompletedInitialSync == true {
                // Returning account (another device, or a reinstall) —
                // cloud already has this account's data; local wins nothing
                // here. Only trust the mirror once the pull actually lands —
                // a failed `pullChanges` must not be treated as "done"
                // either, for the same reason as the `.failure` case above.
                AppLog.info(.sync, "handleSignIn: returning account, running full pull")
                guard await fullPull(uid: uid) else {
                    AppLog.error(.sync, "handleSignIn: full pull failed")
                    lastSyncError = "Couldn't restore your closet — will retry automatically."
                    return
                }
            } else {
                // First sign-in ever for this account — this device's
                // existing local data (if any) becomes the source of truth.
                // Only stamp "fully synced" if the bootstrap push actually
                // drained clean — a partial failure here must not be
                // trusted by a future switch-back (see `pushEverythingLocal`'s
                // doc comment).
                AppLog.info(.sync, "handleSignIn: first sign-in for this account, pushing local data up")
                let fullySynced = await pushEverythingLocal(uid: uid)
                if fullySynced {
                    try? await syncService.initializeSyncStatus(uid: uid)
                } else {
                    AppLog.notice(.sync, "handleSignIn: bootstrap push left rows dirty, will retry via outbox")
                }
            }
            lastSyncError = nil
        }
        AppLog.info(.sync, "handleSignIn: completed for uid=\(uid)")
        Self.currentMirrorUID = uid
    }

    /// Retries `fetchSyncStatus` a few times before giving up — a plain
    /// `try?` here would make a transient failure indistinguishable from
    /// "this account has no cloud history yet," which is the exact
    /// misclassification that used to make a returning account's data
    /// vanish (see `handleSignIn`).
    private func fetchSyncStatusResilient(uid: String) async -> Result<SyncStatusDTO?, Error> {
        var lastError: Error = CancellationError()
        for attempt in 0..<Self.remoteCheckMaxAttempts {
            do {
                return .success(try await syncService.fetchSyncStatus(uid: uid))
            } catch {
                lastError = error
                if attempt < Self.remoteCheckMaxAttempts - 1 {
                    try? await Task.sleep(for: Self.remoteCheckRetryDelay)
                }
            }
        }
        return .failure(lastError)
    }

    // MARK: - Explicit sign-out (guest-first)

    /// Sign-out under guest-first: reverses the old "sign-out doesn't erase
    /// your closet" contract described in this file's header — deliberate,
    /// since guest-first means there's no true signed-out state to fall
    /// back to anymore. Drains the outgoing account's outbox, wipes the
    /// local mirror, signs out, then immediately starts a fresh anonymous
    /// session so the app is never left without a working (if capped) AI
    /// session. Orchestrated here rather than left to the `$uid` Combine
    /// subscription alone so `AccountSectionViewModel` can `await` the
    /// whole sequence and show `isSyncingAccountSwitch` for its full
    /// duration; `Self.currentMirrorUID` is cleared before signing out so
    /// `handleSignIn`'s own wipe-on-different-account branch is a no-op
    /// when the automatic subscription independently reacts to the new
    /// anonymous uid afterward.
    func performExplicitSignOut() async {
        guard let outgoingUID = AuthService.shared.uid else { return }
        AppLog.info(.sync, "performExplicitSignOut: outgoingUID=\(outgoingUID)")
        isSyncingAccountSwitch = true
        defer { isSyncingAccountSwitch = false }

        await wipeLocalMirror(outgoingUID: outgoingUID)
        Self.currentMirrorUID = nil
        try? AuthService.shared.signOut()

        guard let newUID = await AuthService.shared.ensureGuestSession() else {
            AppLog.error(.sync, "performExplicitSignOut: failed to establish a new guest session")
            return
        }
        await handleSignIn(uid: newUID)
    }

    /// Bounded drain-before-wipe: best-effort — races the outgoing account's
    /// outbox drain against a timeout rather than blocking indefinitely (an
    /// offline user must still be able to switch accounts), then wipes
    /// either way. Closes the common "switched accounts moments after
    /// adding an item" race, since per-mutation pushes are otherwise
    /// fire-and-forget and could still be in flight when this runs.
    private static let drainBeforeWipeTimeout: TimeInterval = 5

    private func wipeLocalMirror(outgoingUID: String) async {
        AppLog.info(.sync, "wipeLocalMirror: outgoingUID=\(outgoingUID)")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [outboxWorker] in _ = await outboxWorker.drainNow(uid: outgoingUID) }
            group.addTask { try? await Task.sleep(for: .seconds(Self.drainBeforeWipeTimeout)) }
            await group.next()
            group.cancelAll()
        }

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
        // The outgoing account's portrait must not leak into whichever
        // account is switched into next — mirrors `ImageStorage.wipeAll()`
        // just above. Re-fetched by the incoming account's background
        // prefetch (`downloadMissingPhotos`) if it has one in Cloud Storage.
        UserPortraitStorage.delete()
    }

    // MARK: - Account deletion

    /// Permanently deletes the signed-in account: server-side data
    /// (Firestore subtree + Storage files + the Auth user itself, via
    /// `Services/AccountDeletionService.swift`) first, then the local
    /// mirror — never the other order, so a failed server call can't strand
    /// local data with no server copy having actually been purged. Reuses
    /// `wipeLocalMirror`/the guest-reset tail of `performExplicitSignOut`
    /// rather than duplicating that sequence. Returns whether it succeeded;
    /// the caller (`Features/Profile/AccountSectionView.swift`) surfaces a
    /// retryable error on `false` instead of assuming the account is gone.
    @discardableResult
    func deleteAccount() async -> Bool {
        guard let outgoingUID = AuthService.shared.uid else { return false }
        isSyncingAccountSwitch = true
        defer { isSyncingAccountSwitch = false }

        do {
            try await ServiceFactory.makeAccountDeletionService().deleteAccount()
        } catch {
            lastSyncError = error.localizedDescription
            return false
        }

        await wipeLocalMirror(outgoingUID: outgoingUID)
        Self.currentMirrorUID = nil
        try? AuthService.shared.signOut()

        guard let newUID = await AuthService.shared.ensureGuestSession() else { return true }
        await handleSignIn(uid: newUID)
        return true
    }

    // MARK: - Bootstrap: push everything local up (first sign-in ever for this account)

    /// Routes every entity through the same durable `SyncMetadata` outbox
    /// ordinary mutations use (`SyncingWardrobeRepository.markDirty`),
    /// instead of firing ad hoc pushes wrapped in `try?` that vanish without
    /// a retry record on failure. Returns whether the drain finished with
    /// zero dirty rows left — the caller only stamps `hasCompletedInitialSync`
    /// on `true`; anything still dirty stays durably queued for the normal
    /// per-mutation/foreground drain to retry later.
    @discardableResult
    private func pushEverythingLocal(uid: String) async -> Bool {
        for item in (try? repository.fetchInventory()) ?? [] {
            markDirtyForBootstrap(.wardrobeItem, entityID: item.id, dto: WardrobeItemDTO.from(item))
        }
        for feedback in (try? modelContext.fetch(FetchDescriptor<OutfitFeedback>())) ?? [] {
            markDirtyForBootstrap(.outfitFeedback, entityID: feedback.id, dto: OutfitFeedbackDTO.from(feedback))
        }
        for feedback in (try? modelContext.fetch(FetchDescriptor<ItemFeedback>())) ?? [] {
            markDirtyForBootstrap(.itemFeedback, entityID: feedback.id, dto: ItemFeedbackDTO.from(feedback))
        }
        for feedback in (try? modelContext.fetch(FetchDescriptor<PairFeedback>())) ?? [] {
            markDirtyForBootstrap(.pairFeedback, entityID: feedback.id, dto: PairFeedbackDTO.from(feedback))
        }
        for rating in (try? modelContext.fetch(FetchDescriptor<ItemRating>())) ?? [] {
            markDirtyForBootstrap(.itemRating, entityID: rating.id, dto: ItemRatingDTO.from(rating))
        }
        for combination in (try? repository.fetchSavedCombinations()) ?? [] {
            markDirtyForBootstrap(.savedCombination, entityID: combination.id, dto: SavedCombinationDTO.from(combination))
        }
        for event in (try? modelContext.fetch(FetchDescriptor<SwipeEvent>())) ?? [] {
            markDirtyForBootstrap(.swipeEvent, entityID: event.id, dto: SwipeEventDTO.from(event))
        }
        if let profile = try? repository.fetchUserProfile() {
            markDirtyForBootstrap(.userStyleProfile, entityID: profile.id, dto: UserStyleProfileDTO.from(profile))
        }
        if let state = try? repository.fetchVisualPreferenceState() {
            markDirtyForBootstrap(.visualPreferenceState, entityID: state.id, dto: VisualPreferenceStateDTO.from(state))
        }
        try? modelContext.save()

        await uploadAllLocalPhotos(uid: uid)

        let fullySynced = await outboxWorker.drainNow(uid: uid)
        AppLog.info(.sync, "pushEverythingLocal: bootstrap push finished, fullySynced=\(fullySynced)")
        return fullySynced
    }

    /// Same shape as `SyncingWardrobeRepository.upsertSyncMetadata`, kept as
    /// its own copy rather than shared — that method lives on the decorator
    /// used by ordinary per-mutation writes, while this coordinator
    /// deliberately never holds that decorator (see file header: routing
    /// bulk pull-applied writes back through it would re-mark pulled rows
    /// dirty and push them right back, an infinite no-op loop). Bootstrap
    /// push is the one path here that legitimately needs to *create* dirty
    /// rows rather than clean ones.
    private func markDirtyForBootstrap(_ type: SyncEntityType, entityID: UUID, dto: some Encodable) {
        guard let payload = try? JSONEncoder().encode(dto) else { return }
        let key = SyncMetadata.compositeKey(entityType: type, entityID: entityID)
        let descriptor = FetchDescriptor<SyncMetadata>(predicate: #Predicate { $0.compositeKey == key })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.operation = .upsert
            existing.isDirty = true
            existing.localUpdatedAt = .now
            existing.attemptCount = 0
            existing.lastAttemptAt = nil
            existing.payload = payload
        } else {
            modelContext.insert(SyncMetadata(entityType: type, entityID: entityID, operation: .upsert, payload: payload))
        }
    }

    private func uploadAllLocalPhotos(uid: String) async {
        for item in (try? repository.fetchInventory()) ?? [] {
            guard let assetName = item.imageAssetName, let data = ImageStorage.loadData(for: assetName) else { continue }
            try? await syncService.uploadImage(filename: assetName, data: ImageStorage.downscaledPNGForUpload(data), contentType: .png, uid: uid)
        }
        for combination in (try? repository.fetchSavedCombinations()) ?? [] {
            guard let data = ImageStorage.loadData(for: combination.imageAssetName) else { continue }
            try? await syncService.uploadImage(filename: combination.imageAssetName, data: ImageStorage.downscaledJPEGForUpload(data), contentType: .jpeg, uid: uid)
        }
        if UserPortraitStorage.exists, let data = UserPortraitStorage.load() {
            try? await syncService.uploadPortrait(data: data, uid: uid)
        }
    }

    // MARK: - Pull (bootstrap full pull and steady-state delta reconcile share this)

    @discardableResult
    private func fullPull(uid: String) async -> Bool {
        await pullAndApply(uid: uid, since: nil)
    }

    private func reconcile(uid: String) async {
        let since = (try? await syncService.fetchSyncStatus(uid: uid))?.lastPulledAt
        await pullAndApply(uid: uid, since: since)
    }

    /// Returns whether the pull actually landed — `handleSignIn`'s bootstrap
    /// vs. returning-account branch only trusts `currentMirrorUID` on a
    /// confirmed success (see that method); `reconcile`'s callers don't need
    /// this (a missed delta pull is caught by the next foreground/mutation).
    @discardableResult
    private func pullAndApply(uid: String, since: Date?) async -> Bool {
        guard let delta = try? await syncService.pullChanges(uid: uid, since: since) else {
            AppLog.error(.sync, "pullAndApply: pullChanges failed, since=\(since.map(String.init(describing:)) ?? "nil")")
            return false
        }

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
        AppLog.info(.sync, "pullAndApply: applied ok, since=\(since.map(String.init(describing:)) ?? "nil")")
        let service = syncService
        Task { await self.downloadMissingPhotos(uid: uid, syncService: service) }

        return true
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
            // Only drop the on-disk photo when the incoming row actually
            // references a *different* file — deleting it unconditionally
            // here (as this used to) destroys a perfectly good local photo
            // on every routine reconcile, not just when the photo changed,
            // relying on a re-download that silently never lands whenever
            // the original upload never made it to Cloud Storage either.
            if let assetName = existing.imageAssetName, assetName != dto?.imageAssetName {
                ImageStorage.delete(assetName)
            }
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
            // See `applyWardrobeItemChange`'s comment — only drop the local
            // render when the incoming row actually points at a different
            // file, not on every routine reconcile.
            if existing.imageAssetName != dto?.imageAssetName {
                ImageStorage.delete(existing.imageAssetName)
            }
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
    /// a detached `Task` after `pullAndApply` already returned. Also
    /// backfills the portrait, which has no SwiftData row to key a "missing"
    /// check off — presence is just "no local file yet" (same simplification
    /// as item/combination photos: an *updated* remote portrait with the
    /// same fixed filename won't be re-fetched, only a wholly missing one —
    /// acceptable at this app's current single-portrait-per-account scale).
    /// Bumps `photoRefreshTick` once at the end if anything was actually
    /// written, so views keyed off it redraw at most once per batch.
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

        var didWriteAnything = false
        for filename in missingFilenames {
            guard let data = try? await syncService.downloadImage(filename: filename, uid: uid) else { continue }
            try? ImageStorage.write(data, filename: filename)
            didWriteAnything = true
        }

        if !UserPortraitStorage.exists, (try? await syncService.fetchPortraitUpdatedAt(uid: uid)) != nil,
           let portraitData = try? await syncService.downloadPortrait(uid: uid) {
            try? UserPortraitStorage.save(portraitData)
            didWriteAnything = true
        }

        if didWriteAnything {
            AppLog.info(.sync, "downloadMissingPhotos: fetched \(missingFilenames.count) file(s)")
            photoRefreshTick += 1
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
