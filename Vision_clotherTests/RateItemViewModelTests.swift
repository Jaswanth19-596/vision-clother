//
//  RateItemViewModelTests.swift
//  Vision_clotherTests
//
//  Covers Item Rating & Preference Learning's save flow (see
//  Features/Rating/RateItemViewModel.swift): a successful submit reaches
//  `.saved` and persists the exact question answers; a repository failure
//  surfaces as `.failed` without crashing.
//

import Foundation
import Testing
@testable import Vision_clother

@MainActor
struct RateItemViewModelTests {

    private func makeItem() -> WardrobeItem {
        WardrobeItem(
            slot: .top,
            formalityScore: 2.0,
            colorProfile: ColorProfile(primaryHex: "#FFFFFF", secondaryHex: nil, category: .neutral),
            pattern: .solid,
            seasonality: Season.allCases,
            fabricWeight: .light
        )
    }

    @Test func submitSuccessReachesSavedAndPersistsTheAnswers() async throws {
        let repository = InMemoryWardrobeRepository()
        let item = makeItem()
        let viewModel = RateItemViewModel(item: item, repository: repository)
        viewModel.fit = .slightlyTight
        viewModel.comfort = 2
        viewModel.confidence = 4
        viewModel.wearAgain = false
        viewModel.versatility = 5
        viewModel.frequency = 1
        viewModel.styleIdentity = 4
        viewModel.qualityPerception = 2

        await viewModel.submit()

        #expect(viewModel.state == .saved)
        #expect(repository.recordedRatings.count == 1)
        let recorded = repository.recordedRatings.first
        #expect(recorded?.itemID == item.id)
        #expect(recorded?.fit == .slightlyTight)
        #expect(recorded?.comfort == 2)
        #expect(recorded?.confidence == 4)
        #expect(recorded?.wearAgain == false)
        #expect(recorded?.versatility == 5)
        #expect(recorded?.frequency == 1)
        #expect(recorded?.styleIdentity == 4)
        #expect(recorded?.qualityPerception == 2)
    }

    @Test func submitFailureSurfacesAsFailedWithoutCrashing() async throws {
        let repository = InMemoryWardrobeRepository()
        repository.shouldThrowOnRecordRating = true
        let viewModel = RateItemViewModel(item: makeItem(), repository: repository)

        await viewModel.submit()

        guard case .failed = viewModel.state else {
            Issue.record("Expected .failed, got \(viewModel.state)")
            return
        }
    }

    @Test func defaultsAreNeutralBeforeAnyInput() {
        let viewModel = RateItemViewModel(item: makeItem(), repository: InMemoryWardrobeRepository())

        #expect(viewModel.fit == .justRight)
        #expect(viewModel.comfort == 3)
        #expect(viewModel.confidence == 3)
        #expect(viewModel.wearAgain == true)
        #expect(viewModel.versatility == 3)
        #expect(viewModel.frequency == 3)
        #expect(viewModel.styleIdentity == 3)
        #expect(viewModel.qualityPerception == 3)
        #expect(viewModel.state == .idle)
    }
}

// MARK: - Test doubles

private struct RecordRatingError: Error {}

@MainActor
private final class InMemoryWardrobeRepository: WardrobeRepository {
    var savedItems: [WardrobeItem] = []
    var shouldThrowOnRecordRating = false
    private(set) var recordedRatings: [(itemID: UUID, fit: FitRating, comfort: Int, confidence: Int, wearAgain: Bool, versatility: Int, frequency: Int, styleIdentity: Int, qualityPerception: Int)] = []

    func fetchInventory() throws -> [WardrobeItem] { savedItems }
    func save(_ item: WardrobeItem) throws { savedItems.append(item) }
    func delete(_ item: WardrobeItem) throws { savedItems.removeAll { $0.id == item.id } }
    func fetchFeedbackHistory() throws -> FeedbackHistory { FeedbackHistory() }

    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {}
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {}
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {}

    func recordItemRating(itemID: UUID, fit: FitRating, comfort: Int, confidence: Int, wearAgain: Bool, versatility: Int, frequency: Int, styleIdentity: Int, qualityPerception: Int) throws {
        if shouldThrowOnRecordRating { throw RecordRatingError() }
        recordedRatings.append((itemID, fit, comfort, confidence, wearAgain, versatility, frequency, styleIdentity, qualityPerception))
    }
    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] { [] }
    func recordOutfitRating(outfitID: UUID, submission: OutfitRatingSubmission) throws {}
    func fetchOutfitFeedback(for outfitID: UUID) throws -> [OutfitFeedback] { [] }

    func fetchSavedCombinations() throws -> [SavedCombination] { [] }
    func saveCombination(_ combination: SavedCombination) throws {}
    func deleteCombination(_ combination: SavedCombination) throws {}

    func fetchUserProfile() throws -> UserStyleProfile? { nil }
    func saveUserProfile(_ wire: UserStyleProfileWire) throws {}
}
