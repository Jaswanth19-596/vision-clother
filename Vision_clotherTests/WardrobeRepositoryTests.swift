//
//  WardrobeRepositoryTests.swift
//  Vision_clotherTests
//
//  Covers `SwiftDataWardrobeRepository`'s saved-combination methods (see
//  Data/WardrobeRepository.swift), backing the Combinations tab.
//

import Foundation
import SwiftData
import Testing
@testable import Vision_clother

@MainActor
struct WardrobeRepositoryTests {

    private func makeRepository() throws -> SwiftDataWardrobeRepository {
        let container = try ModelContainer(
            for: WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self,
            ItemRating.self, UserStyleProfile.self, SwipeEvent.self, VisualPreferenceState.self, WardrobeItemEmbedding.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return SwiftDataWardrobeRepository(modelContext: ModelContext(container), embeddingService: MockImageEmbeddingService())
    }

    private func makeCombination(assetName: String, savedAt: Date, origin: String = "pairing") -> SavedCombination {
        SavedCombination(
            imageAssetName: assetName,
            itemIDsBySlot: [.top: UUID(), .bottom: UUID()],
            labelsBySlot: [.top: "Solid Neutral Top", .bottom: "Solid Neutral Bottom"],
            savedAt: savedAt,
            origin: origin
        )
    }

    @Test func saveCombinationPersistsAndFetchReturnsNewestFirst() throws {
        let repository = try makeRepository()
        let older = makeCombination(assetName: "older.png", savedAt: .now.addingTimeInterval(-60))
        let newer = makeCombination(assetName: "newer.png", savedAt: .now)

        try repository.saveCombination(older)
        try repository.saveCombination(newer)

        let fetched = try repository.fetchSavedCombinations()
        #expect(fetched.map(\.imageAssetName) == ["newer.png", "older.png"])
    }

    @Test func deleteCombinationRemovesItAndItsImageFile() throws {
        let repository = try makeRepository()
        let filename = try ImageStorage.save(Data([0x01, 0x02]))
        let combination = makeCombination(assetName: filename, savedAt: .now)
        try repository.saveCombination(combination)

        try repository.deleteCombination(combination)

        #expect(try repository.fetchSavedCombinations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: ImageStorage.url(for: filename).path))
    }

    // MARK: - Item Rating & Preference Learning

    private func makeWardrobeItem(colorVibe: ColorVibe = .vibrant, pattern: GarmentPattern = .solid) -> WardrobeItem {
        WardrobeItem(
            slot: .top,
            formalityScore: 2.0,
            colorProfile: ColorProfile(primaryHex: "#FFFFFF", secondaryHex: nil, category: colorVibe),
            pattern: pattern,
            seasonality: Season.allCases,
            fabricWeight: .light
        )
    }

    @Test func recordItemRatingRoundTrips() throws {
        let repository = try makeRepository()
        let itemID = UUID()

        try repository.recordItemRating(
            itemID: itemID, fit: .slightlyLoose, comfort: 4, confidence: 5, wearAgain: true,
            versatility: 5, frequency: 2, styleIdentity: 4, qualityPerception: 3
        )

        let ratings = try repository.fetchItemRatings(for: itemID)
        #expect(ratings.count == 1)
        #expect(ratings.first?.fit == .slightlyLoose)
        #expect(ratings.first?.comfort == 4)
        #expect(ratings.first?.confidence == 5)
        #expect(ratings.first?.wearAgain == true)
        #expect(ratings.first?.versatility == 5)
        #expect(ratings.first?.frequency == 2)
        #expect(ratings.first?.styleIdentity == 4)
        #expect(ratings.first?.qualityPerception == 3)
    }

    @Test func fetchFeedbackHistoryFoldsRatingsIntoItemPreferenceAndAttributeProfile() async throws {
        let repository = try makeRepository()
        let item = makeWardrobeItem(colorVibe: .vibrant)
        try repository.save(item)

        // A strongly positive rating should read as "liked" in itemFeedback
        // and contribute a positive vibrant-color affinity.
        try repository.recordItemRating(
            itemID: item.id, fit: .justRight, comfort: 5, confidence: 5, wearAgain: true,
            versatility: 5, frequency: 5, styleIdentity: 5, qualityPerception: 5
        )

        let history = try await repository.fetchFeedbackHistory()

        let itemEntry = history.itemFeedback[item.id]
        #expect(abs((itemEntry?.total ?? 0) - 1) < 0.01)
        #expect(abs((itemEntry?.likes ?? 0) - 1) < 0.01)

        #expect(history.attributeProfile.colorVibeAffinity[.vibrant] != nil)
        #expect((history.attributeProfile.colorVibeAffinity[.vibrant] ?? 0) > 0.5)
    }

    @Test func fetchFeedbackHistoryFoldsItemLevelStyleIdentityIntoStyleTagAffinity() async throws {
        let repository = try makeRepository()
        let item = WardrobeItem(
            slot: .top,
            formalityScore: 2.0,
            colorProfile: ColorProfile(primaryHex: "#FFFFFF", secondaryHex: nil, category: .neutral),
            pattern: .solid,
            seasonality: Season.allCases,
            fabricWeight: .light,
            styleTags: ["minimalist"]
        )
        try repository.save(item)

        // A high Style Identity rating ("does this feel like you") should
        // contribute a positive affinity for the item's style tag — the
        // same channel the outfit-level Personal Style Match question feeds.
        try repository.recordItemRating(
            itemID: item.id, fit: .justRight, comfort: 3, confidence: 3, wearAgain: true,
            versatility: 3, frequency: 3, styleIdentity: 5, qualityPerception: 3
        )

        let history = try await repository.fetchFeedbackHistory()

        #expect(history.attributeProfile.styleTagAffinity["minimalist"] != nil)
        #expect((history.attributeProfile.styleTagAffinity["minimalist"] ?? 0) > 0.5)
    }

    // MARK: - User Style Profile (PRD §3.8)

    private func makeProfileWire(bodyType: String = "athletic build") -> UserStyleProfileWire {
        UserStyleProfileWire(
            skinTone: "medium, warm olive",
            undertone: .warm,
            bodyType: bodyType,
            styleKeywords: ["classic"],
            recommendedColors: ["#8A5A44"],
            avoidColors: ["#B983FF"]
        )
    }

    @Test func fetchUserProfileReturnsNilWhenNeverDerived() throws {
        let repository = try makeRepository()
        #expect(try repository.fetchUserProfile() == nil)
    }

    @Test func saveUserProfilePersistsAndFetchReturnsIt() throws {
        let repository = try makeRepository()
        try repository.saveUserProfile(makeProfileWire())

        let fetched = try repository.fetchUserProfile()
        #expect(fetched?.bodyType == "athletic build")
        #expect(fetched?.undertone == .warm)
        #expect(fetched?.styleKeywords == ["classic"])
    }

    @Test func savingAProfileTwiceUpsertsRatherThanAccumulating() throws {
        let container = try ModelContainer(
            for: WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self,
            ItemRating.self, UserStyleProfile.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let modelContext = ModelContext(container)
        let repository = SwiftDataWardrobeRepository(modelContext: modelContext)

        try repository.saveUserProfile(makeProfileWire(bodyType: "athletic build"))
        try repository.saveUserProfile(makeProfileWire(bodyType: "slim build"))

        // Single-row upsert: exactly one profile row should exist, and it
        // must be the most recent derivation.
        let allProfiles = try modelContext.fetch(FetchDescriptor<UserStyleProfile>())
        #expect(allProfiles.count == 1)
        #expect(allProfiles.first?.bodyType == "slim build")
    }

    @Test func fetchFeedbackHistorySkipsRatingsForDeletedItems() async throws {
        let repository = try makeRepository()
        let orphanID = UUID()

        try repository.recordItemRating(
            itemID: orphanID, fit: .justRight, comfort: 5, confidence: 5, wearAgain: true,
            versatility: 3, frequency: 3, styleIdentity: 3, qualityPerception: 3
        )

        // No crash and no attribute contribution — the item no longer
        // exists to join attributes from.
        let history = try await repository.fetchFeedbackHistory()
        #expect(abs((history.itemFeedback[orphanID]?.total ?? 0) - 1) < 0.01)
    }

    // MARK: - Stylist Intelligence Engine Phase 1: dimension-based outfit rating

    private func makeSubmission(
        overallSatisfaction: Int = 5,
        wearAgain: WearAgainAnswer = .yes,
        confidence: Int = 5,
        comfort: Int = 5,
        occasionMatch: Int = 5,
        styleMatch: Int = 5,
        colorHarmony: Int = 5,
        silhouette: Int = 5,
        weatherSuitability: Int = 5,
        practicality: Int = 5,
        favoriteItemID: UUID? = nil,
        weakestItemID: UUID? = nil
    ) -> OutfitRatingSubmission {
        OutfitRatingSubmission(
            overallSatisfaction: overallSatisfaction, wearAgain: wearAgain, confidence: confidence, comfort: comfort,
            occasionMatch: occasionMatch, styleMatch: styleMatch, colorHarmony: colorHarmony, silhouette: silhouette,
            weatherSuitability: weatherSuitability, practicality: practicality,
            favoriteItemID: favoriteItemID, weakestItemID: weakestItemID
        )
    }

    @Test func recordOutfitRatingRoundTripsAndDerivesLikedOverall() throws {
        let repository = try makeRepository()
        let combination = makeCombination(assetName: "outfit.png", savedAt: .now)
        try repository.saveCombination(combination)

        try repository.recordOutfitRating(outfitID: combination.id, submission: makeSubmission())

        let feedback = try repository.fetchOutfitFeedback(for: combination.id)
        #expect(feedback.count == 1)
        #expect(feedback.first?.likedOverall == true)
        #expect(feedback.first?.wearAgain == .yes)
        #expect(feedback.first?.overallSatisfaction == 5)
    }

    @Test func favoriteAndWeakestItemFoldIntoItemPreferenceChannel() async throws {
        let repository = try makeRepository()
        let combination = makeCombination(assetName: "outfit.png", savedAt: .now)
        try repository.saveCombination(combination)
        let favoriteID = UUID()
        let weakestID = UUID()

        try repository.recordOutfitRating(
            outfitID: combination.id,
            submission: makeSubmission(favoriteItemID: favoriteID, weakestItemID: weakestID)
        )

        let history = try await repository.fetchFeedbackHistory()
        #expect(abs((history.itemFeedback[favoriteID]?.total ?? 0) - 1) < 0.01)
        #expect(abs((history.itemFeedback[favoriteID]?.likes ?? 0) - 1) < 0.01)
        #expect(abs((history.itemFeedback[weakestID]?.total ?? 0) - 1) < 0.01)
        #expect(abs((history.itemFeedback[weakestID]?.likes ?? 0) - 0) < 0.01)
    }

    @Test func detailedOutfitRatingJoinsRealItemsIntoAttributeProfile() async throws {
        let repository = try makeRepository()
        let top = makeWardrobeItem(colorVibe: .vibrant)
        try repository.save(top)
        let combination = SavedCombination(
            imageAssetName: "outfit.png",
            itemIDsBySlot: [.top: top.id, .bottom: UUID()],
            labelsBySlot: [.top: "top", .bottom: "bottom"],
            origin: "pairing"
        )
        try repository.saveCombination(combination)

        try repository.recordOutfitRating(
            outfitID: combination.id,
            submission: makeSubmission(occasionMatch: 5, colorHarmony: 5)
        )

        let history = try await repository.fetchFeedbackHistory()
        #expect((history.attributeProfile.colorVibeAffinity[.vibrant] ?? 0) > 0.5)
    }

    @Test func dislikedSavedCombinationPopulatesOutfitNegativeSignalByExactItemSet() async throws {
        // Read Disliked Signals (2026-07-11): a freshly generated
        // OutfitCombination has no durable id of its own, so whole-outfit
        // dislike history must be matched by which items it contains.
        let repository = try makeRepository()
        let topID = UUID()
        let bottomID = UUID()
        let combination = SavedCombination(
            imageAssetName: "outfit.png",
            itemIDsBySlot: [.top: topID, .bottom: bottomID],
            labelsBySlot: [.top: "top", .bottom: "bottom"],
            origin: "pairing"
        )
        try repository.saveCombination(combination)
        try repository.recordOutfitFeedback(outfitID: combination.id, likedOverall: false)

        let history = try await repository.fetchFeedbackHistory()

        let itemSet = Set([topID, bottomID])
        #expect((history.outfitNegativeSignalByItemSet[itemSet] ?? 0) > 0)
        // A different item set must not pick up any signal.
        #expect(history.outfitNegativeSignalByItemSet[Set([UUID(), UUID()])] == nil)
    }

    @Test func likedSavedCombinationDoesNotPopulateOutfitNegativeSignal() async throws {
        let repository = try makeRepository()
        let combination = makeCombination(assetName: "outfit.png", savedAt: .now)
        try repository.saveCombination(combination)
        try repository.recordOutfitFeedback(outfitID: combination.id, likedOverall: true)

        let history = try await repository.fetchFeedbackHistory()

        let itemSet = Set(combination.itemIDsBySlot.values)
        #expect((history.outfitNegativeSignalByItemSet[itemSet] ?? 0) <= 0)
    }

    @Test func dislikedItemFeedbackPopulatesItemNegativeSignal() async throws {
        let repository = try makeRepository()
        let itemID = UUID()
        try repository.recordItemFeedback(itemID: itemID, likedFit: false)

        let history = try await repository.fetchFeedbackHistory()

        #expect((history.itemNegativeSignal[itemID] ?? 0) > 0)
    }

    @Test func simpleAutoRecordedOutfitFeedbackDoesNotContributeToAttributeProfile() async throws {
        let repository = try makeRepository()
        try repository.recordOutfitFeedback(outfitID: UUID(), likedOverall: true)

        // No detailed fields, so `normalizedRating` is `nil` and this event
        // is excluded from the attribute-profile join — no crash, no bias.
        let history = try await repository.fetchFeedbackHistory()
        #expect(history.attributeProfile.colorVibeAffinity.isEmpty)
    }

    // MARK: - Swipe-to-Learn Visual Taste (added 2026-07-14)

    @Test func fetchVisualPreferenceStateIsNilBeforeAnySwipe() throws {
        let repository = try makeRepository()
        #expect(try repository.fetchVisualPreferenceState() == nil)
    }

    @Test func recordSwipePersistsEventAndUpdatesVisualPreferenceState() throws {
        let repository = try makeRepository()
        try repository.recordSwipe(sourcePhotoID: "p1", imageURLString: "https://example.com/p1.jpg", liked: true, embedding: [1, 0, 0])

        let state = try repository.fetchVisualPreferenceState()
        #expect(state?.likedCentroids.count == 1)
        #expect(state?.likedCentroids.first?.weight == 1)
        #expect(state?.dislikedCentroids.isEmpty == true)
    }

    @Test func recordSwipeAccumulatesAcrossMultipleCalls() throws {
        let repository = try makeRepository()
        try repository.recordSwipe(sourcePhotoID: "p1", imageURLString: "https://example.com/p1.jpg", liked: true, embedding: [1, 0, 0])
        try repository.recordSwipe(sourcePhotoID: "p2", imageURLString: "https://example.com/p2.jpg", liked: false, embedding: [0, 1, 0])

        let state = try repository.fetchVisualPreferenceState()
        #expect(state?.likedCentroids.count == 1)
        #expect(state?.dislikedCentroids.count == 1)
    }

    @Test func updateVisualPreferenceStateUpsertsRatherThanAccumulating() throws {
        let repository = try makeRepository()
        try repository.updateVisualPreferenceState(
            likedCentroids: [VisualCentroid(vector: [1, 0, 0], weight: 1)],
            dislikedCentroids: [],
            embeddingDimension: 3
        )
        try repository.updateVisualPreferenceState(
            likedCentroids: [VisualCentroid(vector: [0, 1, 0], weight: 2)],
            dislikedCentroids: [VisualCentroid(vector: [0, 0, 1], weight: 1)],
            embeddingDimension: 3
        )

        let state = try repository.fetchVisualPreferenceState()
        #expect(state?.likedCentroids.count == 1)
        #expect(state?.likedCentroids.first?.vector == [0, 1, 0])
        #expect(state?.dislikedCentroids.count == 1)
    }

    @Test func wardrobeItemEmbeddingRoundTripsThroughSaveAndFetch() throws {
        let repository = try makeRepository()
        let itemID = UUID()
        try repository.saveWardrobeItemEmbedding(itemID: itemID, vector: [1, 0, 0], sourceFingerprint: "abc123")

        let fetched = try repository.fetchWardrobeItemEmbedding(itemID: itemID)
        #expect(fetched?.vector == [1, 0, 0])
        #expect(fetched?.sourceFingerprint == "abc123")
    }

    @Test func savingAWardrobeItemEmbeddingTwiceUpsertsRatherThanAccumulating() throws {
        let repository = try makeRepository()
        let itemID = UUID()
        try repository.saveWardrobeItemEmbedding(itemID: itemID, vector: [1, 0, 0], sourceFingerprint: "v1")
        try repository.saveWardrobeItemEmbedding(itemID: itemID, vector: [0, 1, 0], sourceFingerprint: "v2")

        let fetched = try repository.fetchWardrobeItemEmbedding(itemID: itemID)
        #expect(fetched?.vector == [0, 1, 0])
        #expect(fetched?.sourceFingerprint == "v2")
    }

    @Test func fetchFeedbackHistoryPopulatesItemEmbeddingsForItemsWithAPhoto() async throws {
        let repository = try makeRepository()
        let assetName = try ImageStorage.save(Data([0xAA, 0xBB, 0xCC]))
        let item = makeWardrobeItem()
        item.imageAssetName = assetName
        try repository.save(item)

        let history = try await repository.fetchFeedbackHistory()
        #expect(history.itemEmbeddings[item.id] != nil)
    }

    @Test func fetchFeedbackHistorySkipsEmbeddingsForItemsWithNoPhoto() async throws {
        let repository = try makeRepository()
        let item = makeWardrobeItem() // no imageAssetName
        try repository.save(item)

        let history = try await repository.fetchFeedbackHistory()
        #expect(history.itemEmbeddings[item.id] == nil)
    }

    @Test func fetchFeedbackHistoryReusesCachedEmbeddingWhenFingerprintMatches() async throws {
        let repository = try makeRepository()
        let assetName = try ImageStorage.save(Data([0xAA, 0xBB, 0xCC]))
        let item = makeWardrobeItem()
        item.imageAssetName = assetName
        try repository.save(item)

        _ = try await repository.fetchFeedbackHistory()
        // Overwrite the cache with a sentinel vector distinguishable from
        // whatever the mock embedding service would compute fresh — if the
        // second fetch reuses the cache (fingerprint unchanged), this
        // sentinel survives; if it recomputes, it's overwritten.
        let fingerprint = ImageStorage.fingerprint(Data([0xAA, 0xBB, 0xCC]))
        try repository.saveWardrobeItemEmbedding(itemID: item.id, vector: [9, 9, 9], sourceFingerprint: fingerprint)

        let history = try await repository.fetchFeedbackHistory()
        #expect(history.itemEmbeddings[item.id] == [9, 9, 9])
    }

    @Test func fetchFeedbackHistoryPopulatesVisualProfileFromPersistedState() async throws {
        let repository = try makeRepository()
        try repository.recordSwipe(sourcePhotoID: "p1", imageURLString: "https://example.com/p1.jpg", liked: true, embedding: [1, 0, 0])

        let history = try await repository.fetchFeedbackHistory()
        #expect(history.visualProfile.likedCentroids.count == 1)
    }
}
