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

/// One dirty `SyncMetadata` row queued for a batched push —
/// `Data/SyncOutboxWorker.swift` groups these into chunks of up to
/// `FirestoreWardrobeSyncService.maxBatchSize` and hands each chunk to
/// `commitBatch` as a single Firestore `WriteBatch`, instead of the one
/// `setData` round trip per row this used to be. Mirrors `SyncMetadata`'s own
/// fields exactly — this is just the subset the transport layer needs, kept
/// separate so this file doesn't import SwiftData for a `@Model` reference.
struct SyncBatchOperation {
    var entityType: SyncEntityType
    var entityID: UUID
    var operation: SyncOperation
    /// JSON-encoded DTO snapshot — `nil` for `.delete` (a tombstone needs no
    /// payload), mirrors `SyncMetadata.payload`.
    var payload: Data?
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
    var analyticsSnapshots: [PulledChange<AnalyticsSnapshotDTO>] = []
    var recommendationAnalyticsSnapshots: [PulledChange<RecommendationAnalyticsSnapshotDTO>] = []
    var wornLogEntries: [PulledChange<WornLogEntryDTO>] = []
    /// Anti-Repetition — see `Models/ItemPairBan.swift`.
    var itemPairBans: [PulledChange<ItemPairBanDTO>] = []
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
    /// Commits every operation in `operations` as a single Firestore
    /// `WriteBatch` — atomic as a whole (all land or none do), so
    /// `Data/SyncOutboxWorker.swift` never hands this more than
    /// `FirestoreWardrobeSyncService.maxBatchSize` operations at once
    /// (Firestore's hard per-batch cap) and, on a thrown error, retries
    /// every row in `operations` again individually (each keeping its own
    /// backoff) rather than assuming partial progress. Replaces what used to
    /// be 11 separate `pushX(dto:uid:)` methods plus `deleteEntity` — those
    /// had exactly one caller (`SyncOutboxWorker`), and this is the batched
    /// shape that same caller now needs.
    func commitBatch(_ operations: [SyncBatchOperation], uid: String) async throws

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

    /// Server-generated ~384px-longest-edge variant
    /// (`backend/functions/src/triggers/wardrobeImageProcessing.ts`) at
    /// `users/{uid}/wardrobeImages/thumbnails/{filename}`. Throws for any
    /// item uploaded before this feature shipped, or briefly for a
    /// just-uploaded item whose trigger hasn't finished yet (eventual
    /// consistency) — callers must catch and fall back to `downloadImage`,
    /// never treat this as fatal.
    func downloadThumbnail(filename: String, uid: String) async throws -> Data

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

    // MARK: - Push (batched)

    /// Firestore's hard cap on operations in a single `WriteBatch`.
    static let maxBatchSize = 500

    func commitBatch(_ operations: [SyncBatchOperation], uid: String) async throws {
        guard !operations.isEmpty else { return }
        let batch = db.batch()
        let decoder = JSONDecoder()
        for operation in operations {
            guard let ref = documentReference(entityType: operation.entityType, entityID: operation.entityID, uid: uid) else { continue }
            if operation.operation == .delete {
                // Tombstone — merge, not overwrite, so only these two fields
                // change on an otherwise-untouched doc (matches the old
                // single-row `deleteEntity`'s semantics).
                batch.setData(["isDeleted": true, "updatedAt": FieldValue.serverTimestamp()], forDocument: ref, merge: true)
                continue
            }
            guard let payload = operation.payload,
                  let data = try? Self.encodedData(entityType: operation.entityType, payload: payload, decoder: decoder)
            else { continue }
            batch.setData(data, forDocument: ref)
        }
        try await batch.commit()
    }

    private func documentReference(entityType: SyncEntityType, entityID: UUID, uid: String) -> DocumentReference? {
        switch entityType {
        // Single-row `meta` docs are keyed by a fixed doc name, not `entityID`.
        case .userStyleProfile:
            return usersDoc(uid).collection("meta").document("styleProfile")
        case .visualPreferenceState:
            return usersDoc(uid).collection("meta").document("visualPreferenceState")
        default:
            guard let collection = Self.collectionName(for: entityType) else { return nil }
            return usersDoc(uid).collection(collection).document(entityID.uuidString)
        }
    }

