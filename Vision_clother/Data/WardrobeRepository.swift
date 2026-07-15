//
//  WardrobeRepository.swift
//  Vision_clother
//
//  Persistence boundary (CLAUDE.md guardrail #3: SwiftData). Everything
//  above this layer (Domain/, Features/) talks to the protocol only, so the
//  storage technology could change without touching scoring or UI code.
//

import Foundation
import SwiftData

/// One detailed "Rate this outfit" submission (Stylist Intelligence Engine
/// Phase 1) — bundled into a struct rather than a long parameter list since
/// every field is required together (the flow submits all of Level 1 + 2 +
/// the favorite/weakest picker in one screen-sequence step).
struct OutfitRatingSubmission {
    var overallSatisfaction: Int
    var wearAgain: WearAgainAnswer
    var confidence: Int
    var comfort: Int
    var occasionMatch: Int
    var styleMatch: Int
    var colorHarmony: Int
    var silhouette: Int
    var weatherSuitability: Int
    var practicality: Int
    var favoriteItemID: UUID?
    var weakestItemID: UUID?
}

@MainActor
protocol WardrobeRepository {
    func fetchInventory() throws -> [WardrobeItem]
    func save(_ item: WardrobeItem) throws
    /// Persists in-place edits to an already-saved item (edit-after-save,
    /// `Features/Closet/EditItemView.swift`) — explicit `save()` on the
    /// context, no `insert`, since the item is already tracked.
    func update(_ item: WardrobeItem) throws
    func delete(_ item: WardrobeItem) throws

    /// Aggregates all persisted feedback into the shape the deterministic
    /// scoring engine expects (`Domain/OutfitRecommendationEngine.swift`).
    func fetchFeedbackHistory() async throws -> FeedbackHistory

    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws

    /// Item Rating & Preference Learning: persists one multi-question rating
    /// (`Models/ItemRating.swift`) from `Features/Rating/RateItemView.swift`.
    /// `versatility`/`frequency`/`styleIdentity`/`qualityPerception` are the
    /// Level 2 Fashion Evaluation questions (Stylist Intelligence Engine
    /// Phase 1 addendum, item granularity).
    func recordItemRating(
        itemID: UUID,
        fit: FitRating,
        comfort: Int,
        confidence: Int,
        wearAgain: Bool,
        versatility: Int,
        frequency: Int,
        styleIdentity: Int,
        qualityPerception: Int
    ) throws
    /// All ratings for one item, newest first — backs the "already rated"
    /// state on `ItemDetailView`.
    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating]

    /// Combination Rating: persists one detailed dimension-based rating for
    /// a whole saved outfit (`Features/Rating/RateCombinationView.swift`,
    /// Stylist Intelligence Engine Phase 1). `outfitID` must be a
    /// `SavedCombination.id`. Distinct from `recordOutfitFeedback` above,
    /// which stays the simple auto-recorded "liked" write with no detailed
    /// fields.
    func recordOutfitRating(outfitID: UUID, submission: OutfitRatingSubmission) throws
    /// All feedback/ratings for one saved combination, newest first — backs
    /// the "already rated" state on `CombinationDetailView`.
    func fetchOutfitFeedback(for outfitID: UUID) throws -> [OutfitFeedback]

    /// Saved try-on images from "Save this outfit?" (Manual Pairing / Daily
    /// Assistant), newest first — backs the Combinations tab.
    func fetchSavedCombinations() throws -> [SavedCombination]
    func saveCombination(_ combination: SavedCombination) throws
    func deleteCombination(_ combination: SavedCombination) throws

    /// User Style Profile (PRD §3.8) — single row, `nil` if never derived.
    /// Read by the recommendation call to personalize picks
    /// (Services/OutfitRecommendationService.swift).
    func fetchUserProfile() throws -> UserStyleProfile?
    /// Upserts the single profile row from a fresh derivation
    /// (Services/UserProfileDerivationService.swift) — replaces any existing
    /// row rather than accumulating history, mirroring
    /// Services/UserPortraitStorage.swift's "one portrait" posture.
    func saveUserProfile(_ wire: UserStyleProfileWire) throws

    /// Swipe-to-Learn Visual Taste (`Features/SwipeDiscovery/`): records one
    /// like/dislike swipe and folds its embedding into the persisted
    /// `VisualPreferenceState` centroids in the same call — the "hot" path a
    /// swipe gesture triggers on every card. See `Domain/VisualPreferenceProfile.swift`.
    func recordSwipe(sourcePhotoID: String, imageURLString: String, liked: Bool, embedding: [Float]) throws
    /// Current learned visual-taste state, `nil` before the first swipe.
    func fetchVisualPreferenceState() throws -> VisualPreferenceState?
    /// Direct upsert of the visual-taste centroids — used by
    /// `Domain/VisualPreferenceProfile.build(from:dislikedEmbeddings:)`'s
    /// recovery path (rebuilding from `SwipeEvent` history) rather than
    /// replaying swipes one at a time through `recordSwipe`.
    func updateVisualPreferenceState(
        likedCentroids: [VisualCentroid],
        dislikedCentroids: [VisualCentroid],
        embeddingDimension: Int
    ) throws
    /// Cached embedding for one wardrobe item's current photo, `nil` if never
    /// computed (or the item has no photo). `fetchFeedbackHistory()` is the
    /// only caller that needs this in bulk; exposed individually for tests
    /// and recovery tooling.
    func fetchWardrobeItemEmbedding(itemID: UUID) throws -> WardrobeItemEmbedding?
    /// Upserts one item's cached embedding, keyed by `itemID`.
    func saveWardrobeItemEmbedding(itemID: UUID, vector: [Float], sourceFingerprint: String) throws
}

