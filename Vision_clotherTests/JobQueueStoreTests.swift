//
//  JobQueueStoreTests.swift
//  Vision_clotherTests
//
//  Covers the background job queue (`Features/JobQueue/JobQueueStore.swift`)
//  introduced to decouple wardrobe-item ingestion and try-on generation from
//  any one view's lifecycle: uploads save directly with no review step, and
//  multiple try-on renders can be in flight at once without one cancelling
//  another.
//

import Foundation
import Testing
@testable import Vision_clother

@MainActor
struct JobQueueStoreTests {

    // MARK: - Upload jobs

    @Test func uploadJobSucceedsAndSavesTaggedItemWithNoReviewStep() async throws {
        let repository = InMemoryWardrobeRepository()
        let mockVision = MockVisionMetadataExtractionService(result: GarmentMetadata(
            slot: .outerwear,
            formalityScore: 2.5,
            colorProfile: GarmentMetadata.ColorProfileWire(primaryHex: "#00FF00", secondaryHex: nil, category: .vibrant, undertone: .warm),
            pattern: .plaid,
            seasonality: [.winter],
            fabricWeight: .medium,
            description: "Olive field jacket with brass buttons.",
            styleTags: ["utility", "outdoorsy"]
        ))
        let store = JobQueueStore(
            repository: repository,
            backgroundIsolationService: MockBackgroundIsolationService(),
            imagePreprocessingService: MockBackgroundIsolationService(),
            visionMetadataService: mockVision,
            tryOnService: MockTryOnRenderService(),
            photoLibrarySaver: MockPhotoLibrarySaver(),
            notificationService: MockJobNotificationService()
        )

        store.enqueueUpload(rawImageData: Data([1, 2, 3]), defaultSlot: nil)
        try await waitUntil { !(store.jobs.first?.status.isInFlight ?? true) }

        let job = try #require(store.jobs.first)
        #expect(job.status == .succeeded)

        let saved = try #require(repository.savedItems.first)
        #expect(repository.savedItems.count == 1)
        #expect(saved.slot == .outerwear)
        #expect(saved.formalityScore == 2.5)
        #expect(saved.colorProfile.primaryHex == "#00FF00")
        #expect(saved.colorProfile.undertone == .warm)
        #expect(saved.pattern == .plaid)
        #expect(saved.seasonality == [.winter])
        #expect(saved.fabricWeight == .medium)
        #expect(saved.itemDescription == "Olive field jacket with brass buttons.")
        #expect(saved.styleTags == ["utility", "outdoorsy"])
        #expect(job.resultItemID == saved.id)
    }

    @Test func failedUploadJobSurfacesTheErrorAndIsRetryable() async throws {
        let repository = InMemoryWardrobeRepository()
        let visionService = FlakyVisionMetadataExtractionService(
            failuresBeforeSuccess: 1,
            successResult: MockVisionMetadataExtractionService().result
        )
        let store = JobQueueStore(
            repository: repository,
            backgroundIsolationService: MockBackgroundIsolationService(),
            imagePreprocessingService: MockBackgroundIsolationService(),
            visionMetadataService: visionService,
            tryOnService: MockTryOnRenderService(),
            photoLibrarySaver: MockPhotoLibrarySaver(),
            notificationService: MockJobNotificationService()
        )

        store.enqueueUpload(rawImageData: Data([1, 2, 3]), defaultSlot: nil)
        try await waitUntil { !(store.jobs.first?.status.isInFlight ?? true) }

        guard case .failed = store.jobs.first?.status else {
            Issue.record("Expected the first attempt to fail, got \(String(describing: store.jobs.first?.status))")
            return
        }
        #expect(repository.savedItems.isEmpty)

        let jobID = try #require(store.jobs.first?.id)
        store.retryUpload(jobID)
        try await waitUntil { store.jobs.first?.status == .succeeded }

        #expect(store.jobs.first?.status == .succeeded)
        #expect(repository.savedItems.count == 1)
    }

    // MARK: - Try-on jobs

    @Test func twoConcurrentTryOnJobsDoNotCancelEachOther() async throws {
        let repository = InMemoryWardrobeRepository()
        let tryOnService = ConcurrencyTrackingTryOnRenderService()
        let store = JobQueueStore(
            repository: repository,
            backgroundIsolationService: MockBackgroundIsolationService(),
            imagePreprocessingService: MockBackgroundIsolationService(),
            visionMetadataService: MockVisionMetadataExtractionService(),
            tryOnService: tryOnService,
            photoLibrarySaver: MockPhotoLibrarySaver(),
            notificationService: MockJobNotificationService()
        )

        // Starting the second job must not cancel the first — unlike the
        // pre-job-queue `DailyAssistantViewModel.tryOnTask?.cancel()`
        // cancel-and-replace pattern this store replaced.
        store.enqueueTryOn(baseImageData: Data([0x01]), outfit: makeOutfit())
        store.enqueueTryOn(baseImageData: Data([0x02]), outfit: makeOutfit())

        try await waitUntil { store.jobs.allSatisfy { !$0.status.isInFlight } }

        #expect(store.jobs.count == 2)
        #expect(store.jobs.allSatisfy { $0.status == .succeeded })
        #expect(tryOnService.maxObservedConcurrency == 2)
    }

