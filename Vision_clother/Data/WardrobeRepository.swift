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
    /// Fit, Style Identity, Wear Again. The rating's taste signal reaches
    /// recommendations via `fetchFeedbackHistory()`'s `AttributePreferenceProfile`
    /// rebuild, not through any separate write here.
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

    /// Swipe + Comment combination feedback (2026-07-27) — replaces the
    /// manual Level 1/2/3 form as the write path for a user's own combination
    /// feedback (`Features/Rating/RateCombinationView.swift`). `outfitID`
    /// must be a `SavedCombination.id`, same as `recordOutfitRating`. `chemistry`
    /// is the LLM-inferred `CombinationMetadata` from
    /// `Services/CombinationChemistryInferenceService.swift` — `nil` when that
    /// call failed, in which case sentiment/comment are still saved (a flaky
    /// LLM call must never lose the user's swipe). Upserts one `OutfitFeedback`
    /// row per outfit from this new flow (never overwrites an old-flow row's
    /// Level 1/2/3 fields).
    func recordCombinationSwipeFeedback(outfitID: UUID, sentiment: SwipeSentiment, comment: String?, chemistry: CombinationMetadata?) throws

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

    /// Current swipe-deck calibration state, `nil` before the first swipe.
    /// Only `totalSwipes`/`calibrationProgress`/`isTrained` are meaningful —
    /// the learned taste itself lives in `AttributePreferenceProfile`.
    func fetchVisualPreferenceState() throws -> VisualPreferenceState?
    /// Persists one swipe's scene attributes (extracted by
    /// `Services/VisionMetadataExtractionService.swift`'s `extractSceneMetadata`)
    /// so the swipe teaches `Domain/AttributePreferenceProfile.swift`
    /// affinities — the sole Swipe-to-Learn signal since the pixel-embedding
    /// engine was retired (2026-07-24). Upserts one `SwipeAttributeEvent` per
    /// `(sourcePhotoID, slot)` pair (a re-shown photo, or one already tagged
    /// at this slot, is updated in place rather than duplicated) and, when
    /// `sceneMetadata.combination` is non-`nil` (2+ garments detected), one
    /// `SwipeCombinationEvent` keyed by `sourcePhotoID`. Local-only (not
    /// synced).
    func recordSwipeAttributes(sourcePhotoID: String, imageURLString: String, sentiment: SwipeSentiment, sceneMetadata: SceneMetadata) throws
    /// Whether a swipe-attribute event already exists for this photo id — lets
    /// the deck skip a redundant (paid) LLM tagging call on a re-shown card.
    func hasSwipeAttributes(sourcePhotoID: String) throws -> Bool
    /// Increments the swipe deck's calibration counter — the taste signal
    /// itself is learned via `recordSwipeAttributes`. The single surviving
    /// use of `VisualPreferenceState` after the pixel engine was retired
    /// (2026-07-24).
    func noteSwipeForCalibration() throws

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
    /// Deletes one `WornLogEntry` row — the "Undo" affordance on an
    /// accidental "Wearing This Today" tap (`Features/Combinations/CombinationDetailView.swift`).
    /// Scoped to the exact entry the undo targets, never a blanket "clear
    /// today's wears": `WornLogEntry` otherwise stays append-only/no-delete
    /// by design (see its doc comment) — this exists only to correct a
    /// same-visit mis-tap, not to edit wear history in general.
    func deleteWornLogEntry(id: UUID) throws

    /// Anti-Repetition — the permanent "never recommend these two together"
    /// veto (see `Models/ItemPairBan.swift`).
    func fetchPairBans() throws -> [ItemPairBan]
    /// Dedupes on write against the order-independent key — re-banning an
    /// already-banned pair is a no-op, not a duplicate row.
    func recordPairBan(itemAID: UUID, itemBID: UUID) throws
    /// No "unban" UI ships yet, but the method exists now so a future one
    /// needs no further protocol/migration change.
    func removePairBan(id: UUID) throws

    /// Compressed cross-session memory (Hermes-inspired session-summary
    /// feature, see docs/decisions/resolved-v1.md) — persists one
    /// `SessionSummary` row and prunes down to the last few (see
    /// `pruneOldSessionSummaries`'s doc comment on `SwiftDataWardrobeRepository`).
    func recordSessionSummary(text: String) throws
    /// Newest first, capped at `limit` — feeds `Domain/StylistBrain.swift`'s
    /// recommendation-prompt injection.
    func fetchRecentSessionSummaries(limit: Int) throws -> [SessionSummary]
    /// Every stored row, unfiltered — bootstrap sync push
    /// (`Data/WardrobeSyncCoordinator.swift`'s `pushEverythingLocal`) only.
    func fetchAllSessionSummaries() throws -> [SessionSummary]

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

    // MARK: - Item-Level Feedback (Models/ItemNote.swift)

    /// Every note on one garment, newest first. Unlike the append-only
    /// feedback tables, these are mutable rows the user can edit or delete —
    /// see `Models/ItemNote.swift` for why this one table breaks that
    /// convention.
    func fetchItemNotes(for itemID: UUID) throws -> [ItemNote]
    /// All notes, keyed by item — one fetch for
    /// `Domain/WardrobeCatalogBuilder.swift`, which needs every item's notes
    /// at once and must not issue a query per garment.
    func fetchAllItemNotes() throws -> [UUID: [ItemNote]]
    /// Appends a note. Deliberately not an upsert on `text` — the same
    /// complaint made twice about the same garment is one note, so callers
    /// dedupe on `(itemID, text)` via this method's own check rather than
    /// accumulating duplicates from repeated chip taps.
    @discardableResult
    func addItemNote(itemID: UUID, text: String, severity: ItemNoteSeverity, source: ItemNoteSource, context: ItemNoteContext) throws -> ItemNote?
    /// Edits a note's text and/or severity in place, bumping `updatedAt`.
    /// Re-authoring a note always re-stamps `source` as `.user` — once a
    /// person has corrected it, it is no longer an inferred or chip-derived
    /// claim.
    func updateItemNote(id: UUID, text: String, severity: ItemNoteSeverity) throws
    func deleteItemNote(id: UUID) throws
}

