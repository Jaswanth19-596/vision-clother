//
//  FirestoreDTOs.swift
//  Vision_clother
//
//  Cloud Sync (docs/decisions/resolved-v1.md's "Cloud Sync" section): one
//  dedicated Codable struct per synced `@Model` type, deliberately separate
//  from the existing `*Wire` types (e.g. `UserStyleProfileWire`) — those are
//  the LLM API contract and must stay free to change independently of this
//  sync schema.
//
//  Deliberately pure domain payloads — no `updatedAt`/`isDeleted` fields here.
//  Those are sync metadata, not domain data, and are handled entirely by
//  `Services/WardrobeSyncService.swift` at the Firestore call site (merged in
//  as a raw `FieldValue.serverTimestamp()` on push, read via `.get("updatedAt")`
//  on pull) rather than round-tripped through these structs. Two reasons:
//  1. `Data/SyncMetadata.swift`'s outbox persists a DTO snapshot locally via
//     plain `JSONEncoder`/`JSONDecoder` (see that model's doc comment) — a
//     `@ServerTimestamp`-wrapped field is written for Firestore's own Codable
//     support and isn't guaranteed to round-trip through a generic encoder.
//  2. It keeps these structs framework-agnostic (no `FirebaseFirestore`
//     import needed here at all).
//
//  Shared encoding rules applied throughout:
//  - Every `UUID` is `.uuidString` here, parsed back via `UUID(uuidString:)`.
//  - `[Slot: UUID]`/`[Slot: String]` become `[String: String]` (`Slot.rawValue`
//    keys) — a `RawRepresentable` enum key does not reliably serialize as a
//    native Firestore map.
//  - Enums without an existing raw-string field on the `@Model` are stored as
//    `.rawValue`, decoded via `Enum(rawValue:) ?? default` — mirrors
//    `UserStyleProfile.undertoneRaw` already doing this on the model itself.
//

import Foundation

struct ColorProfileDTO: Codable {
    var primaryHex: String
    var secondaryHex: String?
    var category: String
    var undertone: String?

    static func from(_ model: ColorProfile) -> ColorProfileDTO {
        ColorProfileDTO(
            primaryHex: model.primaryHex,
            secondaryHex: model.secondaryHex,
            category: model.category.rawValue,
            undertone: model.undertone?.rawValue
        )
    }

    func toModel() -> ColorProfile {
        ColorProfile(
            primaryHex: primaryHex,
            secondaryHex: secondaryHex,
            category: ColorVibe(rawValue: category) ?? .neutral,
            undertone: undertone.flatMap(Undertone.init(rawValue:))
        )
    }
}

struct WardrobeItemDTO: Codable {
    var id: String
    var slot: String
    var formalityScore: Double
    var colorProfile: ColorProfileDTO
    var pattern: String
    var seasonality: [String]
    var fabricWeight: String
    var imageAssetName: String?
    var isGhostElement: Bool
    var itemDescription: String?
    var styleTags: [String]
    var garmentSubtype: String?
    var fit: String?
    var silhouette: String?
    var material: String?
    var texture: String?

    static func from(_ model: WardrobeItem) -> WardrobeItemDTO {
        WardrobeItemDTO(
            id: model.id.uuidString,
            slot: model.slot.rawValue,
            formalityScore: model.formalityScore,
            colorProfile: ColorProfileDTO.from(model.colorProfile),
            pattern: model.pattern.rawValue,
            seasonality: model.seasonality.map(\.rawValue),
            fabricWeight: model.fabricWeight.rawValue,
            imageAssetName: model.imageAssetName,
            isGhostElement: model.isGhostElement,
            itemDescription: model.itemDescription,
            styleTags: model.styleTags,
            garmentSubtype: model.garmentSubtype,
            fit: model.fit,
            silhouette: model.silhouette,
            material: model.material,
            texture: model.texture
        )
    }

    func toModel() -> WardrobeItem? {
        guard let uuid = UUID(uuidString: id), let slotValue = Slot(rawValue: slot),
              let patternValue = GarmentPattern(rawValue: pattern),
              let fabricWeightValue = FabricWeight(rawValue: fabricWeight)
        else { return nil }

        return WardrobeItem(
            id: uuid,
            slot: slotValue,
            formalityScore: formalityScore,
            colorProfile: colorProfile.toModel(),
            pattern: patternValue,
            seasonality: seasonality.compactMap(Season.init(rawValue:)),
            fabricWeight: fabricWeightValue,
            imageAssetName: imageAssetName,
            isGhostElement: isGhostElement,
            itemDescription: itemDescription,
            styleTags: styleTags,
            garmentSubtype: garmentSubtype,
            fit: fit,
            silhouette: silhouette,
            material: material,
            texture: texture
        )
    }
}