@MainActor
final class SwiftDataWardrobeRepository: WardrobeRepository {
    private let modelContext: ModelContext
    /// On-device Vision embedding extractor (`Services/ImageEmbeddingService.swift`)
    /// — defaulted to the real implementation so every pre-existing call site
    /// (`SwiftDataWardrobeRepository(modelContext:)`) keeps compiling
    /// unchanged; tests inject `MockImageEmbeddingService`.
    private let embeddingService: ImageEmbeddingService

    init(modelContext: ModelContext, embeddingService: ImageEmbeddingService = VisionFeaturePrintEmbeddingService()) {
        self.modelContext = modelContext
        self.embeddingService = embeddingService
    }

    func fetchInventory() throws -> [WardrobeItem] {
        try modelContext.fetch(FetchDescriptor<WardrobeItem>())
    }

    func save(_ item: WardrobeItem) throws {
        modelContext.insert(item)
        try modelContext.save()
    }

    func update(_ item: WardrobeItem) throws {
        try modelContext.save()
    }

    func delete(_ item: WardrobeItem) throws {
        // Best-effort — an orphaned file is a disk-space leak, not a
        // correctness issue worth failing the delete over.
        if let imageAssetName = item.imageAssetName {
            ImageStorage.delete(imageAssetName)
        }
        modelContext.delete(item)
        try modelContext.save()
    }

