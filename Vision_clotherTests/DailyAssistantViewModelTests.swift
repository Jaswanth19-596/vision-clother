//
//  DailyAssistantViewModelTests.swift
//  Vision_clotherTests
//
//  Covers Daily Assistant's try-on save path — the second call site (besides
//  Manual Pairing) that can persist a `SavedCombination` (see
//  Features/DailyAssistant/DailyAssistantViewModel.swift).
//

import Foundation
import Testing
@testable import Vision_clother

@MainActor
struct DailyAssistantViewModelTests {

    @Test func saveCombinationWithoutARenderedOutfitDoesNothing() async throws {
        let repository = InMemoryWardrobeRepository()
        let viewModel = DailyAssistantViewModel(repository: repository)

        await viewModel.saveCombination()

        #expect(repository.savedCombinations.isEmpty)
    }

    @Test func saveCombinationAfterSuccessfulRenderPersistsTheImage() async throws {
        let repository = InMemoryWardrobeRepository()
        let tryOnService = ControllableTryOnRenderService()
        let photoLibrarySaver = ControllablePhotoLibrarySaver()
        let viewModel = DailyAssistantViewModel(
            repository: repository,
            tryOnService: tryOnService,
            photoLibrarySaver: photoLibrarySaver
        )
        let outfit = makeOutfit()

        viewModel.startTryOn(baseImageData: Data([0x01]), outfit: outfit)
        try await waitUntil { viewModel.tryOnState != .idle }
        guard case .succeeded = viewModel.tryOnState else {
            Issue.record("Expected .succeeded, got \(viewModel.tryOnState)")
            return
        }

        await viewModel.saveCombination()
        defer { repository.savedCombinations.forEach { ImageStorage.delete($0.imageAssetName) } }

        #expect(repository.savedCombinations.count == 1)
        #expect(repository.savedCombinations.first?.origin == "assistant")
        #expect(repository.savedCombinations.first?.topItemID == outfit.top.id)
        #expect(repository.savedCombinations.first?.bottomItemID == outfit.bottom.id)
        #expect(photoLibrarySaver.saveCallCount == 1)
    }
}

// MARK: - Test helpers

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
        top: makeItem(slot: .top),
        bottom: makeItem(slot: .bottom),
        footwear: makeItem(slot: .footwear),
        score: 1.0
    )
}

// MARK: - Test doubles

@MainActor
private final class InMemoryWardrobeRepository: WardrobeRepository {
    var savedItems: [WardrobeItem] = []
    var savedCombinations: [SavedCombination] = []

    func fetchInventory() throws -> [WardrobeItem] { savedItems }
    func save(_ item: WardrobeItem) throws { savedItems.append(item) }
    func delete(_ item: WardrobeItem) throws { savedItems.removeAll { $0.id == item.id } }
    func fetchFeedbackHistory() throws -> FeedbackHistory { FeedbackHistory() }
    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {}
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {}
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {}
    func recordItemRating(itemID: UUID, fit: FitRating, comfort: Int, confidence: Int, wearAgain: Bool) throws {}
    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] { [] }

    func fetchSavedCombinations() throws -> [SavedCombination] { savedCombinations }
    func saveCombination(_ combination: SavedCombination) throws { savedCombinations.append(combination) }
    func deleteCombination(_ combination: SavedCombination) throws {
        savedCombinations.removeAll { $0.id == combination.id }
    }
}

/// Fires exactly one `.submitting` -> `.succeeded` cycle per call, writing
/// real bytes to a local temp file so `saveCombination()`'s
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
