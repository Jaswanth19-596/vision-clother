//
//  WardrobeSyncService.swift
//  Vision_clother
//
//  Cloud Sync (docs/decisions/resolved-v1.md's "Cloud Sync" section): the
//  Firestore/Cloud Storage transport for `Data/SyncOutboxWorker.swift` (push)
//  and `Data/WardrobeSyncCoordinator.swift` (pull/bootstrap). Talks to
//  Firestore/Storage directly — no backend involvement, gated by security
//  rules keyed on `request.auth.uid` (`backend/firestore.rules`,
//  `backend/storage.rules`).
//
//  Every push merges in a fresh `FieldValue.serverTimestamp()` for
//  `updatedAt` as a raw dictionary field alongside the Codable-encoded DTO
//  (never trusting a client clock, which would skew delta-pull's `updatedAt >`
//  watermark query across devices) — see `FirestoreDTOs.swift`'s file-level
//  note for why this happens here rather than via a `@ServerTimestamp`
//  property on the DTOs themselves.
//

import FirebaseFirestore
import FirebaseStorage
import Foundation

/// One changed document from a delta/full pull, paired with its
/// server-authoritative `updatedAt` — `Data/WardrobeSyncCoordinator.swift`
/// needs that timestamp for conflict resolution (comparing against a local
/// `SyncMetadata.localUpdatedAt`), not just the decoded DTO.
enum PulledChange<DTO> {
    case upsert(DTO, updatedAt: Date)
    /// Tombstone — `Data/WardrobeSyncCoordinator.swift` removes the matching
    /// local row rather than materializing anything.
    case deleted(id: String, updatedAt: Date)
}

/// A changed single-row `meta` doc (`UserStyleProfile`/`VisualPreferenceState`)
/// — no delete variant, these are only ever upserted.
struct RemoteMetaUpdate<DTO> {
    var dto: DTO
    var updatedAt: Date
}

/// MIME type for a Cloud Storage photo upload — required so
/// `backend/storage.rules`' `request.resource.contentType.matches('image/.*')`
/// check actually passes. Every `WardrobeItem` cutout is PNG
/// (`ImageStorage.downscaledPNGForUpload`, alpha-preserving); every
/// `SavedCombination` render is JPEG (`ImageStorage.downscaledJPEGForUpload`).
enum SyncImageContentType: String {
    case png = "image/png"
    case jpeg = "image/jpeg"
}

/// Everything pulled in one `pullChanges` call.
struct PulledWardrobeDelta {
    var wardrobeItems: [PulledChange<WardrobeItemDTO>] = []
    var outfitFeedback: [PulledChange<OutfitFeedbackDTO>] = []
    var itemFeedback: [PulledChange<ItemFeedbackDTO>] = []
    var pairFeedback: [PulledChange<PairFeedbackDTO>] = []
    var itemRatings: [PulledChange<ItemRatingDTO>] = []
    var savedCombinations: [PulledChange<SavedCombinationDTO>] = []
    var userStyleProfile: RemoteMetaUpdate<UserStyleProfileDTO>?
    var visualPreferenceState: RemoteMetaUpdate<VisualPreferenceStateDTO>?
    /// Captured before this pull's queries ran — the candidate new
    /// `lastPulledAt` watermark on success (minus a safety buffer; see
    /// `Data/WardrobeSyncCoordinator.swift`). Never the max doc timestamp
    /// seen — a doc written mid-pull must not be silently skipped.
    var queryStartTime: Date
}