    func fetchFeedbackHistory() async throws -> FeedbackHistory {
        let now = Date.now
        let cutoffDate = now.addingTimeInterval(-180 * 24 * 60 * 60)
        let pairFeedbacks = try modelContext.fetch(FetchDescriptor<PairFeedback>(
            predicate: #Predicate { $0.recordedAt >= cutoffDate }
        ))
        let itemFeedbacks = try modelContext.fetch(FetchDescriptor<ItemFeedback>(
            predicate: #Predicate { $0.recordedAt >= cutoffDate }
        ))
        let itemRatings = try modelContext.fetch(FetchDescriptor<ItemRating>(
            predicate: #Predicate { $0.recordedAt >= cutoffDate }
        ))
        let outfitFeedbacks = try modelContext.fetch(FetchDescriptor<OutfitFeedback>(
            predicate: #Predicate { $0.recordedAt >= cutoffDate }
        ))

        var history = FeedbackHistory()

        for feedback in pairFeedbacks {
            let weight = AttributePreferenceProfile.decayWeight(recordedAt: feedback.recordedAt, now: now)
            let key = PairKey(feedback.itemAID, feedback.itemBID)
            var entry = history.pairFeedback[key] ?? (likes: 0, total: 0)
            entry.total += weight
            if feedback.likedTogether { entry.likes += weight }
            history.pairFeedback[key] = entry
        }

        for feedback in itemFeedbacks {
            // Time-decayed, shared between the `itemFeedback` preference
            // tally below and the `itemNegativeSignal` penalty channel.
            let weight = AttributePreferenceProfile.decayWeight(recordedAt: feedback.recordedAt, now: now)

            var entry = history.itemFeedback[feedback.itemID] ?? (likes: 0, total: 0)
            entry.total += weight
            if feedback.likedFit { entry.likes += weight }
            history.itemFeedback[feedback.itemID] = entry

            // Read Disliked Signals: a time-decayed net-negativity tally,
            // separate from the `itemFeedback` tally above — feeds
            // `OutfitRecommendationEngine.outfitScore`'s negative-feedback
            // penalty (previously this history was collected but never read).
            history.itemNegativeSignal[feedback.itemID, default: 0] += weight * (feedback.likedFit ? -1 : 1)
        }

        // Item Rating & Preference Learning: fold each rich `ItemRating`
        // into the same binary item-preference channel the existing scoring
        // already reads (`ItemFeedback.likedFit`'s aggregate), via the
        // rating's own >=0.6 "liked" threshold — so item preference improves
        // immediately with no change to `PairCompatibilityScoring.itemPreference`.
        for rating in itemRatings {
            let weight = AttributePreferenceProfile.decayWeight(recordedAt: rating.recordedAt, now: now)

            var entry = history.itemFeedback[rating.itemID] ?? (likes: 0, total: 0)
            entry.total += weight
            if rating.impliesLiked { entry.likes += weight }
            history.itemFeedback[rating.itemID] = entry

            history.itemNegativeSignal[rating.itemID, default: 0] += weight * (0.5 - rating.normalizedValue) * 2
        }

        // Stylist Intelligence Engine Phase 1: Favorite/Weakest Item feeds
        // the same item preference channel directly — a favorite pick is a
        // strong like, a weakest pick a dislike — reusing
        // `PairCompatibilityScoring.itemPreference`'s existing shrinkage
        // with no new scoring math.
        for feedback in outfitFeedbacks {
            let weight = AttributePreferenceProfile.decayWeight(recordedAt: feedback.recordedAt, now: now)
            if let favoriteItemID = feedback.favoriteItemID {
                var entry = history.itemFeedback[favoriteItemID] ?? (likes: 0, total: 0)
                entry.total += weight
                entry.likes += weight
                history.itemFeedback[favoriteItemID] = entry
                history.itemNegativeSignal[favoriteItemID, default: 0] += weight * -1
            }
            if let weakestItemID = feedback.weakestItemID {
                var entry = history.itemFeedback[weakestItemID] ?? (likes: 0, total: 0)
                entry.total += weight
                history.itemFeedback[weakestItemID] = entry
                history.itemNegativeSignal[weakestItemID, default: 0] += weight * 1
            }
        }

        // Read Disliked Signals (outfit level): a freshly-generated
        // `OutfitCombination` has no durable id of its own until saved, so
        // whole-outfit dislike history can only be looked up by which items
        // it actually contains — join every `OutfitFeedback` back to the
        // `SavedCombination` it rated and key the resulting time-decayed
        // net-negativity by that outfit's full item-id set.
        if !outfitFeedbacks.isEmpty {
            let savedCombinations = try modelContext.fetch(FetchDescriptor<SavedCombination>())
            let combinationsByID = Dictionary(uniqueKeysWithValues: savedCombinations.map { ($0.id, $0) })

            for feedback in outfitFeedbacks {
                guard let combination = combinationsByID[feedback.outfitID] else { continue }
                let itemSet = Set(combination.itemIDsBySlot.values)
                guard !itemSet.isEmpty else { continue }

                let weight = AttributePreferenceProfile.decayWeight(recordedAt: feedback.recordedAt, now: now)
                // Prefer the richer `normalizedRating` (continuous [0,1])
                // when the detailed "Rate this outfit" flow recorded one;
                // fall back to the binary `likedOverall` from the simple
                // auto-recorded save-time event. Positive = net dislike.
                let signedSignal: Double
                if let normalizedRating = feedback.normalizedRating {
                    signedSignal = (0.5 - normalizedRating) * 2
                } else {
                    signedSignal = feedback.likedOverall ? -1 : 1
                }
                history.outfitNegativeSignalByItemSet[itemSet, default: 0] += weight * signedSignal
            }
        }

        // Build the learned taste profile: `ItemRating` contributes
        // color/pattern/formality (blended across its own question set);
        // detailed `OutfitFeedback` rows contribute per-dimension —
        // Color Harmony/Occasion Match add to the same color/formality
        // affinities, Personal Style Match/Fit & Silhouette/Weather
        // Suitability+Practicality seed the three Phase 1 dimensions. Rows
        // referencing items no longer in the inventory (deleted since) are
        // skipped — there's no attribute to learn from.
        let detailedOutfitFeedbacks = outfitFeedbacks.filter { $0.normalizedRating != nil }
        if !itemRatings.isEmpty || !detailedOutfitFeedbacks.isEmpty {
            let inventory = try modelContext.fetch(FetchDescriptor<WardrobeItem>())
            let itemsByID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })

            let ratedAttributes: [RatedAttributes] = itemRatings.compactMap { (rating: ItemRating) -> RatedAttributes? in
                guard let item = itemsByID[rating.itemID] else { return nil }
                return RatedAttributes(
                    value: rating.normalizedValue,
                    colorVibe: item.colorProfile.category,
                    pattern: item.pattern,
                    formalityBand: Int(item.formalityScore.rounded()),
                    styleIdentity: rating.styleIdentity.map { Double($0 - 1) / 4.0 } ?? 0.5,
                    styleTags: item.styleTags,
                    recordedAt: rating.recordedAt,
                    slot: item.slot
                )
            }

            let savedCombinations = try modelContext.fetch(FetchDescriptor<SavedCombination>())
            let combinationsByID = Dictionary(uniqueKeysWithValues: savedCombinations.map { ($0.id, $0) })
            let outfitDimensionRatings: [OutfitDimensionRatedAttributes] = detailedOutfitFeedbacks.flatMap { feedback -> [OutfitDimensionRatedAttributes] in
                guard let combination = combinationsByID[feedback.outfitID],
                      let colorHarmony = feedback.colorHarmony,
                      let occasionMatch = feedback.occasionMatch,
                      let styleMatch = feedback.styleMatch,
                      let silhouette = feedback.silhouette,
                      let weatherSuitability = feedback.weatherSuitability,
                      let practicality = feedback.practicality
                else { return [] }

                let items = combination.itemIDsBySlot.values.compactMap { itemsByID[$0] }

                let colorHarmonyNorm = Double(colorHarmony - 1) / 4.0
                let occasionMatchNorm = Double(occasionMatch - 1) / 4.0
                let styleMatchNorm = Double(styleMatch - 1) / 4.0
                let silhouetteNorm = Double(silhouette - 1) / 4.0
                let weatherFitNorm = (Double(weatherSuitability - 1) / 4.0 + Double(practicality - 1) / 4.0) / 2.0

                return items.map { item in
                    OutfitDimensionRatedAttributes(
                        colorHarmony: colorHarmonyNorm,
                        occasionMatch: occasionMatchNorm,
                        styleMatch: styleMatchNorm,
                        silhouette: silhouetteNorm,
                        weatherFit: weatherFitNorm,
                        colorVibe: item.colorProfile.category,
                        styleTags: item.styleTags,
                        silhouetteTag: item.silhouette,
                        formalityBand: Int(item.formalityScore.rounded()),
                        fabricWeight: item.fabricWeight,
                        recordedAt: feedback.recordedAt,
                        slot: item.slot
                    )
                }
            }

            let inventorySnapshots = inventory.map { item in
                ItemAttributeSnapshot(
                    colorCategory: item.colorProfile.category,
                    pattern: item.pattern,
                    formalityBand: Int(item.formalityScore.rounded()),
                    styleTags: item.styleTags,
                    silhouette: item.silhouette,
                    fabricWeight: item.fabricWeight,
                    slot: item.slot
                )
            }

            let attributeProfile = await Task.detached(priority: .userInitiated) {
                AttributePreferenceProfile.build(
                    from: ratedAttributes,
                    outfitDimensionRatings: outfitDimensionRatings,
                    inventorySnapshots: inventorySnapshots,
                    now: now
                )
            }.value

