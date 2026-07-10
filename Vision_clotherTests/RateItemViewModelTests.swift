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

        await viewModel.submit()

        #expect(viewModel.state == .saved)
        #expect(repository.recordedRatings.count == 1)
        let recorded = repository.recordedRatings.first
        #expect(recorded?.itemID == item.id)
        #expect(recorded?.fit == .slightlyTight)
        #expect(recorded?.comfort == 2)
        #expect(recorded?.confidence == 4)
        #expect(recorded?.wearAgain == false)
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
        #expect(viewModel.state == .idle)
    }
}

// MARK: - Test doubles

private struct RecordRatingError: Error {}

@MainActor
private final class InMemoryWardrobeRepository: WardrobeRepository {
    var savedItems: [WardrobeItem] = []
    var shouldThrowOnRecordRating = false
    private(set) var recordedRatings: [(itemID: UUID, fit: FitRating, comfort: Int, confidence: Int, wearAgain: Bool)] = []

    func fetchInventory() throws -> [WardrobeItem] { savedItems }
    func save(_ item: WardrobeItem) throws { savedItems.append(item) }
    func delete(_ item: WardrobeItem) throws { savedItems.removeAll { $0.id == item.id } }
    func fetchFeedbackHistory() throws -> FeedbackHistory { FeedbackHistory() }

    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {}
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {}
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {}

    func recordItemRating(itemID: UUID, fit: FitRating, comfort: Int, confidence: Int, wearAgain: Bool) throws {
        if shouldThrowOnRecordRating { throw RecordRatingError() }
        recordedRatings.append((itemID, fit, comfort, confidence, wearAgain))
    }
    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] { [] }

    func fetchSavedCombinations() throws -> [SavedCombination] { [] }
    func saveCombination(_ combination: SavedCombination) throws {}
    func deleteCombination(_ combination: SavedCombination) throws {}
}