/// Pure network I/O (Firestore/Storage transport) — deliberately *not*
/// `@MainActor` (see HIGH-3 in `docs/decisions/resolved-v1.md`'s Cloud Sync
/// section): forcing every push/pull/photo transfer onto the main actor
/// serializes work that has no UI dependency until it completes. Every
/// caller (`Data/SyncOutboxWorker.swift`, `Data/WardrobeSyncCoordinator.swift`,
/// `Data/SyncingWardrobeRepository.swift`) is itself `@MainActor` and is the
/// only place allowed to touch `ModelContext`; those callers already do all
/// their local SwiftData mutations directly (not through this protocol), so
/// removing this annotation only frees the network legs to run off the main
/// actor's serial executor, not any local persistence.
protocol WardrobeSyncService {
    // Pure DTO transport, deliberately not `@Model` types — the caller is
    // `Data/SyncOutboxWorker.swift`, draining `SyncMetadata.payload` (a
    // JSON-encoded DTO captured at mutation time, see that model's doc
    // comment), which never has a live `@Model` instance to hand over.
    func pushWardrobeItem(_ dto: WardrobeItemDTO, uid: String) async throws
    func pushOutfitFeedback(_ dto: OutfitFeedbackDTO, uid: String) async throws
    func pushItemFeedback(_ dto: ItemFeedbackDTO, uid: String) async throws
    func pushPairFeedback(_ dto: PairFeedbackDTO, uid: String) async throws
    func pushItemRating(_ dto: ItemRatingDTO, uid: String) async throws
    func pushSavedCombination(_ dto: SavedCombinationDTO, uid: String) async throws
    func pushUserStyleProfile(_ dto: UserStyleProfileDTO, uid: String) async throws
    func pushVisualPreferenceState(_ dto: VisualPreferenceStateDTO, uid: String) async throws

    /// Soft-deletes (tombstones) an entity — only meaningful for the 6
    /// event/row-per-entity types, not the 2 single-row `meta` docs (nothing
    /// in `WardrobeRepository` ever deletes those).
    func deleteEntity(type: SyncEntityType, id: UUID, uid: String) async throws

    /// `since: nil` is a full pull (bootstrap); a non-nil date is a delta
    /// pull bounded to `updatedAt > since` per collection.
    func pullChanges(uid: String, since: Date?) async throws -> PulledWardrobeDelta

    func fetchSyncStatus(uid: String) async throws -> SyncStatusDTO?
    func initializeSyncStatus(uid: String) async throws
    /// `date` is a client-captured watermark (see `PulledWardrobeDelta.queryStartTime`'s
    /// doc comment) — stored as a plain value, not a server timestamp.
    func updateLastPulledAt(uid: String, date: Date) async throws

    func uploadImage(filename: String, data: Data, contentType: SyncImageContentType, uid: String) async throws
    func downloadImage(filename: String, uid: String) async throws -> Data

    /// Portrait sync: the user's own try-on base photo
    /// (`Services/UserPortraitStorage.swift`) is a single fixed file per
    /// account, not a `WardrobeItem`/`SavedCombination` row — so unlike
    /// `uploadImage`/`downloadImage` it has no per-file `filename` and
    /// carries its own presence/timestamp doc (`meta/portrait`) instead of
    /// riding along with a synced entity. Same best-effort posture as the
    /// other photo transports (not part of the durable `SyncMetadata`
    /// outbox) — see `Data/WardrobeSyncCoordinator.swift`.
    func uploadPortrait(data: Data, uid: String) async throws
    func downloadPortrait(uid: String) async throws -> Data
    /// `nil` means no portrait has ever been uploaded for this account.
    func fetchPortraitUpdatedAt(uid: String) async throws -> Date?

    /// Read-only — `AccountSectionView`'s usage readout. `nil` means no
    /// requests made yet this period (never written to).
    func fetchUsage(uid: String) async throws -> UsageDTO?

    /// Client-side counterpart to `backend/firestore.rules`'s
    /// `meta/itemCounts` cap enforcement — `Data/UsageTracker.swift`'s
    /// `itemCap(for:)` pre-check is the fast, optimistic UX guard; this is
    /// what actually moves the counter the rules validate against. Called
    /// best-effort/fire-and-forget from `Data/SyncingWardrobeRepository.swift`'s
    /// `save`/`delete` (same posture as `uploadImageIfNeeded`) — not
    /// transactionally atomic with the item doc write itself, a documented
    /// gap acceptable at this app's scale (see `backend/firestore.rules`'s
    /// comment on `meta/itemCounts`).
    func adjustItemCount(slot: Slot, delta: Int, uid: String) async throws
}

/// Not `@MainActor` — see the protocol's doc comment above. `db`/`storage`
/// are immutable references into thread-safe Firebase SDK singletons, and
/// every method here is pure network I/O with no local persistence, so
/// nothing in this type needs main-actor isolation.
final class FirestoreWardrobeSyncService: WardrobeSyncService {
    private let db = Firestore.firestore()
    private let storage = Storage.storage()

