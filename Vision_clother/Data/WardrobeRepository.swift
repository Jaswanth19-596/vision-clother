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
import os

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
    /// "What would you change?" checklist (Level 3, Stylist Intelligence
    /// Engine ADR) — empty when nothing was flagged.
    var changeReasons: Set<OutfitChangeReason> = []
    /// Analytics & Insights, Phase 3 — Better Feedback Collection. All
    /// optional/defaulted, same "don't force it" posture as `changeReasons`.
    var likeReasons: Set<OutfitLikeReason> = []
    var occasion: OutfitOccasion?
    var wouldBuySimilar: Bool?
    var savedForInspiration: Bool = false
    var replacementSuggestion: ReplacementSuggestion?
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
    /// (`Models/ItemRating.swift`) from `Features/Rating/RateItemView.swift`
    /// — Fit, Comfort, Color, Pattern (`nil` for solid-pattern items), Formality
    /// Fit, Style Identity, Wear Again — and, via `applyImplicitSwipe`, folds
    /// the rating's derived liked/disliked signal into the same Swipe-to-Learn
    /// visual centroids `recordSwipe` maintains (an implicit swipe).
    func recordItemRating(
        itemID: UUID,
        fit: FitRating,
        comfort: Int,
        colorLike: Int,
        patternLike: Int?,
        formalityFit: Int,
        styleIdentity: Int,
        wearAgain: Bool
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
    /// Never inserts a duplicate row for an outfit that's already saved —
    /// "duplicate" means the exact same set of items (every populated slot
    /// plus supplementary accessories), regardless of which flow saved it or
    /// what image it was rendered against. Returns the durable id to use
    /// going forward: `combination.id` for a genuinely new item-set, or the
    /// existing row's id when one already matches (in which case, if that
    /// existing row has no render yet but `combination` does, its image is
    /// upgraded in place via `updateCombinationImage` — see that method).
    /// Callers that reference `combination.id` afterward (recording
    /// feedback, logging a wear) must use this return value instead, since
    /// a dedup match means `combination` itself was never persisted.
    @discardableResult
    func saveCombination(_ combination: SavedCombination) throws -> UUID
    func deleteCombination(_ combination: SavedCombination) throws
    /// Replaces a placeholder-rendered combination's image in place (Anti-
    /// Repetition's "Generate Image" follow-up to a text-only "Wearing This
    /// Today") — never creates a second `SavedCombination` row. No-ops if
    /// `id` doesn't match an existing row.
    func updateCombinationImage(id: UUID, assetName: String) throws

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
    /// Returns the centroid drift percentage from `VisualClusterUpdater.update`
    /// (`nil` when this swipe seeded a fresh centroid rather than nudging an
    /// existing one — there's no prior vector to diff against) so the caller
    /// can surface real, per-swipe learning feedback instead of inferring it
    /// from a swipe count.
    @discardableResult
    func recordSwipe(sourcePhotoID: String, imageURLString: String, liked: Bool, embedding: [Float]) throws -> Double?
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

    /// Impression/Selection Event Capture: inserts one `RecommendationImpressionEvent`
    /// per candidate outfit shown in a round, rank = position in `outfits`
    /// (0 = strongest). Best-effort at the call site (`try?`) — a logging/audit
    /// trail, never a gate on the recommendation flow.
    func recordImpressions(roundID: UUID, outfits: [OutfitCombination]) throws
    /// Marks the impression matching `outfitID` (the `OutfitCombination.id`
    /// the user acted on, e.g. via `startTryOn`) as selected. No-ops if no
    /// matching impression row exists.
    func recordSelection(outfitID: UUID) throws

    // MARK: - Analytics & Insights (Phase 2)

    /// Every locally-known snapshot, most recent period first —
    /// `Domain/AnalyticsAggregator.swift` (later phase) reads this for
    /// cross-device first-paint before its own on-device recompute lands.
    func fetchAnalyticsSnapshots() throws -> [AnalyticsSnapshot]
    /// Upserts by `periodKey` — one row per computed period, never a
    /// duplicate for an already-computed one.
    func upsertAnalyticsSnapshot(periodKey: String, payloadJSON: String) throws
    /// Internal-only Recommendation Analytics rollup — see
    /// `Models/RecommendationAnalyticsSnapshot.swift`.
    func fetchRecommendationAnalyticsSnapshots() throws -> [RecommendationAnalyticsSnapshot]
    func upsertRecommendationAnalyticsSnapshot(periodKey: String, shownCount: Int, selectedCount: Int) throws

    /// The "Wore this" quick action — see `Models/WornLogEntry.swift`.
    func fetchWornLogEntries() throws -> [WornLogEntry]
    /// Bounded to `wornAt >= cutoff` — feeds Anti-Repetition's rotation
    /// novelty window (`Domain/RecentOutfitHistoryBuilder.swift`), which
    /// only ever needs the last `FashionKnowledgeConstants.Rotation.softPenalizeWindowDays`,
    /// never full history the way `fetchWornLogEntries()` above does.
    func fetchWornLogEntries(since cutoff: Date) throws -> [WornLogEntry]
    func logWorn(savedCombinationID: UUID, itemIDs: [UUID]) throws
    /// Anti-Repetition, Action A ("Wearing This Today" from the text
    /// recommendation card, before any try-on image exists): saves `combination`
    /// and logs the wear as one call, so a `WornLogEntry` can never reference
    /// a `SavedCombination.id` that didn't durably commit first. Returns the
    /// id actually persisted — see `saveCombination`'s doc comment on
    /// deduplication; the wear is always logged against that id, never
    /// `combination.id` directly.
    @discardableResult
    func saveAndLogWorn(combination: SavedCombination, itemIDs: [UUID]) throws -> UUID

    /// Anti-Repetition — the permanent "never recommend these two together"
    /// veto (see `Models/ItemPairBan.swift`).
    func fetchPairBans() throws -> [ItemPairBan]
    /// Dedupes on write against the order-independent key — re-banning an
    /// already-banned pair is a no-op, not a duplicate row.
    func recordPairBan(itemAID: UUID, itemBID: UUID) throws
    /// No "unban" UI ships yet, but the method exists now so a future one
    /// needs no further protocol/migration change.
    func removePairBan(id: UUID) throws

    /// Wardrobe/Insights Q&A (2026-07-20): all-time `ItemRating`/`OutfitFeedback`
    /// rows, feeding `Domain/InsightsSummaryBuilder.swift` the same inputs
    /// `Features/Insights/StyleView.swift`'s `@Query`s already give the
    /// Insights tab — `DailyAssistantViewModel` has no `ModelContext`/`@Query`
    /// access, only this repository. Default implementation below returns
    /// `[]` so every existing test double compiles unchanged; only the real
    /// repositories override it.
    func fetchAllItemRatings() throws -> [ItemRating]
    /// See `fetchAllItemRatings()`'s doc comment.
    func fetchAllOutfitFeedback() throws -> [OutfitFeedback]
}

