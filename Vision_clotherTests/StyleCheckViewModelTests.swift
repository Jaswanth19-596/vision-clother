//
//  StyleCheckViewModelTests.swift
//  Vision_clotherTests
//
//  Covers `StyleCheckViewModel` (Features/Profile/) — the "Test Your Style"
//  manual verification tool. Mirrors `SwipeDiscoveryViewModelTests.swift`'s
//  in-memory repository double pattern.
//

import Foundation
import Testing
@testable import Vision_clother

@MainActor
struct StyleCheckViewModelTests {

    @Test func checkPhotoReportsNotEnoughDataWhenNoVisualPreferenceStateExists() async {
        let repository = InMemoryStyleCheckRepository(stateToReturn: nil)
        let viewModel = StyleCheckViewModel(
            repository: repository, embeddingService: MockImageEmbeddingService(vectorToReturn: [1, 0, 0])
        )

        await viewModel.checkPhoto(Data([0x01]))

        guard case .result(let result) = viewModel.state else {
            Issue.record("Expected .result state")
            return
        }
        #expect(result.verdict == .notEnoughData)
        #expect(result.detail == nil)
    }

    @Test func checkPhotoMatchesStyleWhenCloseToALikedCentroid() async {
        let state = VisualPreferenceState(
            likedCentroids: [VisualCentroid(vector: [1, 0, 0], weight: 5)],
            dislikedCentroids: [], totalSwipes: 20
        )
        let repository = InMemoryStyleCheckRepository(stateToReturn: state)
        let viewModel = StyleCheckViewModel(
            repository: repository, embeddingService: MockImageEmbeddingService(vectorToReturn: [1, 0, 0])
        )

        await viewModel.checkPhoto(Data([0x01]))

        guard case .result(let result) = viewModel.state else {
            Issue.record("Expected .result state")
            return
        }
        #expect(result.verdict == .matchesStyle)
        #expect((result.detail?.bonus ?? 0) > 0)
        #expect(result.isTrained == true)
    }

    @Test func checkPhotoReportsNotYourStyleWhenCloseToADislikedCentroid() async {
        let state = VisualPreferenceState(
            likedCentroids: [], dislikedCentroids: [VisualCentroid(vector: [1, 0, 0], weight: 5)]
        )
        let repository = InMemoryStyleCheckRepository(stateToReturn: state)
        let viewModel = StyleCheckViewModel(
            repository: repository, embeddingService: MockImageEmbeddingService(vectorToReturn: [1, 0, 0])
        )

        await viewModel.checkPhoto(Data([0x01]))

        guard case .result(let result) = viewModel.state else {
            Issue.record("Expected .result state")
            return
        }
        #expect(result.verdict == .notYourStyle)
        #expect((result.detail?.bonus ?? 0) < 0)
    }

    @Test func checkPhotoReportsMixedSignalsWhenNoCentroidPullsStrongly() async {
        // Orthogonal to both centroids -> near-zero bonus, below the verdict
        // threshold on either side.
        let state = VisualPreferenceState(
            likedCentroids: [VisualCentroid(vector: [1, 0, 0], weight: 5)],
            dislikedCentroids: [VisualCentroid(vector: [0, 1, 0], weight: 5)]
        )
        let repository = InMemoryStyleCheckRepository(stateToReturn: state)
        let viewModel = StyleCheckViewModel(
            repository: repository, embeddingService: MockImageEmbeddingService(vectorToReturn: [0, 0, 1])
        )

        await viewModel.checkPhoto(Data([0x01]))

        guard case .result(let result) = viewModel.state else {
            Issue.record("Expected .result state")
            return
        }
        #expect(result.verdict == .mixedSignals)
    }

    @Test func checkPhotoFailsGracefullyWhenEmbeddingThrows() async {
        let repository = InMemoryStyleCheckRepository(stateToReturn: nil)
        let viewModel = StyleCheckViewModel(
            repository: repository,
            embeddingService: MockImageEmbeddingService(errorToThrow: .invalidImage)
        )

        await viewModel.checkPhoto(Data([0x01]))

        guard case .failed = viewModel.state else {
            Issue.record("Expected .failed state")
            return
        }
    }

    @Test func checkPhotoTransitionsThroughAnalyzingState() async {
        let repository = InMemoryStyleCheckRepository(stateToReturn: nil)
        let viewModel = StyleCheckViewModel(
            repository: repository, embeddingService: MockImageEmbeddingService(vectorToReturn: [1, 0, 0])
        )
        #expect(viewModel.state == .idle)

        await viewModel.checkPhoto(Data([0x01]))

        // By the time the (synchronous mock) await completes, state has moved
        // past .analyzing — this just confirms it didn't stay .idle.
        #expect(viewModel.state != .idle)
    }

    @Test func resetReturnsStateToIdle() async {
        let repository = InMemoryStyleCheckRepository(stateToReturn: nil)
        let viewModel = StyleCheckViewModel(
            repository: repository, embeddingService: MockImageEmbeddingService(vectorToReturn: [1, 0, 0])
        )
        await viewModel.checkPhoto(Data([0x01]))

        viewModel.reset()

        #expect(viewModel.state == .idle)
    }
}

// MARK: - Test doubles

@MainActor
private final class InMemoryStyleCheckRepository: WardrobeRepository {
    private let stateToReturn: VisualPreferenceState?

    init(stateToReturn: VisualPreferenceState?) {
        self.stateToReturn = stateToReturn
    }

    func fetchInventory() throws -> [WardrobeItem] { [] }
    func save(_ item: WardrobeItem) throws {}
    func update(_ item: WardrobeItem) throws {}
    func delete(_ item: WardrobeItem) throws {}
    func fetchFeedbackHistory() async throws -> FeedbackHistory { FeedbackHistory() }
    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {}
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {}
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {}
    func recordItemRating(itemID: UUID, fit: FitRating, comfort: Int, colorLike: Int, patternLike: Int?, formalityFit: Int, styleIdentity: Int, wearAgain: Bool) throws {}
    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] { [] }
    func recordOutfitRating(outfitID: UUID, submission: OutfitRatingSubmission) throws {}
    func fetchOutfitFeedback(for outfitID: UUID) throws -> [OutfitFeedback] { [] }
    func fetchSavedCombinations() throws -> [SavedCombination] { [] }
    func saveCombination(_ combination: SavedCombination) throws {}
    func deleteCombination(_ combination: SavedCombination) throws {}
    func fetchUserProfile() throws -> UserStyleProfile? { nil }
    func saveUserProfile(_ wire: UserStyleProfileWire) throws {}
    func recordSwipe(sourcePhotoID: String, imageURLString: String, liked: Bool, embedding: [Float]) throws -> Double? { nil }
    func fetchVisualPreferenceState() throws -> VisualPreferenceState? { stateToReturn }
    func updateVisualPreferenceState(likedCentroids: [VisualCentroid], dislikedCentroids: [VisualCentroid], embeddingDimension: Int) throws {}
    func fetchWardrobeItemEmbedding(itemID: UUID) throws -> WardrobeItemEmbedding? { nil }
    func saveWardrobeItemEmbedding(itemID: UUID, vector: [Float], sourceFingerprint: String) throws {}
}