    private func usersDoc(_ uid: String) -> DocumentReference {
        db.collection("users").document(uid)
    }

    /// Shared push helper: encodes `dto` via Firestore's Codable support,
    /// merges in a fresh server timestamp for `updatedAt` and clears any
    /// prior tombstone (`isDeleted = false`, in case this id was previously
    /// soft-deleted and is now being recreated), and writes it all in one
    /// call — one write per push, not a separate encode-then-stamp round trip.
    private func setDocument(_ ref: DocumentReference, dto: some Encodable) async throws {
        var data = try Firestore.Encoder().encode(dto)
        data["updatedAt"] = FieldValue.serverTimestamp()
        data["isDeleted"] = false
        try await ref.setData(data)
    }

    // MARK: - Push

    func pushWardrobeItem(_ dto: WardrobeItemDTO, uid: String) async throws {
        try await setDocument(usersDoc(uid).collection("wardrobeItems").document(dto.id), dto: dto)
    }

    func pushOutfitFeedback(_ dto: OutfitFeedbackDTO, uid: String) async throws {
        try await setDocument(usersDoc(uid).collection("outfitFeedback").document(dto.id), dto: dto)
    }

    func pushItemFeedback(_ dto: ItemFeedbackDTO, uid: String) async throws {
        try await setDocument(usersDoc(uid).collection("itemFeedback").document(dto.id), dto: dto)
    }

    func pushPairFeedback(_ dto: PairFeedbackDTO, uid: String) async throws {
        try await setDocument(usersDoc(uid).collection("pairFeedback").document(dto.id), dto: dto)
    }

    func pushItemRating(_ dto: ItemRatingDTO, uid: String) async throws {
        try await setDocument(usersDoc(uid).collection("itemRatings").document(dto.id), dto: dto)
    }

    func pushSavedCombination(_ dto: SavedCombinationDTO, uid: String) async throws {
        try await setDocument(usersDoc(uid).collection("savedCombinations").document(dto.id), dto: dto)
    }

    func pushUserStyleProfile(_ dto: UserStyleProfileDTO, uid: String) async throws {
        try await setDocument(usersDoc(uid).collection("meta").document("styleProfile"), dto: dto)
    }

    func pushVisualPreferenceState(_ dto: VisualPreferenceStateDTO, uid: String) async throws {
        try await setDocument(usersDoc(uid).collection("meta").document("visualPreferenceState"), dto: dto)
    }

    // MARK: - Delete (tombstone)

    func deleteEntity(type: SyncEntityType, id: UUID, uid: String) async throws {
        guard let collection = Self.collectionName(for: type) else { return }
        try await usersDoc(uid).collection(collection).document(id.uuidString)
            .setData(["isDeleted": true, "updatedAt": FieldValue.serverTimestamp()], merge: true)
    }

    private static func collectionName(for type: SyncEntityType) -> String? {
        switch type {
        case .wardrobeItem: return "wardrobeItems"
        case .outfitFeedback: return "outfitFeedback"
        case .itemFeedback: return "itemFeedback"
        case .pairFeedback: return "pairFeedback"
        case .itemRating: return "itemRatings"
        case .savedCombination: return "savedCombinations"
        // Single-row meta docs are never deleted; `swipeEvent` is legacy-only
        // (see `Models/SyncMetadata.swift`) and never pushed/deleted either.
        case .userStyleProfile, .visualPreferenceState, .swipeEvent: return nil
        }
    }

    // MARK: - Pull