/// Default no-op fallback for the two Insights-Q&A bulk-fetch methods above
/// — keeps every pre-existing `WardrobeRepository` test double compiling
/// without needing a change for a feature they don't exercise. Only
/// `SwiftDataWardrobeRepository`/`SyncingWardrobeRepository` (the real
/// production path) override these.
extension WardrobeRepository {
    func fetchAllItemRatings() throws -> [ItemRating] { [] }
    func fetchAllOutfitFeedback() throws -> [OutfitFeedback] { [] }
}

@MainActor
final class SwiftDataWardrobeRepository: WardrobeRepository {
    private let modelContext: ModelContext
    /// Runs the on-device Vision embedding extractor
    /// (`Services/ImageEmbeddingService.swift`) off the main actor
    /// (`Services/WardrobeEmbeddingWorker.swift`) — `fetchFeedbackHistory()`
    /// is the only caller. Defaulted to the real implementation so every
    /// pre-existing call site (`SwiftDataWardrobeRepository(modelContext:)`)
    /// keeps compiling unchanged; tests inject `MockImageEmbeddingService`.
    private let embeddingWorker: WardrobeEmbeddingWorker

    /// HIGH-2 perf fix: `fetchInventory`/`fetchFeedbackHistory` used to be
    /// cached ad hoc per-caller (`DailyAssistantViewModel`'s now-removed
    /// `inventoryCache`/`feedbackHistoryCache`) — moved down here so every
    /// caller sharing one repository instance (any `SyncingWardrobeRepository`
    /// held across multiple calls, e.g. a long-lived view model) gets the
    /// fast path for free, not just the one view model that happened to
    /// implement its own cache. Invalidated the same way that cache was:
    /// comparing against `WardrobeMutationTracker.shared.version`, which every
    /// `WardrobeItem`/feedback-mutating call site in the app already bumps.
    /// Call sites that construct a fresh repository per call (`ItemDetailView`,
    /// `ClosetView`, `ProfileViewModel`) are unaffected either way — a fresh
    /// instance always starts with an empty cache, same as before this change.
    private var inventoryCache: [WardrobeItem]?
    private var cachedInventoryVersion: UUID?
    private var feedbackHistoryCache: FeedbackHistory?
    private var cachedFeedbackHistoryVersion: UUID?