/// Default no-op fallbacks for the two Insights-Q&A bulk-fetch methods above
/// plus `deleteWornLogEntry` — keeps every pre-existing `WardrobeRepository`
/// test double compiling without needing a change for a feature they don't
/// exercise. Only `SwiftDataWardrobeRepository`/`SyncingWardrobeRepository` (the real
/// production path) override these.
extension WardrobeRepository {
    func fetchAllItemRatings() throws -> [ItemRating] { [] }
    func fetchAllOutfitFeedback() throws -> [OutfitFeedback] { [] }
    func deleteWornLogEntry(id: UUID) throws {}
    func recordSessionSummary(text: String) throws {}
    func fetchRecentSessionSummaries(limit: Int) throws -> [SessionSummary] { [] }
    func fetchAllSessionSummaries() throws -> [SessionSummary] { [] }

    func fetchItemNotes(for itemID: UUID) throws -> [ItemNote] { [] }
    func fetchAllItemNotes() throws -> [UUID: [ItemNote]] { [:] }
    @discardableResult
    func addItemNote(itemID: UUID, text: String, severity: ItemNoteSeverity, source: ItemNoteSource, context: ItemNoteContext) throws -> ItemNote? { nil }
    func updateItemNote(id: UUID, text: String, severity: ItemNoteSeverity) throws {}
    func deleteItemNote(id: UUID) throws {}
}