    func pullChanges(uid: String, since: Date?) async throws -> PulledWardrobeDelta {
        AppLog.info(.sync, "pullChanges: starting, since=\(since.map(String.init(describing:)) ?? "nil") (full pull)")
        let queryStartTime = Date()
        let usersRef = usersDoc(uid)

        async let wardrobeItems: [PulledChange<WardrobeItemDTO>] = Self.fetchCollection(usersRef.collection("wardrobeItems"), since: since)
        async let outfitFeedback: [PulledChange<OutfitFeedbackDTO>] = Self.fetchCollection(usersRef.collection("outfitFeedback"), since: since)
        async let itemFeedback: [PulledChange<ItemFeedbackDTO>] = Self.fetchCollection(usersRef.collection("itemFeedback"), since: since)
        async let pairFeedback: [PulledChange<PairFeedbackDTO>] = Self.fetchCollection(usersRef.collection("pairFeedback"), since: since)
        async let itemRatings: [PulledChange<ItemRatingDTO>] = Self.fetchCollection(usersRef.collection("itemRatings"), since: since)
        async let savedCombinations: [PulledChange<SavedCombinationDTO>] = Self.fetchCollection(usersRef.collection("savedCombinations"), since: since)
        async let userStyleProfile: RemoteMetaUpdate<UserStyleProfileDTO>? = Self.fetchMetaDocIfChanged(usersRef.collection("meta").document("styleProfile"), since: since)
        async let visualPreferenceState: RemoteMetaUpdate<VisualPreferenceStateDTO>? = Self.fetchMetaDocIfChanged(usersRef.collection("meta").document("visualPreferenceState"), since: since)

        do {
            let delta = PulledWardrobeDelta(
                wardrobeItems: try await wardrobeItems,
                outfitFeedback: try await outfitFeedback,
                itemFeedback: try await itemFeedback,
                pairFeedback: try await pairFeedback,
                itemRatings: try await itemRatings,
                savedCombinations: try await savedCombinations,
                userStyleProfile: try await userStyleProfile,
                visualPreferenceState: try await visualPreferenceState,
                queryStartTime: queryStartTime
            )
            AppLog.info(.sync, "pullChanges: ok items=\(delta.wardrobeItems.count) outfitFeedback=\(delta.outfitFeedback.count) itemFeedback=\(delta.itemFeedback.count) pairFeedback=\(delta.pairFeedback.count) itemRatings=\(delta.itemRatings.count) savedCombinations=\(delta.savedCombinations.count)")
            return delta
        } catch {
            AppLog.error(.sync, "pullChanges: failed — \(String(describing: error))")
            throw error
        }
    }

    /// Docs per page — bounds a single Firestore round trip regardless of
    /// collection size. A delta pull (`since` non-nil) rarely spans more
    /// than one page, but a full/bootstrap pull (`since == nil`, a
    /// fresh-device sign-in) previously issued one unbounded
    /// `getDocuments()` per collection — fine for a new account, but
    /// unbounded for an engaged user's `wardrobeItems`/`itemRatings`
    /// history. `.order(by: "updatedAt")` paired with the `since` range
    /// filter on that same field is a single-field index Firestore
    /// maintains automatically, so this needs no `firestore.indexes.json`
    /// change.
    private static let pullPageSize = 300

    private static func fetchCollection<T: Decodable>(_ collection: CollectionReference, since: Date?) async throws -> [PulledChange<T>] {
        var results: [PulledChange<T>] = []
        var lastDoc: DocumentSnapshot?
        while true {
            var query: Query = collection.order(by: "updatedAt")
            if let since {
                query = query.whereField("updatedAt", isGreaterThan: Timestamp(date: since))
            }
            if let lastDoc {
                query = query.start(afterDocument: lastDoc)
            }
            let snapshot = try await query.limit(to: pullPageSize).getDocuments()
            results += snapshot.documents.compactMap { doc -> PulledChange<T>? in
                guard let updatedAtTimestamp = doc.get("updatedAt") as? Timestamp else { return nil }
                let updatedAt = updatedAtTimestamp.dateValue()
                if (doc.get("isDeleted") as? Bool) == true {
                    return .deleted(id: doc.documentID, updatedAt: updatedAt)
                }
                guard let dto = try? doc.data(as: T.self) else { return nil }
                return .upsert(dto, updatedAt: updatedAt)
            }
            guard let last = snapshot.documents.last, snapshot.documents.count == pullPageSize else { break }
            lastDoc = last
        }
        return results
    }