    init(modelContext: ModelContext, embeddingService: ImageEmbeddingService = VisionFeaturePrintEmbeddingService()) {
        self.modelContext = modelContext
        self.embeddingWorker = WardrobeEmbeddingWorker(embeddingService: embeddingService)
    }

    func fetchInventory() throws -> [WardrobeItem] {
        let currentVersion = WardrobeMutationTracker.shared.version
        if let inventoryCache, cachedInventoryVersion == currentVersion {
            return inventoryCache
        }
        let inventory = try modelContext.fetch(FetchDescriptor<WardrobeItem>())
        self.inventoryCache = inventory
        self.cachedInventoryVersion = currentVersion
        return inventory
    }

    /// Saves and bumps `WardrobeMutationTracker`'s version in one call —
    /// every write whose model is read by `fetchInventory()`/
    /// `fetchFeedbackHistory()` above must route through this rather than a
    /// bare `modelContext.save()`, so a new mutating method can't silently
    /// omit the invalidation the way `recordItemFeedback`/`recordPairFeedback`
    /// originally did (both wrote a model `fetchFeedbackHistory()` reads
    /// without bumping the tracker, leaving it serving stale cached data).
    /// Documented exceptions that deliberately keep a bare `modelContext.save()`
    /// instead — `saveCombination`, `updateCombinationImage`,
    /// `saveWardrobeItemEmbedding`, `logWorn`, and the read-only-to-this-cache
    /// writes below (`recordImpressions`, `recordSelection`, `recordPairBan`,
    /// `removePairBan`, `saveUserProfile`, the Analytics upserts) — each carry
    /// their own doc comment explaining why. When adding a new mutating
    /// method, default to this helper unless you can point to why the model
    /// it writes is never read by either cache.
    private func saveAndMarkMutated() throws {
        try modelContext.save()
        WardrobeMutationTracker.shared.markMutated()
    }

    func save(_ item: WardrobeItem) throws {
        modelContext.insert(item)
        try saveAndMarkMutated()
    }

    func update(_ item: WardrobeItem) throws {
        try saveAndMarkMutated()
    }

    func delete(_ item: WardrobeItem) throws {
        // Best-effort — an orphaned file is a disk-space leak, not a
        // correctness issue worth failing the delete over.
        if let imageAssetName = item.imageAssetName {
            ImageStorage.delete(imageAssetName)
        }
        modelContext.delete(item)
        try saveAndMarkMutated()
    }