@MainActor
final class SwiftDataWardrobeRepository: WardrobeRepository {
    private let modelContext: ModelContext

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

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
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
    /// `logWorn`, and the read-only-to-this-cache
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
        // Swipe-to-Learn taste, attribute space: each `SwipeAttributeEvent`
        // (one detected garment's attributes from a swiped scene photo) is a
        // synthetic rating — its `SwipeSentiment.ratingValue` (love=1.0,
        // like=0.75, dislike=0.25, hate=0.0) teaches "likes this color/pattern/
        // formality/…" at that strength — folded into the same
        // `AttributePreferenceProfile` owned-item ratings drive, so swipes
        // flow straight into recommendations/Insights rather than the
        // separate (weaker) pixel-embedding centroids. `recordedAt` carries the
        // same exponential time-decay as ratings.
        let swipeAttributeEvents = try modelContext.fetch(FetchDescriptor<SwipeAttributeEvent>())
        let swipeRatedAttributes: [RatedAttributes] = swipeAttributeEvents.map { event in
            let signal = event.sentiment.ratingValue
            return RatedAttributes(
                colorLike: signal,
                patternLike: signal,
                formalityFit: signal,
                colorVibe: event.colorVibe,
                pattern: event.pattern,
                formalityBand: event.formalityBand,
                styleIdentity: signal,
                styleTags: event.styleTags,
                recordedAt: event.recordedAt,
                slot: event.slot,
                silhouetteTag: event.silhouette,
                silhouetteFit: event.silhouette != nil ? signal : nil,
                fabricWeight: event.fabricWeight,
                fabricComfort: signal,
                undertone: event.undertone,
                material: event.material,
                texture: event.texture,
                fit: event.fit,
                fitLike: event.fit != nil ? signal : nil,
                weight: event.weight
            )
        }

        // Multi-Garment "Discover Your Style": each `SwipeCombinationEvent`
        // (a swiped photo with 2+ detected garments) is a whole-look synthetic
        // rating — feeds `AttributePreferenceProfile.colorHarmonyAffinity`
        // (Insights-only; not read by the recommendation scoring engine).
        let swipeCombinationEvents = try modelContext.fetch(FetchDescriptor<SwipeCombinationEvent>())
        let stockPhotoRatedCombinations: [RatedCombination] = swipeCombinationEvents.map { event in
            RatedCombination(
                colorHarmony: event.colorHarmony,
                styleTags: event.styleCoherenceTags,
                signal: event.sentiment.ratingValue,
                recordedAt: event.recordedAt,
                paletteArchetype: event.paletteArchetype,
                contrastLevel: event.contrastLevel,
                colorSandwiching: event.colorSandwiching,
                proportionRatio: event.proportionRatio,
                volumeBalance: event.volumeBalance,
                textureContrast: event.textureContrast,
                formalityBridge: event.formalityBridge,
                overallAestheticVibe: event.overallAestheticVibe,
                complexityScore: event.complexityScore
            )
        }

        // Swipe + Comment combination feedback (2026-07-27): a user's own
        // combination, swiped + optionally LLM-chemistry-inferred, unified
        // into the same `[RatedCombination]` signal as stock-photo swipes
        // above — one learned taste, regardless of source.
        let ownCombinationRatedCombinations: [RatedCombination] = outfitFeedbacks.compactMap { feedback -> RatedCombination? in
            guard let sentiment = feedback.swipeSentiment, let chemistry = feedback.inferredCombinationMetadata else { return nil }
            return RatedCombination(
                colorHarmony: chemistry.colorHarmony,
                styleTags: chemistry.styleCoherenceTags,
                signal: sentiment.ratingValue,
                recordedAt: feedback.recordedAt,
                paletteArchetype: chemistry.paletteArchetype,
                contrastLevel: chemistry.contrastLevel,
                colorSandwiching: chemistry.colorSandwiching,
                proportionRatio: chemistry.proportionRatio,
                volumeBalance: chemistry.volumeBalance,
                textureContrast: chemistry.textureContrast,
                formalityBridge: chemistry.formalityBridge,
                overallAestheticVibe: chemistry.overallAestheticVibe,
                complexityScore: chemistry.complexityScore
            )
        }
        let ratedCombinations = stockPhotoRatedCombinations + ownCombinationRatedCombinations