    /// Single-row `meta` docs have no delta query of their own (one doc, not
    /// a collection) — fetched whenever present, filtered by `since` in code
    /// instead of in the query. `nil` if absent (never pushed yet) or
    /// unchanged since `since`.
    private static func fetchMetaDocIfChanged<T: Decodable>(_ doc: DocumentReference, since: Date?) async throws -> RemoteMetaUpdate<T>? {
        let snapshot = try await doc.getDocument()
        guard snapshot.exists, let updatedAtTimestamp = snapshot.get("updatedAt") as? Timestamp else { return nil }
        let updatedAt = updatedAtTimestamp.dateValue()
        if let since, updatedAt <= since { return nil }
        guard let dto = try? snapshot.data(as: T.self) else { return nil }
        return RemoteMetaUpdate(dto: dto, updatedAt: updatedAt)
    }

    // MARK: - Sync status

    private func syncStatusDoc(_ uid: String) -> DocumentReference {
        usersDoc(uid).collection("meta").document("syncStatus")
    }

    func fetchSyncStatus(uid: String) async throws -> SyncStatusDTO? {
        let snapshot = try await syncStatusDoc(uid).getDocument()
        guard snapshot.exists else { return nil }
        return try? snapshot.data(as: SyncStatusDTO.self)
    }

    func initializeSyncStatus(uid: String) async throws {
        try await syncStatusDoc(uid).setData(from: SyncStatusDTO(hasCompletedInitialSync: true, lastPulledAt: Date()))
    }

    func updateLastPulledAt(uid: String, date: Date) async throws {
        try await syncStatusDoc(uid).setData(["lastPulledAt": Timestamp(date: date)], merge: true)
    }

    // MARK: - Quota (read-only usage readout + item-count backstop)

    func fetchUsage(uid: String) async throws -> UsageDTO? {
        let snapshot = try await usersDoc(uid).collection("meta").document("usage").getDocument()
        guard snapshot.exists else { return nil }
        return try? snapshot.data(as: UsageDTO.self)
    }

    func adjustItemCount(slot: Slot, delta: Int, uid: String) async throws {
        let ref = usersDoc(uid).collection("meta").document("itemCounts")
        do {
            try await db.runTransaction { transaction, errorPointer -> Any? in
                let snapshot: DocumentSnapshot
                do {
                    snapshot = try transaction.getDocument(ref)
                } catch {
                    errorPointer?.pointee = error as NSError
                    return nil
                }
                let current = (snapshot.data()?[slot.rawValue] as? Int) ?? 0
                transaction.setData([slot.rawValue: max(0, current + delta)], forDocument: ref, merge: true)
                return nil
            }
        } catch {
            AppLog.error(.sync, "adjustItemCount: \(slot.rawValue) delta=\(delta) failed — \(String(describing: error))")
            throw error
        }
    }

    // MARK: - Photos

    private func imageRef(filename: String, uid: String) -> StorageReference {
        storage.reference().child("users/\(uid)/wardrobeImages/\(filename)")
    }

    /// `contentType` must be set explicitly — `putDataAsync` without a
    /// `StorageMetadata` leaves the object's content type unset, which
    /// `backend/storage.rules`' `request.resource.contentType.matches('image/.*')`
    /// write check then rejects outright. Every upload silently failed this
    /// way before this was added (verified via the Console: the bucket had
    /// zero files despite every push otherwise "succeeding").
    func uploadImage(filename: String, data: Data, contentType: SyncImageContentType, uid: String) async throws {
        AppLog.info(.sync, "uploadImage: \(filename) bytes=\(data.count) contentType=\(contentType.rawValue)")
        let metadata = StorageMetadata()
        metadata.contentType = contentType.rawValue
        do {
            _ = try await imageRef(filename: filename, uid: uid).putDataAsync(data, metadata: metadata)
            AppLog.info(.sync, "uploadImage: \(filename) ok")
        } catch {
            AppLog.error(.sync, "uploadImage: \(filename) failed — \(String(describing: error))")
            throw error
        }
    }

    /// 15 MiB cap matches `backend/storage.rules`' upload-size limit.
    func downloadImage(filename: String, uid: String) async throws -> Data {
        do {
            let data = try await imageRef(filename: filename, uid: uid).data(maxSize: 15 * 1024 * 1024)
            AppLog.info(.sync, "downloadImage: \(filename) ok bytes=\(data.count)")
            return data
        } catch {
            AppLog.error(.sync, "downloadImage: \(filename) failed — \(String(describing: error))")
            throw error
        }
    }