struct OutfitFeedbackDTO: Codable {
    var id: String
    var outfitID: String
    var likedOverall: Bool
    var recordedAt: Date
    var overallSatisfaction: Int?
    var wearAgainRaw: String?
    var confidence: Int?
    var comfort: Int?
    var occasionMatch: Int?
    var styleMatch: Int?
    var colorHarmony: Int?
    var silhouette: Int?
    var weatherSuitability: Int?
    var practicality: Int?
    var favoriteItemID: String?
    var weakestItemID: String?
    var changeReasonsRaw: [String]

    static func from(_ model: OutfitFeedback) -> OutfitFeedbackDTO {
        OutfitFeedbackDTO(
            id: model.id.uuidString,
            outfitID: model.outfitID.uuidString,
            likedOverall: model.likedOverall,
            recordedAt: model.recordedAt,
            overallSatisfaction: model.overallSatisfaction,
            wearAgainRaw: model.wearAgainRaw,
            confidence: model.confidence,
            comfort: model.comfort,
            occasionMatch: model.occasionMatch,
            styleMatch: model.styleMatch,
            colorHarmony: model.colorHarmony,
            silhouette: model.silhouette,
            weatherSuitability: model.weatherSuitability,
            practicality: model.practicality,
            favoriteItemID: model.favoriteItemID?.uuidString,
            weakestItemID: model.weakestItemID?.uuidString,
            changeReasonsRaw: model.changeReasonsRaw
        )
    }

    func toModel() -> OutfitFeedback? {
        guard let uuid = UUID(uuidString: id), let outfitUUID = UUID(uuidString: outfitID) else { return nil }

        return OutfitFeedback(
            id: uuid,
            outfitID: outfitUUID,
            likedOverall: likedOverall,
            recordedAt: recordedAt,
            overallSatisfaction: overallSatisfaction,
            wearAgain: wearAgainRaw.flatMap(WearAgainAnswer.init(rawValue:)),
            confidence: confidence,
            comfort: comfort,
            occasionMatch: occasionMatch,
            styleMatch: styleMatch,
            colorHarmony: colorHarmony,
            silhouette: silhouette,
            weatherSuitability: weatherSuitability,
            practicality: practicality,
            favoriteItemID: favoriteItemID.flatMap(UUID.init(uuidString:)),
            weakestItemID: weakestItemID.flatMap(UUID.init(uuidString:)),
            changeReasons: changeReasonsRaw.compactMap(OutfitChangeReason.init(rawValue:))
        )
    }
}

struct ItemFeedbackDTO: Codable {
    var id: String
    var itemID: String
    var likedFit: Bool
    var recordedAt: Date

    static func from(_ model: ItemFeedback) -> ItemFeedbackDTO {
        ItemFeedbackDTO(id: model.id.uuidString, itemID: model.itemID.uuidString, likedFit: model.likedFit, recordedAt: model.recordedAt)
    }

    func toModel() -> ItemFeedback? {
        guard let uuid = UUID(uuidString: id), let itemUUID = UUID(uuidString: itemID) else { return nil }
        return ItemFeedback(id: uuid, itemID: itemUUID, likedFit: likedFit, recordedAt: recordedAt)
    }
}

struct PairFeedbackDTO: Codable {
    var id: String
    var itemAID: String
    var itemBID: String
    var likedTogether: Bool
    var recordedAt: Date

    static func from(_ model: PairFeedback) -> PairFeedbackDTO {
        PairFeedbackDTO(
            id: model.id.uuidString,
            itemAID: model.itemAID.uuidString,
            itemBID: model.itemBID.uuidString,
            likedTogether: model.likedTogether,
            recordedAt: model.recordedAt
        )
    }

    func toModel() -> PairFeedback? {
        guard let uuid = UUID(uuidString: id), let aUUID = UUID(uuidString: itemAID), let bUUID = UUID(uuidString: itemBID) else { return nil }
        return PairFeedback(id: uuid, itemAID: aUUID, itemBID: bUUID, likedTogether: likedTogether, recordedAt: recordedAt)
    }
}