    func fetchFeedbackHistory() async throws -> FeedbackHistory {
        let currentVersion = WardrobeMutationTracker.shared.version
        if let feedbackHistoryCache, cachedFeedbackHistoryVersion == currentVersion {
            return feedbackHistoryCache
        }

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

        // Fetched once and reused by every block below (attribute-profile
        // join, outfit-negative-signal join, embedding pass) — previously
        // each block re-fetched its own copy of the same full table.
        let inventory = try modelContext.fetch(FetchDescriptor<WardrobeItem>())

        // `combinationsByID` is only ever looked up by `feedback.outfitID`
        // for a `feedback` drawn from `outfitFeedbacks` above (both join
        // sites below), so scope the fetch to exactly those ids instead of
        // every `SavedCombination` ever saved — bounded by the (already
        // 180-day-windowed) feedback count, not by all-time saved-combo
        // count, and still correct even when a combo saved long ago outside
        // the window was rated again just now (its id is still in
        // `outfitFeedbacks`, so it's still fetched here).
        let neededOutfitIDs = Set(outfitFeedbacks.map(\.outfitID))
        let savedCombinations: [SavedCombination]
        if neededOutfitIDs.isEmpty {
            savedCombinations = []
        } else {
            savedCombinations = try modelContext.fetch(FetchDescriptor<SavedCombination>(
                predicate: #Predicate { neededOutfitIDs.contains($0.id) }
            ))
        }
        let combinationsByID = Dictionary(uniqueKeysWithValues: savedCombinations.map { ($0.id, $0) })

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
            let itemsByID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })

            let ratedAttributes: [RatedAttributes] = itemRatings.compactMap { (rating: ItemRating) -> RatedAttributes? in
                guard let item = itemsByID[rating.itemID] else { return nil }
                return RatedAttributes(
                    colorLike: Double(rating.colorLike - 1) / 4.0,
                    patternLike: rating.patternLike.map { Double($0 - 1) / 4.0 },
                    formalityFit: Double(rating.formalityFit - 1) / 4.0,
                    colorVibe: item.colorProfile.category,
                    pattern: item.pattern,
                    formalityBand: Int(item.formalityScore.rounded()),
                    styleIdentity: Double(rating.styleIdentity - 1) / 4.0,
                    styleTags: item.styleTags,
                    recordedAt: rating.recordedAt,
                    slot: item.slot,
                    silhouetteTag: item.silhouette,
                    silhouetteFit: item.silhouette != nil ? rating.fit.centeredness : nil,
                    fabricWeight: item.fabricWeight,
                    fabricComfort: Double(rating.comfort - 1) / 4.0
                )
            }

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

                // "What would you change?" checklist (Level 3): a flagged
                // reason forces that dimension's contribution to a strongly
                // negative value regardless of the star given — a
                // deliberate signal on top of, not a replacement for, the
                // Level 2 star (docs/decisions/stylist-intelligence-engine.md).
                let reasons = feedback.changeReasons
                let strongDissatisfaction = 0.1
                let formalityFlagged = reasons.contains(.tooFormal) || reasons.contains(.tooCasual)

                let colorHarmonyNorm = reasons.contains(.wrongColor) ? min(Double(colorHarmony - 1) / 4.0, strongDissatisfaction) : Double(colorHarmony - 1) / 4.0
                let occasionMatchNorm = formalityFlagged ? min(Double(occasionMatch - 1) / 4.0, strongDissatisfaction) : Double(occasionMatch - 1) / 4.0
                let styleMatchNorm = reasons.contains(.notMyStyle) ? min(Double(styleMatch - 1) / 4.0, strongDissatisfaction) : Double(styleMatch - 1) / 4.0
                let silhouetteNorm = reasons.contains(.didntFitRight) ? min(Double(silhouette - 1) / 4.0, strongDissatisfaction) : Double(silhouette - 1) / 4.0
                let weatherFitBase = (Double(weatherSuitability - 1) / 4.0 + Double(practicality - 1) / 4.0) / 2.0
                let weatherFitNorm = reasons.contains(.wrongForWeather) ? min(weatherFitBase, strongDissatisfaction) : weatherFitBase
                let patternDissatisfaction: Double? = reasons.contains(.wrongPattern) ? strongDissatisfaction : nil

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
                        pattern: item.pattern,
                        patternDissatisfaction: patternDissatisfaction,
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

        let cachedEmbeddings = try modelContext.fetch(FetchDescriptor<WardrobeItemEmbedding>())
        let embeddingsByItemID = Dictionary(uniqueKeysWithValues: cachedEmbeddings.map { ($0.itemID, $0) })

        // Cheap, synchronous pass on the main actor: a persisted
        // `imageFingerprint` matching the cached embedding's fingerprint is
        // a pure in-memory compare — no disk I/O, no hashing. Only items
        // that can't be resolved this way (a pre-existing row saved before
        // `imageFingerprint` existed, or a genuine cache miss) get queued
        // for the off-main-actor fingerprint pass below.
        var pendingFingerprintChecks: [WardrobeEmbeddingWorker.FingerprintRequest] = []
        var itemsPendingFingerprintPersist: [UUID: WardrobeItem] = [:]
        for item in inventory {
            guard !item.isGhostElement, let assetName = item.imageAssetName else { continue }

            if let fingerprint = item.imageFingerprint,
               let cached = embeddingsByItemID[item.id], cached.sourceFingerprint == fingerprint {
                history.itemEmbeddings[item.id] = cached.vector
                continue
            }

            pendingFingerprintChecks.append(WardrobeEmbeddingWorker.FingerprintRequest(itemID: item.id, filename: assetName))
            if item.imageFingerprint == nil {
                itemsPendingFingerprintPersist[item.id] = item
            }
        }

        // Off-main-actor, parallel across cores — best-effort per item, same
        // posture as `computeEmbeddings` below (a missing/unreadable photo
        // just drops that item rather than failing the whole fetch).
        let fingerprintResults = await embeddingWorker.computeFingerprints(for: pendingFingerprintChecks)

        var pendingEmbeddingRequests: [WardrobeEmbeddingWorker.EmbeddingRequest] = []
        for result in fingerprintResults {
            // Backfill: this item had no persisted fingerprint yet — cache
            // it now so every later fetch for this item takes the cheap
            // branch above instead of re-resolving it every time.
            itemsPendingFingerprintPersist[result.itemID]?.imageFingerprint = result.fingerprint

            if let cached = embeddingsByItemID[result.itemID], cached.sourceFingerprint == result.fingerprint {
                history.itemEmbeddings[result.itemID] = cached.vector
            } else {
                pendingEmbeddingRequests.append(WardrobeEmbeddingWorker.EmbeddingRequest(
                    itemID: result.itemID, imageData: result.imageData, sourceFingerprint: result.fingerprint
                ))
            }
        }
        if !itemsPendingFingerprintPersist.isEmpty {
            try? modelContext.save()
        }

        // Off-main-actor, parallel across cores — best-effort per item, same
        // posture as the serial loop this replaces (a Vision failure on one
        // item's photo shouldn't fail the whole feedback-history fetch).
        let embeddingResults = await embeddingWorker.computeEmbeddings(for: pendingEmbeddingRequests)

        // Back on the main actor: this is the only place that touches
        // `ModelContext`, so the worker itself never needs to.
        for result in embeddingResults {
            try? saveWardrobeItemEmbedding(itemID: result.itemID, vector: result.vector, sourceFingerprint: result.sourceFingerprint)
            history.itemEmbeddings[result.itemID] = result.vector
        }

        self.feedbackHistoryCache = history
        self.cachedFeedbackHistoryVersion = currentVersion
        return history
    }

    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {
        modelContext.insert(OutfitFeedback(outfitID: outfitID, likedOverall: likedOverall))
        try saveAndMarkMutated()
    }

    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {
        modelContext.insert(ItemFeedback(itemID: itemID, likedFit: likedFit))
        try saveAndMarkMutated()
    }

    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {
        modelContext.insert(PairFeedback(itemAID: itemAID, itemBID: itemBID, likedTogether: likedTogether))
        try saveAndMarkMutated()
    }

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
        let rating = ItemRating(
            itemID: itemID,
            fit: fit,
            comfort: comfort,
            colorLike: colorLike,
            patternLike: patternLike,
            formalityFit: formalityFit,
            styleIdentity: styleIdentity,
            wearAgain: wearAgain
        )
        modelContext.insert(rating)
        try saveAndMarkMutated()

        // Close the loop with Swipe-to-Learn Visual Taste: best-effort — a
        // rating should still save even if the visual-taste update fails or
        // this item has no cached embedding yet (see `applyImplicitSwipe`).
        try? applyImplicitSwipe(itemID: itemID, liked: rating.impliesLiked)
    }

    /// Folds a rating's derived liked/disliked signal into the same
    /// `VisualPreferenceState` centroids `recordSwipe` maintains, treating a
    /// highly-rated item as an implicit "swipe right" (and a poorly-rated one
    /// as an implicit "swipe left") — see `VisualClusterUpdater.implicitLearningRate`
    /// for why this uses a gentler fixed step than an explicit swipe. Unlike
    /// `recordSwipe`, this does not write a `SwipeEvent`: a rating isn't a
    /// discrete stock-photo swipe, so replaying `SwipeEvent` history to
    /// rebuild `VisualPreferenceState` (`VisualPreferenceProfile.build(from:dislikedEmbeddings:)`)
    /// should stay scoped to actual swipe gestures. No-ops if this item's
    /// photo embedding hasn't been computed yet — `WardrobeItemEmbedding` is
    /// populated lazily by `fetchFeedbackHistory()`, so a rating recorded
    /// before that happens simply misses this one nudge.
    private func applyImplicitSwipe(itemID: UUID, liked: Bool) throws {
        guard let embedding = try fetchWardrobeItemEmbedding(itemID: itemID)?.vector else { return }

        let state = try loadOrCreateVisualPreferenceState()
        var likedCentroids = state.likedCentroids
        var dislikedCentroids = state.dislikedCentroids
        let drift: Double?
        if liked {
            drift = VisualClusterUpdater.update(&likedCentroids, with: embedding, learningRate: VisualClusterUpdater.implicitLearningRate)
        } else {
            drift = VisualClusterUpdater.update(&dislikedCentroids, with: embedding, learningRate: VisualClusterUpdater.implicitLearningRate)
        }
        state.likedCentroids = likedCentroids
        state.dislikedCentroids = dislikedCentroids
        state.updatedAt = .now
        try modelContext.save()

        if let drift {
            MLLog.logger.notice("[AI-Stylist-ML] centroid drift: type=implicit side=\(liked ? "liked" : "disliked", privacy: .public) drift=\(drift, format: .fixed(precision: 2), privacy: .public)%")
        }
    }

    /// Shared fetch-or-create for the single-row `VisualPreferenceState` —
    /// used by both `recordSwipe` (explicit) and `applyImplicitSwipe`
    /// (rating-derived).
    private func loadOrCreateVisualPreferenceState() throws -> VisualPreferenceState {
        let existing = try modelContext.fetch(FetchDescriptor<VisualPreferenceState>()).first
        let state = existing ?? VisualPreferenceState()
        if existing == nil {
            modelContext.insert(state)
        }
        return state
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
            weakestItemID: submission.weakestItemID,
            changeReasons: Array(submission.changeReasons),
            likeReasons: Array(submission.likeReasons),
            occasion: submission.occasion,
            wouldBuySimilar: submission.wouldBuySimilar,
            savedForInspiration: submission.savedForInspiration,
            replacementSuggestion: submission.replacementSuggestion
        ))
        try saveAndMarkMutated()
    }

    func fetchOutfitFeedback(for outfitID: UUID) throws -> [OutfitFeedback] {
        let descriptor = FetchDescriptor<OutfitFeedback>(
            predicate: #Predicate { $0.outfitID == outfitID },
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func fetchAllItemRatings() throws -> [ItemRating] {
        try modelContext.fetch(FetchDescriptor<ItemRating>(sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]))
    }

    func fetchAllOutfitFeedback() throws -> [OutfitFeedback] {
        try modelContext.fetch(FetchDescriptor<OutfitFeedback>(sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]))
    }

    func fetchSavedCombinations() throws -> [SavedCombination] {
        let descriptor = FetchDescriptor<SavedCombination>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)])
        return try modelContext.fetch(descriptor)
    }

    @discardableResult
    func saveCombination(_ combination: SavedCombination) throws -> UUID {
        let candidateItemIDs = Set(combination.itemIDsBySlot.values).union(combination.supplementaryAccessoryItemIDs)
        if let existing = try fetchSavedCombinations().first(where: {
            Set($0.itemIDsBySlot.values).union($0.supplementaryAccessoryItemIDs) == candidateItemIDs
        }) {
            if !existing.hasRenderedImage && combination.hasRenderedImage {
                // Upgrade the existing placeholder in place rather than
                // leaving a second, image-bearing row for the same outfit.
                try updateCombinationImage(id: existing.id, assetName: combination.imageAssetName)
            } else if combination.hasRenderedImage {
                // A real render was already generated for `combination`
                // before this call (the caller writes the file, then builds
                // the row) but it's going unused — best-effort cleanup so it
                // doesn't leak on disk, same posture as `deleteCombination`.
                ImageStorage.delete(combination.imageAssetName)
            }
            return existing.id
        }

        modelContext.insert(combination)
        try modelContext.save()
        // Deliberately does NOT call `WardrobeMutationTracker.shared.markMutated()`:
        // `fetchFeedbackHistory()`'s cache (the only consumer of that version
        // counter besides `fetchInventory()`) never reads `SavedCombination`
        // rows except by joining through `OutfitFeedback.outfitID` — a bare
        // save with no feedback yet changes nothing that cache aggregates.
        // Bumping the version here anyway (a prior version of this method
        // did) forced a full, expensive recompute (Vision embeddings +
        // attribute profile) on the very next `fetchFeedbackHistory()` call
        // for zero benefit — see `recordOutfitFeedback` for where this
        // invalidation actually belongs.
        return combination.id
    }

    func updateCombinationImage(id: UUID, assetName: String) throws {
        let descriptor = FetchDescriptor<SavedCombination>(predicate: #Predicate { $0.id == id })
        guard let existing = try modelContext.fetch(descriptor).first else { return }
        let previousAssetName = existing.imageAssetName
        existing.imageAssetName = assetName
        try modelContext.save()
        // No `markMutated()` — same reasoning as `saveCombination` above;
        // an image swap changes nothing `fetchFeedbackHistory()` reads.
        // Best-effort — an orphaned placeholder file doesn't exist on disk
        // (it's a sentinel string, not a real `ImageStorage` filename) so
        // this only ever has real cleanup work to do for a genuine
        // re-render (a previously-rendered combination generating a new
        // image), never for the placeholder-replacement path.
        if previousAssetName != assetName && previousAssetName != SavedCombination.noRenderPlaceholderAssetName {
            ImageStorage.delete(previousAssetName)
        }
    }

    /// No `markMutated()` — same general posture as `saveCombination`/
    /// `updateCombinationImage` above (a `SavedCombination` write alone
    /// doesn't change anything `fetchFeedbackHistory()` aggregates). Known,
    /// accepted gap: if this combination already has `OutfitFeedback` rows
    /// pointing at it (recorded via `recordOutfitFeedback`/`recordOutfitRating`,
    /// both of which do bump the tracker on their own write), a cached
    /// `feedbackHistoryCache` built before this delete keeps crediting that
    /// feedback to this combination's item set until some other mutation
    /// happens to invalidate it — a fresh (uncached) recompute would instead
    /// drop it immediately, since `combinationsByID` can no longer resolve
    /// the now-deleted row. Left as-is rather than bumping here, since that
    /// would force a full embeddings + attribute-profile recompute on every
    /// combination deletion for a rare, low-severity staleness window.
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

    @discardableResult
    func recordSwipe(sourcePhotoID: String, imageURLString: String, liked: Bool, embedding: [Float]) throws -> Double? {
        modelContext.insert(SwipeEvent(
            sourcePhotoID: sourcePhotoID,
            imageURLString: imageURLString,
            liked: liked,
            embedding: embedding
        ))

        let state = try loadOrCreateVisualPreferenceState()
        let wasTrained = state.isTrained

        // Mutate local copies, then reassign — `VisualClusterUpdater.update`
        // takes `inout`, which a `@Model`-backed stored property can't be
        // passed as directly.
        var likedCentroids = state.likedCentroids
        var dislikedCentroids = state.dislikedCentroids
        let drift: Double?
        if liked {
            drift = VisualClusterUpdater.update(&likedCentroids, with: embedding)
        } else {
            drift = VisualClusterUpdater.update(&dislikedCentroids, with: embedding)
        }
        state.likedCentroids = likedCentroids
        state.dislikedCentroids = dislikedCentroids
        state.embeddingDimension = embedding.count
        state.updatedAt = .now
        // Calibration progress is driven by explicit deck swipes only — see
        // `VisualPreferenceState.totalSwipes`'s doc comment.
        state.totalSwipes += 1

        try saveAndMarkMutated()

        if let drift {
            MLLog.logger.notice("[AI-Stylist-ML] centroid drift: type=explicit side=\(liked ? "liked" : "disliked", privacy: .public) drift=\(drift, format: .fixed(precision: 2), privacy: .public)%")
        }
        if !wasTrained && state.isTrained {
            MLLog.logger.notice("[AI-Stylist-ML] calibration complete: isTrained=true totalSwipes=\(state.totalSwipes, privacy: .public)")
        }

        return drift
    }

    func fetchVisualPreferenceState() throws -> VisualPreferenceState? {
        try modelContext.fetch(FetchDescriptor<VisualPreferenceState>()).first
    }

    func updateVisualPreferenceState(
        likedCentroids: [VisualCentroid],
        dislikedCentroids: [VisualCentroid],
        embeddingDimension: Int
    ) throws {
        let state = try loadOrCreateVisualPreferenceState()
        state.likedCentroids = likedCentroids
        state.dislikedCentroids = dislikedCentroids
        state.embeddingDimension = embeddingDimension
        state.updatedAt = .now
        try saveAndMarkMutated()
    }

    func fetchWardrobeItemEmbedding(itemID: UUID) throws -> WardrobeItemEmbedding? {
        let descriptor = FetchDescriptor<WardrobeItemEmbedding>(
            predicate: #Predicate { $0.itemID == itemID }
        )
        return try modelContext.fetch(descriptor).first
    }

    /// Deliberately a bare `modelContext.save()`, not `saveAndMarkMutated()`,
    /// even though `WardrobeItemEmbedding` rows feed `fetchFeedbackHistory()`'s
    /// `itemEmbeddings` map: this method's only current caller is
    /// `fetchFeedbackHistory()` itself, mid-recompute (line ~610 below),
    /// persisting an embedding it just lazily computed for the cache entry
    /// it's about to write. Bumping the tracker here would change
    /// `WardrobeMutationTracker.shared.version` out from under the
    /// `currentVersion` that recompute captured at its own start, so the
    /// freshly-built cache would immediately register as stale against
    /// itself on the very next call — forcing a full re-embed every time
    /// there's any new embedding to compute, defeating the cache entirely.
    /// If a future caller invokes this from outside `fetchFeedbackHistory()`
    /// (e.g. recovery tooling), it must bump the tracker itself afterward.
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

    func recordImpressions(roundID: UUID, outfits: [OutfitCombination]) throws {
        try pruneOldImpressionEvents()
        for (rank, outfit) in outfits.enumerated() {
            modelContext.insert(RecommendationImpressionEvent(
                id: outfit.id,
                roundID: roundID,
                rank: rank,
                itemIDsBySlot: outfit.itemsBySlot.mapValues(\.id)
            ))
        }
        try modelContext.save()
        MLLog.logger.notice("[AI-Stylist-ML] impressions recorded: round=\(roundID, privacy: .public) count=\(outfits.count, privacy: .public)")
    }

    /// Retention policy for `RecommendationImpressionEvent` — per its own
    /// doc comment, nothing reads this table yet, so without this it would
    /// grow by a few rows every Daily Assistant turn, forever, for as long as
    /// the app is used. Pruned opportunistically here (once per recorded
    /// round — cheap relative to the round's own LLM round-trip this is
    /// already part of) rather than a separate scheduled job.
    private static let impressionRetentionInterval: TimeInterval = 90 * 24 * 60 * 60

    private func pruneOldImpressionEvents() throws {
        let cutoffDate = Date.now.addingTimeInterval(-Self.impressionRetentionInterval)
        let staleEvents = try modelContext.fetch(FetchDescriptor<RecommendationImpressionEvent>(
            predicate: #Predicate { $0.shownAt < cutoffDate }
        ))
        guard !staleEvents.isEmpty else { return }
        for event in staleEvents {
            modelContext.delete(event)
        }
    }

    func recordSelection(outfitID: UUID) throws {
        let descriptor = FetchDescriptor<RecommendationImpressionEvent>(
            predicate: #Predicate { $0.id == outfitID }
        )
        guard let event = try modelContext.fetch(descriptor).first else { return }
        event.selectedAt = .now
        try modelContext.save()
        MLLog.logger.notice("[AI-Stylist-ML] selection recorded: outfit=\(outfitID, privacy: .public) rank=\(event.rank, privacy: .public)")
    }

    // MARK: - Analytics & Insights (Phase 2)

    func fetchAnalyticsSnapshots() throws -> [AnalyticsSnapshot] {
        try modelContext.fetch(FetchDescriptor<AnalyticsSnapshot>(sortBy: [SortDescriptor(\.periodKey, order: .reverse)]))
    }

    func upsertAnalyticsSnapshot(periodKey: String, payloadJSON: String) throws {
        let descriptor = FetchDescriptor<AnalyticsSnapshot>(predicate: #Predicate { $0.periodKey == periodKey })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.payloadJSON = payloadJSON
            existing.computedAt = .now
        } else {
            modelContext.insert(AnalyticsSnapshot(periodKey: periodKey, payloadJSON: payloadJSON))
        }
        try modelContext.save()
    }

    func fetchRecommendationAnalyticsSnapshots() throws -> [RecommendationAnalyticsSnapshot] {
        try modelContext.fetch(FetchDescriptor<RecommendationAnalyticsSnapshot>(sortBy: [SortDescriptor(\.periodKey, order: .reverse)]))
    }

    func upsertRecommendationAnalyticsSnapshot(periodKey: String, shownCount: Int, selectedCount: Int) throws {
        let descriptor = FetchDescriptor<RecommendationAnalyticsSnapshot>(predicate: #Predicate { $0.periodKey == periodKey })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.shownCount = shownCount
            existing.selectedCount = selectedCount
            existing.computedAt = .now
        } else {
            modelContext.insert(RecommendationAnalyticsSnapshot(periodKey: periodKey, shownCount: shownCount, selectedCount: selectedCount))
        }
        try modelContext.save()
    }

    func fetchWornLogEntries() throws -> [WornLogEntry] {
        try modelContext.fetch(FetchDescriptor<WornLogEntry>(sortBy: [SortDescriptor(\.wornAt, order: .reverse)]))
    }

    func fetchWornLogEntries(since cutoff: Date) throws -> [WornLogEntry] {
        try modelContext.fetch(FetchDescriptor<WornLogEntry>(
            predicate: #Predicate { $0.wornAt >= cutoff },
            sortBy: [SortDescriptor(\.wornAt, order: .reverse)]
        ))
    }

    func logWorn(savedCombinationID: UUID, itemIDs: [UUID]) throws {
        modelContext.insert(WornLogEntry(savedCombinationID: savedCombinationID, itemIDs: itemIDs))
        try modelContext.save()
        // No `markMutated()` — `WornLogEntry` isn't read by
        // `fetchFeedbackHistory()` at all; Anti-Repetition's rotation
        // history (`DailyAssistantViewModel.fetchRecentOutfitHistory()`)
        // deliberately reads this table directly/uncached rather than
        // through that cache, so there is nothing here for the version
        // counter to protect — bumping it only forced an unrelated,
        // expensive recompute on the next unrelated `fetchFeedbackHistory()`
        // call (observed: contributed to a recommendation request blowing
        // past its 15s deadline and being cancelled).
    }

    @discardableResult
    func saveAndLogWorn(combination: SavedCombination, itemIDs: [UUID]) throws -> UUID {
        let persistedID = try saveCombination(combination)
        try logWorn(savedCombinationID: persistedID, itemIDs: itemIDs)
        return persistedID
    }

    func fetchPairBans() throws -> [ItemPairBan] {
        try modelContext.fetch(FetchDescriptor<ItemPairBan>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    func recordPairBan(itemAID: UUID, itemBID: UUID) throws {
        let candidate = ItemPairBan(itemA: itemAID, itemB: itemBID)
        let existing = try fetchPairBans()
        guard !existing.contains(where: { $0.itemAID == candidate.itemAID && $0.itemBID == candidate.itemBID }) else { return }
        modelContext.insert(candidate)
        try modelContext.save()
    }

    func removePairBan(id: UUID) throws {
        let descriptor = FetchDescriptor<ItemPairBan>(predicate: #Predicate { $0.id == id })
        guard let existing = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }
}