    // MARK: - Portrait

    private func portraitRef(uid: String) -> StorageReference {
        storage.reference().child("users/\(uid)/portrait/base_portrait.jpg")
    }

    private func portraitMetaDoc(_ uid: String) -> DocumentReference {
        usersDoc(uid).collection("meta").document("portrait")
    }

    func uploadPortrait(data: Data, uid: String) async throws {
        AppLog.info(.sync, "uploadPortrait: bytes=\(data.count)")
        let metadata = StorageMetadata()
        metadata.contentType = SyncImageContentType.jpeg.rawValue
        do {
            _ = try await portraitRef(uid: uid).putDataAsync(data, metadata: metadata)
            try await portraitMetaDoc(uid).setData(["updatedAt": FieldValue.serverTimestamp()], merge: true)
            AppLog.info(.sync, "uploadPortrait: ok")
        } catch {
            AppLog.error(.sync, "uploadPortrait: failed — \(String(describing: error))")
            throw error
        }
    }

    func downloadPortrait(uid: String) async throws -> Data {
        do {
            let data = try await portraitRef(uid: uid).data(maxSize: 15 * 1024 * 1024)
            AppLog.info(.sync, "downloadPortrait: ok bytes=\(data.count)")
            return data
        } catch {
            AppLog.error(.sync, "downloadPortrait: failed — \(String(describing: error))")
            throw error
        }
    }

    func fetchPortraitUpdatedAt(uid: String) async throws -> Date? {
        let snapshot = try await portraitMetaDoc(uid).getDocument()
        guard snapshot.exists, let timestamp = snapshot.get("updatedAt") as? Timestamp else { return nil }
        return timestamp.dateValue()
    }
}

/// Routes every call to a real or mock `WardrobeSyncService` based on
/// `AuthService.shared.isSignedIn` **at call time**, not at construction
/// time. `ServiceFactory.makeWardrobeSyncService()` used to snapshot
/// `isSignedIn` once and bake the choice into a `let` the caller held for its
/// entire lifetime — fatal for `Vision_clotherApp.init()`'s app-root
/// `WardrobeSyncCoordinator`/`SyncingWardrobeRepository`, which are
/// constructed once at launch: a cold launch while signed out permanently
/// froze them on `MockWardrobeSyncService`, silently no-op'ing every push for
/// the rest of the process's life even after a later sign-in. Both
/// `real`/`mock` are lazy so a guest/dev session with no Firebase project
/// configured never touches `Firestore.firestore()`/`Storage.storage()`.
@MainActor
final class AuthGatedWardrobeSyncService: WardrobeSyncService {
    private lazy var real = FirestoreWardrobeSyncService()
    private lazy var mock = MockWardrobeSyncService()
    private var current: WardrobeSyncService { AuthService.shared.isSignedIn ? real : mock }