    /// Decodes `payload` into its typed DTO for `entityType`, Firestore-encodes
    /// it, and merges in a fresh server timestamp plus a cleared tombstone
    /// flag (`isDeleted = false`, in case this id was previously soft-deleted
    /// and is now being recreated) — one switch instead of the 11 near-identical
    /// `pushX` methods this used to be spread across, now that every push
    /// funnels through `commitBatch`.
    private static func encodedData(entityType: SyncEntityType, payload: Data, decoder: JSONDecoder) throws -> [String: Any] {
        var data: [String: Any]
        switch entityType {
        case .wardrobeItem:
            data = try Firestore.Encoder().encode(decoder.decode(WardrobeItemDTO.self, from: payload))
        case .outfitFeedback:
            data = try Firestore.Encoder().encode(decoder.decode(OutfitFeedbackDTO.self, from: payload))
        case .itemFeedback:
            data = try Firestore.Encoder().encode(decoder.decode(ItemFeedbackDTO.self, from: payload))
        case .pairFeedback:
            data = try Firestore.Encoder().encode(decoder.decode(PairFeedbackDTO.self, from: payload))
        case .itemRating:
            data = try Firestore.Encoder().encode(decoder.decode(ItemRatingDTO.self, from: payload))
        case .savedCombination:
            data = try Firestore.Encoder().encode(decoder.decode(SavedCombinationDTO.self, from: payload))
        case .userStyleProfile:
            data = try Firestore.Encoder().encode(decoder.decode(UserStyleProfileDTO.self, from: payload))
        case .visualPreferenceState:
            data = try Firestore.Encoder().encode(decoder.decode(VisualPreferenceStateDTO.self, from: payload))
        case .analyticsSnapshot:
            data = try Firestore.Encoder().encode(decoder.decode(AnalyticsSnapshotDTO.self, from: payload))
        case .recommendationAnalyticsSnapshot:
            data = try Firestore.Encoder().encode(decoder.decode(RecommendationAnalyticsSnapshotDTO.self, from: payload))
        case .wornLogEntry:
            data = try Firestore.Encoder().encode(decoder.decode(WornLogEntryDTO.self, from: payload))
        case .itemPairBan:
            data = try Firestore.Encoder().encode(decoder.decode(ItemPairBanDTO.self, from: payload))
        case .swipeEvent:
            // Legacy no-op — never queued (see `SyncOutboxWorker.drainNow`,
            // which drains any pre-existing `.swipeEvent` row locally
            // without ever reaching this method).
            data = [:]
        }
        data["updatedAt"] = FieldValue.serverTimestamp()
        data["isDeleted"] = false
        return data
    }

    private static func collectionName(for type: SyncEntityType) -> String? {
        switch type {
        case .wardrobeItem: return "wardrobeItems"
        case .outfitFeedback: return "outfitFeedback"
        case .itemFeedback: return "itemFeedback"
        case .pairFeedback: return "pairFeedback"
        case .itemRating: return "itemRatings"
        case .savedCombination: return "savedCombinations"
        case .analyticsSnapshot: return "analyticsSnapshots"
        case .recommendationAnalyticsSnapshot: return "recommendationAnalyticsSnapshots"
        case .wornLogEntry: return "wornLogEntries"
        case .itemPairBan: return "itemPairBans"
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
        async let analyticsSnapshots: [PulledChange<AnalyticsSnapshotDTO>] = Self.fetchCollection(usersRef.collection("analyticsSnapshots"), since: since)
        async let recommendationAnalyticsSnapshots: [PulledChange<RecommendationAnalyticsSnapshotDTO>] = Self.fetchCollection(usersRef.collection("recommendationAnalyticsSnapshots"), since: since)
        async let wornLogEntries: [PulledChange<WornLogEntryDTO>] = Self.fetchCollection(usersRef.collection("wornLogEntries"), since: since)
        async let itemPairBans: [PulledChange<ItemPairBanDTO>] = Self.fetchCollection(usersRef.collection("itemPairBans"), since: since)
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
                analyticsSnapshots: try await analyticsSnapshots,
                recommendationAnalyticsSnapshots: try await recommendationAnalyticsSnapshots,
                wornLogEntries: try await wornLogEntries,
                itemPairBans: try await itemPairBans,
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

    private func thumbnailRef(filename: String, uid: String) -> StorageReference {
        storage.reference().child("users/\(uid)/wardrobeImages/thumbnails/\(filename)")
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

    /// 15 MiB cap matches `backend/storage.rules`' upload-size limit, though
    /// in practice the server-generated thumbnail is far smaller.
    func downloadThumbnail(filename: String, uid: String) async throws -> Data {
        do {
            let data = try await thumbnailRef(filename: filename, uid: uid).data(maxSize: 15 * 1024 * 1024)
            AppLog.info(.sync, "downloadThumbnail: \(filename) ok bytes=\(data.count)")
            return data
        } catch {
            AppLog.error(.sync, "downloadThumbnail: \(filename) failed — \(String(describing: error))")
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

    func commitBatch(_ operations: [SyncBatchOperation], uid: String) async throws {
        try await current.commitBatch(operations, uid: uid)
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
    func downloadThumbnail(filename: String, uid: String) async throws -> Data {
        try await current.downloadThumbnail(filename: filename, uid: uid)
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
    func commitBatch(_ operations: [SyncBatchOperation], uid: String) async throws {}
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
    func downloadThumbnail(filename: String, uid: String) async throws -> Data {
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