        let detailedOutfitFeedbacks = outfitFeedbacks.filter { $0.normalizedRating != nil }
        // `swipeRatedOutfitFeedbacks` is checked separately from
        // `ratedCombinations`: a combination swipe whose background chemistry
        // inference failed produces a sentiment row but no `RatedCombination`,
        // and its per-item fan-out below is still valid signal that must not
        // be gated behind the chemistry call having succeeded.
        let swipeRatedOutfitFeedbacks = outfitFeedbacks.filter { $0.normalizedRating == nil && $0.swipeSentiment != nil }
        if !itemRatings.isEmpty || !detailedOutfitFeedbacks.isEmpty || !swipeRatedAttributes.isEmpty
            || !ratedCombinations.isEmpty || !swipeRatedOutfitFeedbacks.isEmpty {
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
                    fabricComfort: Double(rating.comfort - 1) / 4.0,
                    undertone: item.colorProfile.undertone,
                    material: item.material,
                    texture: item.texture,
                    fit: item.fit,
                    fitLike: item.fit != nil ? rating.fit.centeredness : nil,
                    patternScale: item.patternScale,
                    textureFinish: item.textureFinish,
                    silhouetteCut: item.silhouetteCut,
                    necklineOrRise: item.necklineOrRise,
                    fabricWeightDetail: item.fabricWeightDetail
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
                        slot: item.slot,
                        undertone: item.colorProfile.undertone,
                        material: item.material,
                        texture: item.texture,
                        fit: item.fit,
                        patternScale: item.patternScale,
                        textureFinish: item.textureFinish,
                        silhouetteCut: item.silhouetteCut,
                        necklineOrRise: item.necklineOrRise,
                        fabricWeightDetail: item.fabricWeightDetail
                    )
                }
            }

            // Item-Level Feedback (2026-07-27): the combination-swipe flow
            // that replaced the Level 1/2/3 form records a whole-look
            // sentiment and no per-dimension answers, so its rows have a
            // `nil` `normalizedRating` and were excluded from
            // `detailedOutfitFeedbacks` above — meaning that since that
            // refactor, rating your own outfit taught whole-look chemistry
            // and *nothing per-garment*. `ItemRating` has no writer either,
            // so per-category taste learned from the user's own closet had
            // stopped moving entirely.
            //
            // Fan the sentiment back out across the garments in the look, at
            // `1/N` credit — the same credit assignment a multi-garment stock
            // swipe already uses (`recordSwipeAttributes`), for the same
            // reason: one judgment about N garments is not N independent
            // judgments. Every dimension takes the same sentiment because
            // that's genuinely all the user said; `patternDissatisfaction`
            // stays `nil` because a disliked outfit is not evidence the
            // *pattern* was the problem, and inventing that signal would
            // teach `patternAffinity` something never expressed.
            let swipeOutfitDimensionRatings: [OutfitDimensionRatedAttributes] = swipeRatedOutfitFeedbacks.flatMap { feedback -> [OutfitDimensionRatedAttributes] in
                guard let sentiment = feedback.swipeSentiment,
                      let combination = combinationsByID[feedback.outfitID]
                else { return [] }

                let items = combination.itemIDsBySlot.values.compactMap { itemsByID[$0] }
                guard !items.isEmpty else { return [] }

                let signal = sentiment.ratingValue
                let perItemWeight = 1.0 / Double(items.count)
                return items.map { item in
                    OutfitDimensionRatedAttributes(
                        colorHarmony: signal,
                        occasionMatch: signal,
                        styleMatch: signal,
                        silhouette: signal,
                        weatherFit: signal,
                        colorVibe: item.colorProfile.category,
                        styleTags: item.styleTags,
                        silhouetteTag: item.silhouette,
                        formalityBand: Int(item.formalityScore.rounded()),
                        fabricWeight: item.fabricWeight,
                        pattern: item.pattern,
                        patternDissatisfaction: nil,
                        recordedAt: feedback.recordedAt,
                        slot: item.slot,
                        undertone: item.colorProfile.undertone,
                        material: item.material,
                        texture: item.texture,
                        fit: item.fit,
                        patternScale: item.patternScale,
                        textureFinish: item.textureFinish,
                        silhouetteCut: item.silhouetteCut,
                        necklineOrRise: item.necklineOrRise,
                        fabricWeightDetail: item.fabricWeightDetail,
                        weight: perItemWeight
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
                    slot: item.slot,
                    undertone: item.colorProfile.undertone,
                    material: item.material,
                    texture: item.texture,
                    fit: item.fit,
                    patternScale: item.patternScale,
                    textureFinish: item.textureFinish,
                    silhouetteCut: item.silhouetteCut,
                    necklineOrRise: item.necklineOrRise,
                    fabricWeightDetail: item.fabricWeightDetail
                )
            }

            let attributeProfile = await Task.detached(priority: .userInitiated) {
                AttributePreferenceProfile.build(
                    from: ratedAttributes + swipeRatedAttributes,
                    outfitDimensionRatings: outfitDimensionRatings + swipeOutfitDimensionRatings,
                    combinationRatings: ratedCombinations,
                    inventorySnapshots: inventorySnapshots,
                    now: now
                )
            }.value

            history.attributeProfile = attributeProfile
        }

        // Swipe-to-Learn taste is now unified into `attributeProfile` above
        // (2026-07-24): the former pixel-embedding pass here — reading
        // `VisualPreferenceState` centroids and lazily computing/caching a
        // `WardrobeItemEmbedding` per item to feed a separate visual re-rank —
        // was removed when the engine and catalog builder switched to the
        // single `AttributePreferenceProfile`. `VisualPreferenceState`/
        // `SwipeEvent`/`WardrobeItemEmbedding` remain as inert tables (kept to
        // avoid a destructive migration; `VisualPreferenceState.totalSwipes`
        // still drives the swipe deck's calibration ring).

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
        // Taste learning happens entirely through `fetchFeedbackHistory()`'s
        // `AttributePreferenceProfile` rebuild now (2026-07-24) — this rating's
        // per-attribute values are folded in there. The former implicit-swipe
        // pixel-centroid nudge was removed with the rest of the visual engine.
    }

    /// Bumps the swipe deck's calibration counter (`VisualPreferenceState.totalSwipes`)
    /// — the only thing the retired visual engine still powers is the gamified
    /// calibration ring. The garment's taste signal itself is learned
    /// separately via `recordSwipeAttributes` (attribute space).
    /// Best-effort; a counter hiccup must never fail a swipe.
    func noteSwipeForCalibration() throws {
        let state = try loadOrCreateVisualPreferenceState()
        let wasTrained = state.isTrained
        state.totalSwipes += 1
        state.updatedAt = .now
        try saveAndMarkMutated()
        if !wasTrained && state.isTrained {
            MLLog.logger.notice("[AI-Stylist-ML] calibration complete: isTrained=true totalSwipes=\(state.totalSwipes, privacy: .public)")
        }
    }

    /// Shared fetch-or-create for the single-row `VisualPreferenceState` —
    /// `noteSwipeForCalibration` is the only writer.
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

    func recordCombinationSwipeFeedback(outfitID: UUID, sentiment: SwipeSentiment, comment: String?, chemistry: CombinationMetadata?) throws {
        // Upsert against an existing *new-flow* row only — an old-flow
        // detailed-rating row (swipeSentimentRaw == nil) for this outfit must
        // never be overwritten by a re-swipe.
        let descriptor = FetchDescriptor<OutfitFeedback>(
            predicate: #Predicate { $0.outfitID == outfitID && $0.swipeSentimentRaw != nil }
        )
        if let existing = try modelContext.fetch(descriptor).first {
            existing.likedOverall = sentiment.liked
            existing.swipeSentimentRaw = sentiment.rawValue
            existing.swipeComment = comment
            existing.inferredColorHarmonyRaw = chemistry?.colorHarmony.rawValue
            existing.inferredStyleCoherenceTags = chemistry?.styleCoherenceTags ?? []
            existing.inferredFormalityConsistencyRaw = chemistry?.formalityConsistency.rawValue
            existing.inferredRationale = chemistry?.rationale
            existing.inferredPaletteArchetypeRaw = chemistry?.paletteArchetype.rawValue
            existing.inferredContrastLevelRaw = chemistry?.contrastLevel.rawValue
            existing.inferredColorSandwiching = chemistry?.colorSandwiching
            existing.inferredColorDistribution = chemistry?.colorDistribution
            existing.inferredProportionRatioRaw = chemistry?.proportionRatio.rawValue
            existing.inferredVolumeBalanceRaw = chemistry?.volumeBalance.rawValue
            existing.inferredTextureContrastRaw = chemistry?.textureContrast.rawValue
            existing.inferredFormalityBridgeRaw = chemistry?.formalityBridge.rawValue
            existing.inferredOverallAestheticVibe = chemistry?.overallAestheticVibe
            existing.inferredComplexityScore = chemistry?.complexityScore
            existing.recordedAt = .now
        } else {
            modelContext.insert(OutfitFeedback(
                outfitID: outfitID,
                likedOverall: sentiment.liked,
                sentiment: sentiment,
                comment: comment,
                inferredChemistry: chemistry
            ))
        }
        try saveAndMarkMutated()
        MLLog.logger.notice("[AI-Stylist-ML] combination swipe: outfit=\(outfitID, privacy: .public) sentiment=\(sentiment.rawValue, privacy: .public) hasComment=\(comment != nil, privacy: .public) hasChemistry=\(chemistry != nil, privacy: .public)")
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

    func fetchVisualPreferenceState() throws -> VisualPreferenceState? {
        try modelContext.fetch(FetchDescriptor<VisualPreferenceState>()).first
    }

    func recordSwipeAttributes(sourcePhotoID: String, imageURLString: String, sentiment: SwipeSentiment, sceneMetadata: SceneMetadata) throws {
        // Credit-assignment weight: a swiped photo with N detected garments
        // fans its sentiment out to N rows, so each row is worth 1/N of a
        // single-garment swipe's full signal — an N-garment "full outfit"
        // swipe no longer injects N× the raw signal of a 1-garment swipe for
        // the same sentiment (2026-07-27). A single-garment photo naturally
        // gets `weight = 1.0`, unchanged from before this existed.
        let weight = 1.0 / Double(max(sceneMetadata.garments.count, 1))
        for garment in sceneMetadata.garments {
            let colorVibe = garment.colorProfile.category
            // Same banding `fetchFeedbackHistory` applies to owned items, so a
            // swipe and a rating land in the same `formalityAffinity` bucket.
            let formalityBand = Int(garment.formalityScore.rounded())
            let slot = garment.slot

            let descriptor = FetchDescriptor<SwipeAttributeEvent>(
                predicate: #Predicate { $0.sourcePhotoID == sourcePhotoID && $0.slot == slot }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                // Re-swipe of the same photo (deck reshuffle) — update in
                // place so the most recent direction wins rather than
                // double-counting.
                existing.imageURLString = imageURLString
                existing.sentiment = sentiment
                existing.colorVibe = colorVibe
                existing.pattern = garment.pattern
                existing.formalityBand = formalityBand
                existing.fabricWeight = garment.fabricWeight
                existing.styleTags = garment.styleTags
                existing.silhouette = garment.silhouette
                existing.undertone = garment.colorProfile.undertone
                existing.material = garment.material
                existing.texture = garment.texture
                existing.fit = garment.fit
                existing.weight = weight
                existing.recordedAt = .now
            } else {
                modelContext.insert(SwipeAttributeEvent(
                    sourcePhotoID: sourcePhotoID,
                    imageURLString: imageURLString,
                    sentiment: sentiment,
                    colorVibe: colorVibe,
                    pattern: garment.pattern,
                    formalityBand: formalityBand,
                    fabricWeight: garment.fabricWeight,
                    slot: slot,
                    styleTags: garment.styleTags,
                    silhouette: garment.silhouette,
                    undertone: garment.colorProfile.undertone,
                    material: garment.material,
                    texture: garment.texture,
                    fit: garment.fit,
                    weight: weight
                ))
            }
        }

        if let combination = sceneMetadata.combination {
            let comboDescriptor = FetchDescriptor<SwipeCombinationEvent>(
                predicate: #Predicate { $0.sourcePhotoID == sourcePhotoID }
            )
            if let existing = try modelContext.fetch(comboDescriptor).first {
                existing.sentiment = sentiment
                existing.colorHarmony = combination.colorHarmony
                existing.styleCoherenceTags = combination.styleCoherenceTags
                existing.formalityConsistency = combination.formalityConsistency
                existing.rationale = combination.rationale
                existing.paletteArchetypeRaw = combination.paletteArchetype.rawValue
                existing.contrastLevelRaw = combination.contrastLevel.rawValue
                existing.colorSandwiching = combination.colorSandwiching
                existing.colorDistribution = combination.colorDistribution
                existing.proportionRatioRaw = combination.proportionRatio.rawValue
                existing.volumeBalanceRaw = combination.volumeBalance.rawValue
                existing.textureContrastRaw = combination.textureContrast.rawValue
                existing.formalityBridgeRaw = combination.formalityBridge.rawValue
                existing.overallAestheticVibe = combination.overallAestheticVibe
                existing.complexityScore = combination.complexityScore
                existing.recordedAt = .now
            } else {
                modelContext.insert(SwipeCombinationEvent(
                    sourcePhotoID: sourcePhotoID,
                    sentiment: sentiment,
                    colorHarmony: combination.colorHarmony,
                    styleCoherenceTags: combination.styleCoherenceTags,
                    formalityConsistency: combination.formalityConsistency,
                    rationale: combination.rationale,
                    paletteArchetype: combination.paletteArchetype,
                    contrastLevel: combination.contrastLevel,
                    colorSandwiching: combination.colorSandwiching,
                    colorDistribution: combination.colorDistribution,
                    proportionRatio: combination.proportionRatio,
                    volumeBalance: combination.volumeBalance,
                    textureContrast: combination.textureContrast,
                    formalityBridge: combination.formalityBridge,
                    overallAestheticVibe: combination.overallAestheticVibe,
                    complexityScore: combination.complexityScore
                ))
            }
        }

        // `fetchFeedbackHistory()` reads both `SwipeAttributeEvent` and
        // `SwipeCombinationEvent` into the attribute profile, so this must
        // invalidate that cache — not a bare `modelContext.save()`.
        try saveAndMarkMutated()
        MLLog.logger.notice("[AI-Stylist-ML] swipe attributes: photo=\(sourcePhotoID, privacy: .public) sentiment=\(sentiment.rawValue, privacy: .public) garments=\(sceneMetadata.garments.count, privacy: .public) hasCombo=\(sceneMetadata.combination != nil, privacy: .public)")
    }

    func hasSwipeAttributes(sourcePhotoID: String) throws -> Bool {
        let descriptor = FetchDescriptor<SwipeAttributeEvent>(
            predicate: #Predicate { $0.sourcePhotoID == sourcePhotoID }
        )
        return try modelContext.fetch(descriptor).first != nil
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

    func deleteWornLogEntry(id: UUID) throws {
        let descriptor = FetchDescriptor<WornLogEntry>(predicate: #Predicate { $0.id == id })
        guard let existing = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(existing)
        try modelContext.save()
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

    // MARK: - Compressed cross-session memory (Models/SessionSummary.swift)

    func recordSessionSummary(text: String) throws {
        let summary = SessionSummary(summaryText: text)
        modelContext.insert(summary)
        // Bare `modelContext.save()`, not `saveAndMarkMutated()` — same
        // reasoning as `recordPairBan`/`logWorn`: `SessionSummary` isn't read
        // by `fetchInventory()` or `fetchFeedbackHistory()`, the two caches
        // `WardrobeMutationTracker` invalidation protects.
        try modelContext.save()
        try pruneOldSessionSummaries()
        AppLog.info(.recommendation, "[SessionSummary] persisted id=\(summary.id) length=\(summary.summaryText.count)")
    }

    func fetchRecentSessionSummaries(limit: Int) throws -> [SessionSummary] {
        var descriptor = FetchDescriptor<SessionSummary>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
    }

    func fetchAllSessionSummaries() throws -> [SessionSummary] {
        try modelContext.fetch(FetchDescriptor<SessionSummary>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
    }

    /// Rolling-buffer retention (see the plan's "Risk: context drift over
    /// many sessions" note) — deliberately a hard count cap, not a
    /// continuously-rewritten single profile: growth is structurally
    /// bounded regardless of how many sessions a user has, and a bad write
    /// can never corrupt prior history since each row is independent.
    private static let maxStoredSessionSummaries = 5

    private func pruneOldSessionSummaries() throws {
        let all = try fetchAllSessionSummaries()
        guard all.count > Self.maxStoredSessionSummaries else { return }
        for stale in all.dropFirst(Self.maxStoredSessionSummaries) {
            modelContext.delete(stale)
        }
        try modelContext.save()
        AppLog.info(.recommendation, "[SessionSummary] pruned to \(Self.maxStoredSessionSummaries)")
    }

    // MARK: - Item-Level Feedback (Models/ItemNote.swift)

    /// Hard cap on notes kept per garment. Notes are joined into
    /// `CatalogEntry.userNote` for every item that has any, so an uncapped
    /// list would let one garment consume a meaningful slice of the
    /// recommendation prompt. Capped by *recency* rather than expiry on a
    /// timer: a defect doesn't heal with age, but a note the user has since
    /// contradicted should fall off the end naturally.
    static let maxNotesPerItem = 4

    func fetchItemNotes(for itemID: UUID) throws -> [ItemNote] {
        try modelContext.fetch(FetchDescriptor<ItemNote>(
            predicate: #Predicate { $0.itemID == itemID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
    }

    func fetchAllItemNotes() throws -> [UUID: [ItemNote]] {
        let all = try modelContext.fetch(FetchDescriptor<ItemNote>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        ))
        return Dictionary(grouping: all, by: \.itemID)
    }

    @discardableResult
    func addItemNote(itemID: UUID, text: String, severity: ItemNoteSeverity, source: ItemNoteSource, context: ItemNoteContext) throws -> ItemNote? {
        let normalized = ItemNote.normalizedText(text)
        guard !normalized.isEmpty else { return nil }

        // The same complaint tapped twice about the same garment is one note,
        // not two — refresh the existing row instead of duplicating it, so a
        // user who re-taps "Too loose" on a second outfit doesn't end up
        // pushing their other notes off the recency cap below.
        let existing = try fetchItemNotes(for: itemID)
        if let duplicate = existing.first(where: { $0.text.caseInsensitiveCompare(normalized) == .orderedSame }) {
            duplicate.severityRaw = severity.rawValue
            duplicate.contextRaw = context.rawValue
            duplicate.updatedAt = .now
            try modelContext.save()
            AppLog.info(.viewModel, "[ItemNote] refreshed id=\(duplicate.id) item=\(itemID) severity=\(severity.rawValue)")
            return duplicate
        }

        let note = ItemNote(itemID: itemID, text: normalized, severity: severity, source: source, context: context)
        modelContext.insert(note)
        for stale in ([note] + existing).dropFirst(Self.maxNotesPerItem) {
            modelContext.delete(stale)
        }
        // `saveAndMarkMutated`, unlike `SessionSummary` above: notes *are*
        // read on the recommendation path (`WardrobeCatalogBuilder`), so the
        // caches `WardrobeMutationTracker` guards must be invalidated.
        try saveAndMarkMutated()
        AppLog.info(.viewModel, "[ItemNote] added id=\(note.id) item=\(itemID) source=\(source.rawValue) severity=\(severity.rawValue) context=\(context.rawValue)")
        return note
    }

    func updateItemNote(id: UUID, text: String, severity: ItemNoteSeverity) throws {
        let descriptor = FetchDescriptor<ItemNote>(predicate: #Predicate { $0.id == id })
        guard let note = try modelContext.fetch(descriptor).first else { return }
        let normalized = ItemNote.normalizedText(text)
        guard !normalized.isEmpty else { return }

        note.text = normalized
        note.severityRaw = severity.rawValue
        note.sourceRaw = ItemNoteSource.user.rawValue
        note.updatedAt = .now
        try saveAndMarkMutated()
        AppLog.info(.viewModel, "[ItemNote] edited id=\(id) severity=\(severity.rawValue)")
    }

    func deleteItemNote(id: UUID) throws {
        let descriptor = FetchDescriptor<ItemNote>(predicate: #Predicate { $0.id == id })
        guard let note = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(note)
        try saveAndMarkMutated()
        AppLog.info(.viewModel, "[ItemNote] deleted id=\(id)")
    }
}