            history.attributeProfile = attributeProfile
        }

        // Swipe-to-Learn Visual Taste: read the persisted centroid state and
        // lazily compute/cache per-item embeddings for every real (non-ghost)
        // inventory item that has a photo — powers both
        // Domain/OutfitRecommendationEngine.swift's re-rank term and
        // Domain/WardrobeCatalogBuilder.swift's truncation ranking. Runs
        // unconditionally (unlike the attribute-profile block above), since
        // an item can have a photo with zero ratings.
        if let visualState = try modelContext.fetch(FetchDescriptor<VisualPreferenceState>()).first {
            history.visualProfile = VisualPreferenceProfile(
                likedCentroids: visualState.likedCentroids,
                dislikedCentroids: visualState.dislikedCentroids
            )
        }

        let embeddableInventory = try modelContext.fetch(FetchDescriptor<WardrobeItem>())
        let cachedEmbeddings = try modelContext.fetch(FetchDescriptor<WardrobeItemEmbedding>())
        let embeddingsByItemID = Dictionary(uniqueKeysWithValues: cachedEmbeddings.map { ($0.itemID, $0) })

        for item in embeddableInventory {
            guard !item.isGhostElement, let assetName = item.imageAssetName,
                  let imageData = ImageStorage.loadData(for: assetName)
            else { continue }
            let fingerprint = ImageStorage.fingerprint(imageData)

            if let cached = embeddingsByItemID[item.id], cached.sourceFingerprint == fingerprint {
                history.itemEmbeddings[item.id] = cached.vector
                continue
            }

            // Best-effort — a Vision failure on one item's photo shouldn't
            // fail the whole feedback-history fetch (same posture as the
            // best-effort file cleanup elsewhere in this class).
            guard let vector = try? await embeddingService.embedding(for: imageData) else { continue }
            try? saveWardrobeItemEmbedding(itemID: item.id, vector: vector, sourceFingerprint: fingerprint)
            history.itemEmbeddings[item.id] = vector
        }

        return history
    }

    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {
        modelContext.insert(OutfitFeedback(outfitID: outfitID, likedOverall: likedOverall))
        try modelContext.save()
    }

    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {
        modelContext.insert(ItemFeedback(itemID: itemID, likedFit: likedFit))
        try modelContext.save()
    }

    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {
        modelContext.insert(PairFeedback(itemAID: itemAID, itemBID: itemBID, likedTogether: likedTogether))
        try modelContext.save()
    }

    func recordItemRating(
        itemID: UUID,
        fit: FitRating,
        comfort: Int,
        confidence: Int,
        wearAgain: Bool,
        versatility: Int,
        frequency: Int,
        styleIdentity: Int,
        qualityPerception: Int
    ) throws {
        modelContext.insert(ItemRating(
            itemID: itemID,
            fit: fit,
            comfort: comfort,
            confidence: confidence,
            wearAgain: wearAgain,
            versatility: versatility,
            frequency: frequency,
            styleIdentity: styleIdentity,
            qualityPerception: qualityPerception
        ))
        try modelContext.save()
    }

    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] {
        let descriptor = FetchDescriptor<ItemRating>(
            predicate: #Predicate { $0.itemID == itemID },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func recordOutfitRating(outfitID: UUID, submission: OutfitRatingSubmission) throws {
        let normalizedValue = OutfitFeedback.normalizedRating(
            overallSatisfaction: submission.overallSatisfaction, wearAgain: submission.wearAgain,
            confidence: submission.confidence, comfort: submission.comfort,
            occasionMatch: submission.occasionMatch, styleMatch: submission.styleMatch,
            colorHarmony: submission.colorHarmony, silhouette: submission.silhouette,
            weatherSuitability: submission.weatherSuitability, practicality: submission.practicality
        )
        modelContext.insert(OutfitFeedback(
            outfitID: outfitID,
            likedOverall: normalizedValue >= 0.6,
            overallSatisfaction: submission.overallSatisfaction,
            wearAgain: submission.wearAgain,
            confidence: submission.confidence,
            comfort: submission.comfort,
            occasionMatch: submission.occasionMatch,
            styleMatch: submission.styleMatch,
            colorHarmony: submission.colorHarmony,
            silhouette: submission.silhouette,
            weatherSuitability: submission.weatherSuitability,
            practicality: submission.practicality,
            favoriteItemID: submission.favoriteItemID,
            weakestItemID: submission.weakestItemID
        ))
        try modelContext.save()
    }

    func fetchOutfitFeedback(for outfitID: UUID) throws -> [OutfitFeedback] {
        let descriptor = FetchDescriptor<OutfitFeedback>(
            predicate: #Predicate { $0.outfitID == outfitID },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func fetchSavedCombinations() throws -> [SavedCombination] {
        let descriptor = FetchDescriptor<SavedCombination>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)])
        return try modelContext.fetch(descriptor)
    }

    func saveCombination(_ combination: SavedCombination) throws {
        modelContext.insert(combination)
        try modelContext.save()
    }

    func deleteCombination(_ combination: SavedCombination) throws {
        // Best-effort — an orphaned file is a disk-space leak, not a
        // correctness issue worth failing the delete over.
        ImageStorage.delete(combination.imageAssetName)
        modelContext.delete(combination)
        try modelContext.save()
    }

    func fetchUserProfile() throws -> UserStyleProfile? {
        try modelContext.fetch(FetchDescriptor<UserStyleProfile>()).first
    }

    func saveUserProfile(_ wire: UserStyleProfileWire) throws {
        // Single-row upsert: delete any prior profile(s) before inserting
        // the fresh one, so a re-derivation never accumulates history.
        for existing in try modelContext.fetch(FetchDescriptor<UserStyleProfile>()) {
            modelContext.delete(existing)
        }
        modelContext.insert(UserStyleProfile(
            skinTone: wire.skinTone,
            undertone: wire.undertone,
            bodyType: wire.bodyType,
            styleKeywords: wire.styleKeywords,
            recommendedColors: wire.recommendedColors,
            avoidColors: wire.avoidColors
        ))
        try modelContext.save()
    }

    func recordSwipe(sourcePhotoID: String, imageURLString: String, liked: Bool, embedding: [Float]) throws {
        modelContext.insert(SwipeEvent(
            sourcePhotoID: sourcePhotoID,
            imageURLString: imageURLString,
            liked: liked,
            embedding: embedding
        ))

        let existing = try modelContext.fetch(FetchDescriptor<VisualPreferenceState>()).first
        let state = existing ?? VisualPreferenceState()
        if existing == nil {
            modelContext.insert(state)
        }

        // Mutate local copies, then reassign — `VisualClusterUpdater.update`
        // takes `inout`, which a `@Model`-backed stored property can't be
        // passed as directly.
        var likedCentroids = state.likedCentroids
        var dislikedCentroids = state.dislikedCentroids
        if liked {
            VisualClusterUpdater.update(&likedCentroids, with: embedding)
        } else {
            VisualClusterUpdater.update(&dislikedCentroids, with: embedding)
        }
        state.likedCentroids = likedCentroids
        state.dislikedCentroids = dislikedCentroids
        state.embeddingDimension = embedding.count
        state.updatedAt = .now

        try modelContext.save()
    }

    func fetchVisualPreferenceState() throws -> VisualPreferenceState? {
        try modelContext.fetch(FetchDescriptor<VisualPreferenceState>()).first
    }

    func updateVisualPreferenceState(
        likedCentroids: [VisualCentroid],
        dislikedCentroids: [VisualCentroid],
        embeddingDimension: Int
    ) throws {
        let existing = try modelContext.fetch(FetchDescriptor<VisualPreferenceState>()).first
        let state = existing ?? VisualPreferenceState()
        if existing == nil {
            modelContext.insert(state)
        }
        state.likedCentroids = likedCentroids
        state.dislikedCentroids = dislikedCentroids
        state.embeddingDimension = embeddingDimension
        state.updatedAt = .now
        try modelContext.save()
    }

    func fetchWardrobeItemEmbedding(itemID: UUID) throws -> WardrobeItemEmbedding? {
        let descriptor = FetchDescriptor<WardrobeItemEmbedding>(
            predicate: #Predicate { $0.itemID == itemID }
        )
        return try modelContext.fetch(descriptor).first
    }

    func saveWardrobeItemEmbedding(itemID: UUID, vector: [Float], sourceFingerprint: String) throws {
        if let existing = try fetchWardrobeItemEmbedding(itemID: itemID) {
            existing.vector = vector
            existing.sourceFingerprint = sourceFingerprint
            existing.computedAt = .now
        } else {
            modelContext.insert(WardrobeItemEmbedding(
                itemID: itemID,
                vector: vector,
                sourceFingerprint: sourceFingerprint
            ))
        }
        try modelContext.save()
    }
}