    @Test func saveCombinationForAJobWithoutASucceededRenderDoesNothing() async throws {
        let repository = InMemoryWardrobeRepository()
        let store = makeJobQueueStore(repository: repository)

        await store.saveCombination(for: UUID(), liked: true)

        #expect(repository.savedCombinations.isEmpty)
    }

    @Test func saveCombinationAfterSuccessfulRenderPersistsTheImage() async throws {
        let repository = InMemoryWardrobeRepository()
        let tryOnService = ControllableTryOnRenderService()
        let photoLibrarySaver = ControllablePhotoLibrarySaver()
        let store = JobQueueStore(
            repository: repository,
            backgroundIsolationService: MockBackgroundIsolationService(),
            imagePreprocessingService: MockBackgroundIsolationService(),
            visionMetadataService: MockVisionMetadataExtractionService(),
            tryOnService: tryOnService,
            photoLibrarySaver: photoLibrarySaver,
            notificationService: MockJobNotificationService()
        )
        let outfit = makeOutfit()

        store.enqueueTryOn(baseImageData: Data([0x01]), outfit: outfit)
        try await waitUntil { store.jobs.first?.status == .succeeded }

        let jobID = try #require(store.jobs.first?.id)
        await store.saveCombination(for: jobID, liked: true)
        defer { repository.savedCombinations.forEach { ImageStorage.delete($0.imageAssetName) } }

        #expect(repository.savedCombinations.count == 1)
        #expect(repository.savedCombinations.first?.origin == "assistant")
        #expect(repository.savedCombinations.first?.itemIDsBySlot[.top] == outfit.top.id)
        #expect(repository.savedCombinations.first?.itemIDsBySlot[.bottom] == outfit.bottom.id)
        #expect(repository.savedCombinations.first?.basePortraitFingerprint == ImageStorage.fingerprint(Data([0x01])))
        #expect(photoLibrarySaver.saveCallCount == 1)
    }

    @Test func saveCombinationRecordsOutfitAndEveryPairwiseFeedback() async throws {
        // Daily Assistant outfits can have 3-4 real items (top/bottom/footwear
        // +optional outerwear) — every pairwise combination must get a
        // feedback row, not just top+bottom, since outfitScore already reads
        // every pair via PairCompatibilityScoring.pairwiseCombinations.
        let repository = InMemoryWardrobeRepository()
        let tryOnService = ControllableTryOnRenderService()
        let store = JobQueueStore(
            repository: repository,
            backgroundIsolationService: MockBackgroundIsolationService(),
            imagePreprocessingService: MockBackgroundIsolationService(),
            visionMetadataService: MockVisionMetadataExtractionService(),
            tryOnService: tryOnService,
            photoLibrarySaver: MockPhotoLibrarySaver(),
            notificationService: MockJobNotificationService()
        )
        let outfit = makeOutfit()

        store.enqueueTryOn(baseImageData: Data([0x01]), outfit: outfit)
        try await waitUntil { store.jobs.first?.status == .succeeded }

        let jobID = try #require(store.jobs.first?.id)
        await store.saveCombination(for: jobID, liked: false)
        defer { repository.savedCombinations.forEach { ImageStorage.delete($0.imageAssetName) } }

        #expect(repository.recordedOutfitFeedback.count == 1)
        #expect(repository.recordedOutfitFeedback.first?.likedOverall == false)
        #expect(repository.recordedOutfitFeedback.first?.outfitID == repository.savedCombinations.first?.id)
        // top+bottom, top+footwear, bottom+footwear — 3 pairs for a 3-item outfit.
        #expect(repository.recordedPairFeedback.count == 3)
        #expect(repository.recordedPairFeedback.allSatisfy { $0.likedTogether == false })
    }
}

// MARK: - Test helpers

@MainActor
private func makeJobQueueStore(repository: WardrobeRepository) -> JobQueueStore {
    JobQueueStore(
        repository: repository,
        backgroundIsolationService: MockBackgroundIsolationService(),
        imagePreprocessingService: MockBackgroundIsolationService(),
        visionMetadataService: MockVisionMetadataExtractionService(),
        tryOnService: MockTryOnRenderService(),
        photoLibrarySaver: MockPhotoLibrarySaver(),
        notificationService: MockJobNotificationService()
    )
}

private func makeItem(slot: Slot) -> WardrobeItem {
    WardrobeItem(
        slot: slot,
        formalityScore: 2.0,
        colorProfile: ColorProfile(primaryHex: "#000000", secondaryHex: nil, category: .neutral),
        pattern: .solid,
        seasonality: [.summer],
        fabricWeight: .light,
        imageAssetName: "\(UUID().uuidString).png"
    )
}