struct ItemRatingDTO: Codable {
    var id: String
    var itemID: String
    var fitRaw: Int
    var comfort: Int
    var colorLike: Int
    var patternLike: Int?
    var formalityFit: Int
    var styleIdentity: Int
    var wearAgain: Bool
    var recordedAt: Date

    static func from(_ model: ItemRating) -> ItemRatingDTO {
        ItemRatingDTO(
            id: model.id.uuidString,
            itemID: model.itemID.uuidString,
            fitRaw: model.fitRaw,
            comfort: model.comfort,
            colorLike: model.colorLike,
            patternLike: model.patternLike,
            formalityFit: model.formalityFit,
            styleIdentity: model.styleIdentity,
            wearAgain: model.wearAgain,
            recordedAt: model.recordedAt
        )
    }

    func toModel() -> ItemRating? {
        guard let uuid = UUID(uuidString: id), let itemUUID = UUID(uuidString: itemID),
              let fit = FitRating(rawValue: fitRaw)
        else { return nil }

        return ItemRating(
            id: uuid,
            itemID: itemUUID,
            fit: fit,
            comfort: comfort,
            colorLike: colorLike,
            patternLike: patternLike,
            formalityFit: formalityFit,
            styleIdentity: styleIdentity,
            wearAgain: wearAgain,
            recordedAt: recordedAt
        )
    }
}

struct SavedCombinationDTO: Codable {
    var id: String
    var imageAssetName: String
    /// `Slot.rawValue` -> item id string — see the file-level note on why a
    /// `[Slot: UUID]` dictionary can't be encoded directly.
    var itemIDsBySlot: [String: String]
    var labelsBySlot: [String: String]
    var savedAt: Date
    var origin: String
    var basePortraitFingerprint: String?
    var supplementaryAccessoryItemIDs: [String]
    var supplementaryAccessoryLabels: [String]

    static func from(_ model: SavedCombination) -> SavedCombinationDTO {
        SavedCombinationDTO(
            id: model.id.uuidString,
            imageAssetName: model.imageAssetName,
            itemIDsBySlot: Dictionary(uniqueKeysWithValues: model.itemIDsBySlot.map { ($0.key.rawValue, $0.value.uuidString) }),
            labelsBySlot: Dictionary(uniqueKeysWithValues: model.labelsBySlot.map { ($0.key.rawValue, $0.value) }),
            savedAt: model.savedAt,
            origin: model.origin,
            basePortraitFingerprint: model.basePortraitFingerprint,
            supplementaryAccessoryItemIDs: model.supplementaryAccessoryItemIDs.map(\.uuidString),
            supplementaryAccessoryLabels: model.supplementaryAccessoryLabels
        )
    }

    func toModel() -> SavedCombination? {
        guard let uuid = UUID(uuidString: id) else { return nil }

        var items: [Slot: UUID] = [:]
        for (slotRaw, idString) in itemIDsBySlot {
            guard let slot = Slot(rawValue: slotRaw), let itemUUID = UUID(uuidString: idString) else { continue }
            items[slot] = itemUUID
        }
        var labels: [Slot: String] = [:]
        for (slotRaw, label) in labelsBySlot {
            guard let slot = Slot(rawValue: slotRaw) else { continue }
            labels[slot] = label
        }

        return SavedCombination(
            id: uuid,
            imageAssetName: imageAssetName,
            itemIDsBySlot: items,
            labelsBySlot: labels,
            savedAt: savedAt,
            origin: origin,
            basePortraitFingerprint: basePortraitFingerprint,
            supplementaryAccessoryItemIDs: supplementaryAccessoryItemIDs.compactMap(UUID.init(uuidString:)),
            supplementaryAccessoryLabels: supplementaryAccessoryLabels
        )
    }
}

/// Single-row upsert (fixed doc `users/{uid}/meta/styleProfile`) — mirrors
/// `UserStyleProfile`'s "one row, replaced not deleted" posture
/// (`Data/WardrobeRepository.swift`'s `saveUserProfile`).
struct UserStyleProfileDTO: Codable {
    var id: String
    var skinTone: String
    var undertoneRaw: String
    var bodyType: String
    var styleKeywords: [String]
    var recommendedColors: [String]
    var avoidColors: [String]
    var derivedAt: Date

