//
//  SwipeDiscoveryViewModelTests.swift
//  Vision_clotherTests
//
//  Covers `SwipeDiscoveryViewModel` (Features/SwipeDiscovery/) — deck
//  loading/refill and the swipe-then-persist flow. Mirrors
//  `RateItemViewModelTests.swift`'s in-memory repository double pattern.
//  Network calls in `persistSwipe` are intercepted by a stub `URLProtocol`
//  so these tests never touch the real network.
//

import Foundation
import Testing
@testable import Vision_clother

@MainActor
struct SwipeDiscoveryViewModelTests {

    private func makePhotos(count: Int) -> [StockPhoto] {
        (0..<count).map { i in
            StockPhoto(
                id: "photo-\(i)",
                imageURLString: "https://stub.test/photo-\(i).jpg",
                photographerName: "Test Photographer",
                photographerURLString: nil
            )
        }
    }

    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func loadDeckIfNeededPopulatesDeckFromFeedService() async {
        let repository = InMemoryWardrobeRepository()
        let feedService = MockStockImageFeedService(photosToReturn: makePhotos(count: 5))
        let viewModel = SwipeDiscoveryViewModel(
            repository: repository, feedService: feedService, embeddingService: MockImageEmbeddingService()
        )

        await viewModel.loadDeckIfNeeded()

        #expect(viewModel.deck.count == 5)
        #expect(viewModel.loadState == .loaded)
    }

    @Test func loadDeckIfNeededIsANoOpWhenDeckAlreadyHasCards() async {
        let repository = InMemoryWardrobeRepository()
        let feedService = MockStockImageFeedService(photosToReturn: makePhotos(count: 3))
        let viewModel = SwipeDiscoveryViewModel(
            repository: repository, feedService: feedService, embeddingService: MockImageEmbeddingService()
        )

        await viewModel.loadDeckIfNeeded()
        await viewModel.loadDeckIfNeeded()

        #expect(viewModel.deck.count == 3)
    }

    @Test func loadDeckSetsFailedStateWhenFeedServiceThrows() async {
        let repository = InMemoryWardrobeRepository()
        let feedService = MockStockImageFeedService(errorToThrow: .missingAPIKey)
        let viewModel = SwipeDiscoveryViewModel(
            repository: repository, feedService: feedService, embeddingService: MockImageEmbeddingService()
        )

        await viewModel.loadDeckIfNeeded()

        guard case .failed = viewModel.loadState else {
            Issue.record("Expected .failed load state")
            return
        }
        #expect(viewModel.deck.isEmpty)
    }

    @Test func swipePopsTheTopCardImmediately() async {
        let repository = InMemoryWardrobeRepository()
        let feedService = MockStockImageFeedService(photosToReturn: makePhotos(count: 3))
        let viewModel = SwipeDiscoveryViewModel(
            repository: repository, feedService: feedService,
            embeddingService: MockImageEmbeddingService(), session: makeStubbedSession()
        )
        await viewModel.loadDeckIfNeeded()
        let topBefore = viewModel.topPhoto

        viewModel.swipe(liked: true)

        #expect(viewModel.deck.count == 2)
        #expect(viewModel.topPhoto?.id != topBefore?.id)
    }

    @Test func swipeEventuallyRecordsALikeThroughTheRepository() async throws {
        let repository = InMemoryWardrobeRepository()
        let feedService = MockStockImageFeedService(photosToReturn: makePhotos(count: 1))
        let viewModel = SwipeDiscoveryViewModel(
            repository: repository, feedService: feedService,
            embeddingService: MockImageEmbeddingService(vectorToReturn: [1, 0, 0]),
            session: makeStubbedSession()
        )
        await viewModel.loadDeckIfNeeded()

        viewModel.swipe(liked: true)

        try await waitUntil { repository.recordedSwipes.count == 1 }
        #expect(repository.recordedSwipes.first?.liked == true)
        #expect(repository.recordedSwipes.first?.embedding == [1, 0, 0])
    }

    @Test func swipeEventuallyRecordsADislike() async throws {
        let repository = InMemoryWardrobeRepository()
        let feedService = MockStockImageFeedService(photosToReturn: makePhotos(count: 1))
        let viewModel = SwipeDiscoveryViewModel(
            repository: repository, feedService: feedService,
            embeddingService: MockImageEmbeddingService(), session: makeStubbedSession()
        )
        await viewModel.loadDeckIfNeeded()

        viewModel.swipe(liked: false)

        try await waitUntil { repository.recordedSwipes.count == 1 }
        #expect(repository.recordedSwipes.first?.liked == false)
    }