private func makeOutfit() -> OutfitCombination {
    OutfitCombination(
        itemsBySlot: [.top: makeItem(slot: .top), .bottom: makeItem(slot: .bottom), .footwear: makeItem(slot: .footwear)],
        score: 1.0
    )
}

@MainActor
private final class InMemoryWardrobeRepository: WardrobeRepository {
    var savedItems: [WardrobeItem] = []
    var savedCombinations: [SavedCombination] = []
    private(set) var recordedOutfitFeedback: [(outfitID: UUID, likedOverall: Bool)] = []
    private(set) var recordedPairFeedback: [(itemAID: UUID, itemBID: UUID, likedTogether: Bool)] = []

    func fetchInventory() throws -> [WardrobeItem] { savedItems }
    func save(_ item: WardrobeItem) throws { savedItems.append(item) }
    func update(_ item: WardrobeItem) throws {}
    func delete(_ item: WardrobeItem) throws { savedItems.removeAll { $0.id == item.id } }
    func fetchFeedbackHistory() async throws -> FeedbackHistory { FeedbackHistory() }
    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {
        recordedOutfitFeedback.append((outfitID, likedOverall))
    }
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {}
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {
        recordedPairFeedback.append((itemAID, itemBID, likedTogether))
    }
    func recordItemRating(itemID: UUID, fit: FitRating, comfort: Int, colorLike: Int, patternLike: Int?, formalityFit: Int, styleIdentity: Int, wearAgain: Bool) throws {}
    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] { [] }
    func recordOutfitRating(outfitID: UUID, submission: OutfitRatingSubmission) throws {}
    func fetchOutfitFeedback(for outfitID: UUID) throws -> [OutfitFeedback] { [] }

    func fetchSavedCombinations() throws -> [SavedCombination] { savedCombinations }
    func saveCombination(_ combination: SavedCombination) throws { savedCombinations.append(combination) }
    func deleteCombination(_ combination: SavedCombination) throws {
        savedCombinations.removeAll { $0.id == combination.id }
    }

    func fetchUserProfile() throws -> UserStyleProfile? { nil }
    func saveUserProfile(_ wire: UserStyleProfileWire) throws {}
    func recordSwipe(sourcePhotoID: String, imageURLString: String, liked: Bool, embedding: [Float]) throws -> Double? { nil }
    func fetchVisualPreferenceState() throws -> VisualPreferenceState? { nil }
    func updateVisualPreferenceState(likedCentroids: [VisualCentroid], dislikedCentroids: [VisualCentroid], embeddingDimension: Int) throws {}
    func fetchWardrobeItemEmbedding(itemID: UUID) throws -> WardrobeItemEmbedding? { nil }
    func saveWardrobeItemEmbedding(itemID: UUID, vector: [Float], sourceFingerprint: String) throws {}
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

// MARK: - Test doubles

/// Throws `failuresBeforeSuccess` times, then returns `successResult` —
/// backs the upload-retry test.
private final class FlakyVisionMetadataExtractionService: VisionMetadataExtractionService {
    private var remainingFailures: Int
    let successResult: GarmentMetadata

    init(failuresBeforeSuccess: Int, successResult: GarmentMetadata) {
        self.remainingFailures = failuresBeforeSuccess
        self.successResult = successResult
    }

    func extractMetadata(imageData: Data) async throws -> GarmentMetadata {
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw VisionMetadataExtractionError.emptyChoices
        }
        return successResult
    }
}

/// Tracks how many `renderTryOn` calls are simultaneously in flight — proves
/// two jobs actually overlap rather than merely both eventually succeeding.
@MainActor
private final class ConcurrencyTrackingTryOnRenderService: TryOnRenderService {
    private(set) var activeCount = 0
    private(set) var maxObservedConcurrency = 0

    func renderTryOn(
        baseImageData: Data,
        items: [WardrobeItem],
        onUpdate: @escaping (TryOnState) -> Void
    ) async {
        activeCount += 1
        maxObservedConcurrency = max(maxObservedConcurrency, activeCount)
        onUpdate(.submitting(stage: .rendering))
        try? await Task.sleep(for: .milliseconds(50))
        activeCount -= 1

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try? Data([0xAA]).write(to: url)
        onUpdate(.succeeded(imageURL: url))
    }
}

/// Fires exactly one `.submitting` -> `.succeeded` cycle per call, writing
/// real bytes to a local temp file so `saveCombination(for:)`'s
/// `Data(contentsOf:)` read never has to touch the network.
private final class ControllableTryOnRenderService: TryOnRenderService {
    let resultImageURL: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try? Data([0xAA, 0xBB, 0xCC]).write(to: url)
        return url
    }()

    func renderTryOn(
        baseImageData: Data,
        items: [WardrobeItem],
        onUpdate: @escaping (TryOnState) -> Void
    ) async {
        onUpdate(.submitting(stage: .rendering))
        onUpdate(.succeeded(imageURL: resultImageURL))
    }
}

private final class ControllablePhotoLibrarySaver: PhotoLibrarySaver {
    private(set) var saveCallCount = 0

    func save(imageData: Data) async throws {
        saveCallCount += 1
    }
}