    static func from(_ model: UserStyleProfile) -> UserStyleProfileDTO {
        UserStyleProfileDTO(
            id: model.id.uuidString,
            skinTone: model.skinTone,
            undertoneRaw: model.undertoneRaw,
            bodyType: model.bodyType,
            styleKeywords: model.styleKeywords,
            recommendedColors: model.recommendedColors,
            avoidColors: model.avoidColors,
            derivedAt: model.derivedAt
        )
    }

    func toModel() -> UserStyleProfile? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return UserStyleProfile(
            id: uuid,
            skinTone: skinTone,
            undertone: Undertone(rawValue: undertoneRaw) ?? .neutral,
            bodyType: bodyType,
            styleKeywords: styleKeywords,
            recommendedColors: recommendedColors,
            avoidColors: avoidColors,
            derivedAt: derivedAt
        )
    }
}

struct SwipeEventDTO: Codable {
    var id: String
    var sourcePhotoID: String
    var imageURLString: String
    var liked: Bool
    var embedding: [Float]
    var recordedAt: Date

    static func from(_ model: SwipeEvent) -> SwipeEventDTO {
        SwipeEventDTO(
            id: model.id.uuidString,
            sourcePhotoID: model.sourcePhotoID,
            imageURLString: model.imageURLString,
            liked: model.liked,
            embedding: model.embedding,
            recordedAt: model.recordedAt
        )
    }

    func toModel() -> SwipeEvent? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return SwipeEvent(
            id: uuid,
            sourcePhotoID: sourcePhotoID,
            imageURLString: imageURLString,
            liked: liked,
            embedding: embedding,
            recordedAt: recordedAt
        )
    }
}

struct VisualCentroidDTO: Codable {
    var vector: [Float]
    var weight: Double

    static func from(_ model: VisualCentroid) -> VisualCentroidDTO {
        VisualCentroidDTO(vector: model.vector, weight: model.weight)
    }

    func toModel() -> VisualCentroid {
        VisualCentroid(vector: vector, weight: weight)
    }
}

/// Single-row upsert (fixed doc `users/{uid}/meta/visualPreferenceState`) —
/// same posture as `UserStyleProfileDTO`. `stateUpdatedAt` is the model's own
/// domain `updatedAt` field (last centroid nudge) — named differently here so
/// it isn't confused with this doc's separate sync-level `updatedAt`
/// (server timestamp, merged in by `Services/WardrobeSyncService.swift`, not
/// a field on this struct).
struct VisualPreferenceStateDTO: Codable {
    var id: String
    var likedCentroids: [VisualCentroidDTO]
    var dislikedCentroids: [VisualCentroidDTO]
    var embeddingDimension: Int
    var stateUpdatedAt: Date
    var totalSwipes: Int

    static func from(_ model: VisualPreferenceState) -> VisualPreferenceStateDTO {
        VisualPreferenceStateDTO(
            id: model.id.uuidString,
            likedCentroids: model.likedCentroids.map(VisualCentroidDTO.from),
            dislikedCentroids: model.dislikedCentroids.map(VisualCentroidDTO.from),
            embeddingDimension: model.embeddingDimension,
            stateUpdatedAt: model.updatedAt,
            totalSwipes: model.totalSwipes
        )
    }

    func toModel() -> VisualPreferenceState? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return VisualPreferenceState(
            id: uuid,
            likedCentroids: likedCentroids.map { $0.toModel() },
            dislikedCentroids: dislikedCentroids.map { $0.toModel() },
            embeddingDimension: embeddingDimension,
            updatedAt: stateUpdatedAt,
            totalSwipes: totalSwipes
        )
    }
}

/// Bookkeeping-only doc (`users/{uid}/meta/syncStatus`) — no `@Model`
/// counterpart. `hasCompletedInitialSync` gates the bootstrap-vs-steady-state
/// split (`Data/WardrobeSyncCoordinator.swift`). Unlike every other
/// timestamp in this sync layer, `lastPulledAt` is deliberately a *client*
/// clock value (`queryStartTime`, captured before that pull's queries ran,
/// minus a small safety buffer) — not a server timestamp. It's a watermark
/// compared against other documents' server-authoritative `updatedAt`
/// values; resolving it via `FieldValue.serverTimestamp()` written *after*
/// the pull completes would itself race a concurrent write landing in the
/// gap between "queries ran" and "watermark resolved," which could then be
/// permanently skipped by every later delta pull. See
/// `Data/WardrobeSyncCoordinator.swift` for the exact buffer logic.
struct SyncStatusDTO: Codable {
    var hasCompletedInitialSync: Bool
    var lastPulledAt: Date?
}
