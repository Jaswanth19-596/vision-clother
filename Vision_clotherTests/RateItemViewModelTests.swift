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
        viewModel.colorLike = 4
        viewModel.patternLike = 1
        viewModel.formalityFit = 4
        viewModel.styleIdentity = 4
        viewModel.wearAgain = false

        await viewModel.submit()

        #expect(viewModel.state == .saved)
        #expect(repository.recordedRatings.count == 1)
        let recorded = repository.recordedRatings.first
        #expect(recorded?.itemID == item.id)
        #expect(recorded?.fit == .slightlyTight)
        #expect(recorded?.comfort == 2)
        #expect(recorded?.colorLike == 4)
        // `makeItem()` uses `.solid`, so the Pattern question is skipped —
        // `patternLike` must be submitted as `nil` regardless of the bound
        // control's leftover value.
        #expect(recorded?.patternLike == nil)
        #expect(recorded?.formalityFit == 4)
        #expect(recorded?.styleIdentity == 4)
        #expect(recorded?.wearAgain == false)
    }

    @Test func submitSubmitsPatternLikeForANonSolidItem() async throws {
        let repository = InMemoryWardrobeRepository()
        let item = WardrobeItem(
            slot: .top,
            formalityScore: 2.0,
            colorProfile: ColorProfile(primaryHex: "#FFFFFF", secondaryHex: nil, category: .neutral),
            pattern: .striped,
            seasonality: Season.allCases,
            fabricWeight: .light
        )
        let viewModel = RateItemViewModel(item: item, repository: repository)
        viewModel.patternLike = 5

        await viewModel.submit()

        #expect(repository.recordedRatings.first?.patternLike == 5)
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
        #expect(viewModel.colorLike == 3)
        #expect(viewModel.patternLike == 3)
        #expect(viewModel.formalityFit == 3)
        #expect(viewModel.styleIdentity == 3)
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
    private(set) var recordedRatings: [(itemID: UUID, fit: FitRating, comfort: Int, colorLike: Int, patternLike: Int?, formalityFit: Int, styleIdentity: Int, wearAgain: Bool)] = []

    func fetchInventory() throws -> [WardrobeItem] { savedItems }
    func save(_ item: WardrobeItem) throws { savedItems.append(item) }
    func update(_ item: WardrobeItem) throws {}
    func delete(_ item: WardrobeItem) throws { savedItems.removeAll { $0.id == item.id } }
    func fetchFeedbackHistory() async throws -> FeedbackHistory { FeedbackHistory() }

    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {}
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {}
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {}

    func recordItemRating(itemID: UUID, fit: FitRating, comfort: Int, colorLike: Int, patternLike: Int?, formalityFit: Int, styleIdentity: Int, wearAgain: Bool) throws {
        if shouldThrowOnRecordRating { throw RecordRatingError() }
        recordedRatings.append((itemID, fit, comfort, colorLike, patternLike, formalityFit, styleIdentity, wearAgain))
    }
    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] { [] }
    func recordOutfitRating(outfitID: UUID, submission: OutfitRatingSubmission) throws {}
    func fetchOutfitFeedback(for outfitID: UUID) throws -> [OutfitFeedback] { [] }

    func fetchSavedCombinations() throws -> [SavedCombination] { [] }
    func saveCombination(_ combination: SavedCombination) throws {}
    func deleteCombination(_ combination: SavedCombination) throws {}

    func fetchUserProfile() throws -> UserStyleProfile? { nil }
    func saveUserProfile(_ wire: UserStyleProfileWire) throws {}
    func recordSwipe(sourcePhotoID: String, imageURLString: String, liked: Bool, embedding: [Float]) throws -> Double? { nil }
    func fetchVisualPreferenceState() throws -> VisualPreferenceState? { nil }
    func updateVisualPreferenceState(likedCentroids: [VisualCentroid], dislikedCentroids: [VisualCentroid], embeddingDimension: Int) throws {}
    func fetchWardrobeItemEmbedding(itemID: UUID) throws -> WardrobeItemEmbedding? { nil }
    func saveWardrobeItemEmbedding(itemID: UUID, vector: [Float], sourceFingerprint: String) throws {}
}