    @Test func swipeOnAnEmptyDeckIsANoOp() async {
        let repository = InMemoryWardrobeRepository()
        let feedService = MockStockImageFeedService(photosToReturn: [])
        let viewModel = SwipeDiscoveryViewModel(
            repository: repository, feedService: feedService, embeddingService: MockImageEmbeddingService()
        )

        viewModel.swipe(liked: true)

        #expect(viewModel.deck.isEmpty)
    }

    // MARK: - SwipeGestureResolver

    @Test func decisionIsLikePastThePositiveThreshold() {
        #expect(SwipeGestureResolver.decision(forHorizontalTranslation: SwipeGestureResolver.commitThreshold) == .like)
        #expect(SwipeGestureResolver.decision(forHorizontalTranslation: SwipeGestureResolver.commitThreshold + 50) == .like)
    }

    @Test func decisionIsDislikePastTheNegativeThreshold() {
        #expect(SwipeGestureResolver.decision(forHorizontalTranslation: -SwipeGestureResolver.commitThreshold) == .dislike)
        #expect(SwipeGestureResolver.decision(forHorizontalTranslation: -SwipeGestureResolver.commitThreshold - 50) == .dislike)
    }

    @Test func decisionIsUndecidedWithinTheThreshold() {
        #expect(SwipeGestureResolver.decision(forHorizontalTranslation: 0) == .undecided)
        #expect(SwipeGestureResolver.decision(forHorizontalTranslation: SwipeGestureResolver.commitThreshold - 1) == .undecided)
        #expect(SwipeGestureResolver.decision(forHorizontalTranslation: -(SwipeGestureResolver.commitThreshold - 1)) == .undecided)
    }
}

// MARK: - Test doubles

@MainActor
private final class InMemoryWardrobeRepository: WardrobeRepository {
    private(set) var recordedSwipes: [(sourcePhotoID: String, liked: Bool, embedding: [Float])] = []

    func fetchInventory() throws -> [WardrobeItem] { [] }
    func save(_ item: WardrobeItem) throws {}
    func update(_ item: WardrobeItem) throws {}
    func delete(_ item: WardrobeItem) throws {}
    func fetchFeedbackHistory() async throws -> FeedbackHistory { FeedbackHistory() }
    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {}
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {}
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {}
    func recordItemRating(itemID: UUID, fit: FitRating, comfort: Int, confidence: Int, wearAgain: Bool, versatility: Int, frequency: Int, styleIdentity: Int, qualityPerception: Int) throws {}
    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] { [] }
    func recordOutfitRating(outfitID: UUID, submission: OutfitRatingSubmission) throws {}
    func fetchOutfitFeedback(for outfitID: UUID) throws -> [OutfitFeedback] { [] }
    func fetchSavedCombinations() throws -> [SavedCombination] { [] }
    func saveCombination(_ combination: SavedCombination) throws {}
    func deleteCombination(_ combination: SavedCombination) throws {}
    func fetchUserProfile() throws -> UserStyleProfile? { nil }
    func saveUserProfile(_ wire: UserStyleProfileWire) throws {}

    func recordSwipe(sourcePhotoID: String, imageURLString: String, liked: Bool, embedding: [Float]) throws {
        recordedSwipes.append((sourcePhotoID, liked, embedding))
    }
    func fetchVisualPreferenceState() throws -> VisualPreferenceState? { nil }
    func updateVisualPreferenceState(likedCentroids: [VisualCentroid], dislikedCentroids: [VisualCentroid], embeddingDimension: Int) throws {}
    func fetchWardrobeItemEmbedding(itemID: UUID) throws -> WardrobeItemEmbedding? { nil }
    func saveWardrobeItemEmbedding(itemID: UUID, vector: [Float], sourceFingerprint: String) throws {}
}

/// Intercepts every request with canned 200-OK image bytes — `persistSwipe`'s
/// `session.data(from:)` download never touches the real network in tests.
private final class StubURLProtocol: URLProtocol {
    static let stubData = Data([0x01, 0x02, 0x03])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.stubData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
