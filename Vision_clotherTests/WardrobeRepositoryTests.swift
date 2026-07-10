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
            for: WardrobeItem.self, OutfitFeedback.self, ItemFeedback.self, PairFeedback.self, SavedCombination.self, ItemRating.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return SwiftDataWardrobeRepository(modelContext: ModelContext(container))
    }

    private func makeCombination(assetName: String, savedAt: Date, origin: String = "pairing") -> SavedCombination {
        SavedCombination(
            imageAssetName: assetName,
            topItemID: UUID(),
            bottomItemID: UUID(),
            topLabel: "Solid Neutral Top",
            bottomLabel: "Solid Neutral Bottom",
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

        try repository.recordItemRating(itemID: itemID, fit: .slightlyLoose, comfort: 4, confidence: 5, wearAgain: true)

        let ratings = try repository.fetchItemRatings(for: itemID)
        #expect(ratings.count == 1)
        #expect(ratings.first?.fit == .slightlyLoose)
        #expect(ratings.first?.comfort == 4)
        #expect(ratings.first?.confidence == 5)
        #expect(ratings.first?.wearAgain == true)
    }

    @Test func fetchFeedbackHistoryFoldsRatingsIntoItemPreferenceAndAttributeProfile() throws {
        let repository = try makeRepository()
        let item = makeWardrobeItem(colorVibe: .vibrant)
        try repository.save(item)

        // A strongly positive rating should read as "liked" in itemFeedback
        // and contribute a positive vibrant-color affinity.
        try repository.recordItemRating(itemID: item.id, fit: .justRight, comfort: 5, confidence: 5, wearAgain: true)

        let history = try repository.fetchFeedbackHistory()

        let itemEntry = history.itemFeedback[item.id]
        #expect(itemEntry?.total == 1)
        #expect(itemEntry?.likes == 1)

        #expect(history.attributeProfile.colorVibeAffinity[.vibrant] != nil)
        #expect((history.attributeProfile.colorVibeAffinity[.vibrant] ?? 0) > 0.5)
    }

    @Test func fetchFeedbackHistorySkipsRatingsForDeletedItems() throws {
        let repository = try makeRepository()
        let orphanID = UUID()

        try repository.recordItemRating(itemID: orphanID, fit: .justRight, comfort: 5, confidence: 5, wearAgain: true)

        // No crash and no attribute contribution — the item no longer
        // exists to join attributes from.
        let history = try repository.fetchFeedbackHistory()
        #expect(history.itemFeedback[orphanID]?.total == 1)
    }
}
