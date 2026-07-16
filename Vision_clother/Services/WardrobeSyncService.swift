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

/// Everything pulled in one `pullChanges` call.
struct PulledWardrobeDelta {
    var wardrobeItems: [PulledChange<WardrobeItemDTO>] = []
    var outfitFeedback: [PulledChange<OutfitFeedbackDTO>] = []
    var itemFeedback: [PulledChange<ItemFeedbackDTO>] = []
    var pairFeedback: [PulledChange<PairFeedbackDTO>] = []
    var itemRatings: [PulledChange<ItemRatingDTO>] = []
    var savedCombinations: [PulledChange<SavedCombinationDTO>] = []
    var swipeEvents: [PulledChange<SwipeEventDTO>] = []
    var userStyleProfile: RemoteMetaUpdate<UserStyleProfileDTO>?
    var visualPreferenceState: RemoteMetaUpdate<VisualPreferenceStateDTO>?
    /// Captured before this pull's queries ran — the candidate new
    /// `lastPulledAt` watermark on success (minus a safety buffer; see
    /// `Data/WardrobeSyncCoordinator.swift`). Never the max doc timestamp
    /// seen — a doc written mid-pull must not be silently skipped.
    var queryStartTime: Date
}

@MainActor
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
    func pushSwipeEvent(_ dto: SwipeEventDTO, uid: String) async throws
    func pushVisualPreferenceState(_ dto: VisualPreferenceStateDTO, uid: String) async throws

    /// Soft-deletes (tombstones) an entity — only meaningful for the 7
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

    func uploadImage(filename: String, data: Data, uid: String) async throws
    func downloadImage(filename: String, uid: String) async throws -> Data
}

@MainActor
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

    func pushSwipeEvent(_ dto: SwipeEventDTO, uid: String) async throws {
        try await setDocument(usersDoc(uid).collection("swipeEvents").document(dto.id), dto: dto)
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
        case .swipeEvent: return "swipeEvents"
        // Single-row meta docs are never deleted.
        case .userStyleProfile, .visualPreferenceState: return nil
        }
    }

    // MARK: - Pull

    func pullChanges(uid: String, since: Date?) async throws -> PulledWardrobeDelta {
        let queryStartTime = Date()
        let usersRef = usersDoc(uid)

        async let wardrobeItems: [PulledChange<WardrobeItemDTO>] = Self.fetchCollection(usersRef.collection("wardrobeItems"), since: since)
        async let outfitFeedback: [PulledChange<OutfitFeedbackDTO>] = Self.fetchCollection(usersRef.collection("outfitFeedback"), since: since)
        async let itemFeedback: [PulledChange<ItemFeedbackDTO>] = Self.fetchCollection(usersRef.collection("itemFeedback"), since: since)
        async let pairFeedback: [PulledChange<PairFeedbackDTO>] = Self.fetchCollection(usersRef.collection("pairFeedback"), since: since)
        async let itemRatings: [PulledChange<ItemRatingDTO>] = Self.fetchCollection(usersRef.collection("itemRatings"), since: since)
        async let savedCombinations: [PulledChange<SavedCombinationDTO>] = Self.fetchCollection(usersRef.collection("savedCombinations"), since: since)
        async let swipeEvents: [PulledChange<SwipeEventDTO>] = Self.fetchCollection(usersRef.collection("swipeEvents"), since: since)
        async let userStyleProfile: RemoteMetaUpdate<UserStyleProfileDTO>? = Self.fetchMetaDocIfChanged(usersRef.collection("meta").document("styleProfile"), since: since)
        async let visualPreferenceState: RemoteMetaUpdate<VisualPreferenceStateDTO>? = Self.fetchMetaDocIfChanged(usersRef.collection("meta").document("visualPreferenceState"), since: since)

        return PulledWardrobeDelta(
            wardrobeItems: try await wardrobeItems,
            outfitFeedback: try await outfitFeedback,
            itemFeedback: try await itemFeedback,
            pairFeedback: try await pairFeedback,
            itemRatings: try await itemRatings,
            savedCombinations: try await savedCombinations,
            swipeEvents: try await swipeEvents,
            userStyleProfile: try await userStyleProfile,
            visualPreferenceState: try await visualPreferenceState,
            queryStartTime: queryStartTime
        )
    }

    private static func fetchCollection<T: Decodable>(_ collection: CollectionReference, since: Date?) async throws -> [PulledChange<T>] {
        var query: Query = collection
        if let since {
            query = query.whereField("updatedAt", isGreaterThan: Timestamp(date: since))
        }
        let snapshot = try await query.getDocuments()
        return snapshot.documents.compactMap { doc -> PulledChange<T>? in
            guard let updatedAtTimestamp = doc.get("updatedAt") as? Timestamp else { return nil }
            let updatedAt = updatedAtTimestamp.dateValue()
            if (doc.get("isDeleted") as? Bool) == true {
                return .deleted(id: doc.documentID, updatedAt: updatedAt)
            }
            guard let dto = try? doc.data(as: T.self) else { return nil }
            return .upsert(dto, updatedAt: updatedAt)
        }
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

    // MARK: - Photos

    private func imageRef(filename: String, uid: String) -> StorageReference {
        storage.reference().child("users/\(uid)/wardrobeImages/\(filename)")
    }

    func uploadImage(filename: String, data: Data, uid: String) async throws {
        _ = try await imageRef(filename: filename, uid: uid).putDataAsync(data)
    }

    /// 15 MiB cap matches `backend/storage.rules`' upload-size limit.
    func downloadImage(filename: String, uid: String) async throws -> Data {
        try await imageRef(filename: filename, uid: uid).data(maxSize: 15 * 1024 * 1024)
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
    func pushSwipeEvent(_ dto: SwipeEventDTO, uid: String) async throws {}
    func pushVisualPreferenceState(_ dto: VisualPreferenceStateDTO, uid: String) async throws {}
    func deleteEntity(type: SyncEntityType, id: UUID, uid: String) async throws {}
    func pullChanges(uid: String, since: Date?) async throws -> PulledWardrobeDelta {
        PulledWardrobeDelta(queryStartTime: Date())
    }
    func fetchSyncStatus(uid: String) async throws -> SyncStatusDTO? { nil }
    func initializeSyncStatus(uid: String) async throws {}
    func updateLastPulledAt(uid: String, date: Date) async throws {}
    func uploadImage(filename: String, data: Data, uid: String) async throws {}
    func downloadImage(filename: String, uid: String) async throws -> Data {
        throw CocoaError(.fileNoSuchFile)
    }
}