    func pushWardrobeItem(_ dto: WardrobeItemDTO, uid: String) async throws {
        try await current.pushWardrobeItem(dto, uid: uid)
    }
    func pushOutfitFeedback(_ dto: OutfitFeedbackDTO, uid: String) async throws {
        try await current.pushOutfitFeedback(dto, uid: uid)
    }
    func pushItemFeedback(_ dto: ItemFeedbackDTO, uid: String) async throws {
        try await current.pushItemFeedback(dto, uid: uid)
    }
    func pushPairFeedback(_ dto: PairFeedbackDTO, uid: String) async throws {
        try await current.pushPairFeedback(dto, uid: uid)
    }
    func pushItemRating(_ dto: ItemRatingDTO, uid: String) async throws {
        try await current.pushItemRating(dto, uid: uid)
    }
    func pushSavedCombination(_ dto: SavedCombinationDTO, uid: String) async throws {
        try await current.pushSavedCombination(dto, uid: uid)
    }
    func pushUserStyleProfile(_ dto: UserStyleProfileDTO, uid: String) async throws {
        try await current.pushUserStyleProfile(dto, uid: uid)
    }
    func pushVisualPreferenceState(_ dto: VisualPreferenceStateDTO, uid: String) async throws {
        try await current.pushVisualPreferenceState(dto, uid: uid)
    }
    func deleteEntity(type: SyncEntityType, id: UUID, uid: String) async throws {
        try await current.deleteEntity(type: type, id: id, uid: uid)
    }
    func pullChanges(uid: String, since: Date?) async throws -> PulledWardrobeDelta {
        try await current.pullChanges(uid: uid, since: since)
    }
    func fetchSyncStatus(uid: String) async throws -> SyncStatusDTO? {
        try await current.fetchSyncStatus(uid: uid)
    }
    func initializeSyncStatus(uid: String) async throws {
        try await current.initializeSyncStatus(uid: uid)
    }
    func updateLastPulledAt(uid: String, date: Date) async throws {
        try await current.updateLastPulledAt(uid: uid, date: date)
    }
    func uploadImage(filename: String, data: Data, contentType: SyncImageContentType, uid: String) async throws {
        try await current.uploadImage(filename: filename, data: data, contentType: contentType, uid: uid)
    }
    func downloadImage(filename: String, uid: String) async throws -> Data {
        try await current.downloadImage(filename: filename, uid: uid)
    }
    func uploadPortrait(data: Data, uid: String) async throws {
        try await current.uploadPortrait(data: data, uid: uid)
    }
    func downloadPortrait(uid: String) async throws -> Data {
        try await current.downloadPortrait(uid: uid)
    }
    func fetchPortraitUpdatedAt(uid: String) async throws -> Date? {
        try await current.fetchPortraitUpdatedAt(uid: uid)
    }
    func fetchUsage(uid: String) async throws -> UsageDTO? {
        try await current.fetchUsage(uid: uid)
    }
    func adjustItemCount(slot: Slot, delta: Int, uid: String) async throws {
        try await current.adjustItemCount(slot: slot, delta: delta, uid: uid)
    }
}

/// Signed-out fallback — mirrors every other `ServiceFactory`-gated mock
/// (`MockIntentExtractionService` etc.): every push/pull is a silent no-op so
/// `Data/SyncingWardrobeRepository.swift`/`Data/WardrobeSyncCoordinator.swift`
/// stay interactive in Simulator/previews with no Firebase sign-in.
@MainActor
final class MockWardrobeSyncService: WardrobeSyncService {
    func pushWardrobeItem(_ dto: WardrobeItemDTO, uid: String) async throws {}
    func pushOutfitFeedback(_ dto: OutfitFeedbackDTO, uid: String) async throws {}
    func pushItemFeedback(_ dto: ItemFeedbackDTO, uid: String) async throws {}
    func pushPairFeedback(_ dto: PairFeedbackDTO, uid: String) async throws {}
    func pushItemRating(_ dto: ItemRatingDTO, uid: String) async throws {}
    func pushSavedCombination(_ dto: SavedCombinationDTO, uid: String) async throws {}
    func pushUserStyleProfile(_ dto: UserStyleProfileDTO, uid: String) async throws {}
    func pushVisualPreferenceState(_ dto: VisualPreferenceStateDTO, uid: String) async throws {}
    func deleteEntity(type: SyncEntityType, id: UUID, uid: String) async throws {}
    func pullChanges(uid: String, since: Date?) async throws -> PulledWardrobeDelta {
        PulledWardrobeDelta(queryStartTime: Date())
    }
    func fetchSyncStatus(uid: String) async throws -> SyncStatusDTO? { nil }
    func initializeSyncStatus(uid: String) async throws {}
    func updateLastPulledAt(uid: String, date: Date) async throws {}
    func uploadImage(filename: String, data: Data, contentType: SyncImageContentType, uid: String) async throws {}
    func downloadImage(filename: String, uid: String) async throws -> Data {
        throw CocoaError(.fileNoSuchFile)
    }
    func uploadPortrait(data: Data, uid: String) async throws {}
    func downloadPortrait(uid: String) async throws -> Data {
        throw CocoaError(.fileNoSuchFile)
    }
    func fetchPortraitUpdatedAt(uid: String) async throws -> Date? { nil }
    func fetchUsage(uid: String) async throws -> UsageDTO? { nil }
    func adjustItemCount(slot: Slot, delta: Int, uid: String) async throws {}
}
