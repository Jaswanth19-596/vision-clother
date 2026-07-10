//
//  ManualPairingViewModelTests.swift
//  Vision_clotherTests
//
//  Covers Manual Outfit Pairing's flow at the view-model layer: photo gate,
//  validation failure, cancel-on-reselect (no stale result ever overwrites
//  a newer selection), and the save/discard feedback-only persistence path
//  (see Features/Pairing/ManualPairingViewModel.swift).
//

import Foundation
import Testing
@testable import Vision_clother

// `UserPortraitStorage` is one fixed file shared by every test in this
// suite (see its header — there is deliberately only ever one on disk), so
// tests can't run concurrently against it without racing each other. This
// suite is serialized for that reason; each test still cleans up after
// itself with `defer { UserPortraitStorage.delete() }` so ordering never
// matters either.
@Suite(.serialized)
@MainActor
struct ManualPairingViewModelTests {

    @Test func ghostElementsAreExcludedFromPickers() throws {
        let repository = InMemoryWardrobeRepository()
        let realTop = makeItem(slot: .top)
        let ghostTop = makeItem(slot: .top, isGhostElement: true)
        repository.savedItems = [realTop, ghostTop]

        let viewModel = ManualPairingViewModel(repository: repository)

        #expect(viewModel.availableTops.map(\.id) == [realTop.id])
    }

    @Test func generatingWithoutAPortraitFails() async throws {
        UserPortraitStorage.delete()
        defer { UserPortraitStorage.delete() }

        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        repository.savedItems = [top, bottom]

        let tryOnService = ControllableTryOnRenderService()
        let viewModel = ManualPairingViewModel(
            repository: repository,
            validationService: MockPersonPhotoValidationService(),
            tryOnService: tryOnService
        )
        viewModel.selectTop(top)
        viewModel.selectBottom(bottom)
        #expect(viewModel.canGeneratePreview == false)

        // Drive the pipeline directly (bypassing the UI's disabled-button
        // gate) to also cover the defensive nil-portrait guard in
        // runPipeline itself.
        viewModel.generatePreview()
        try await waitUntil { viewModel.state != .validatingPhoto }

        guard case .failed(let message) = viewModel.state else {
            Issue.record("Expected .failed, got \(viewModel.state)")
            return
        }
        #expect(message == "Add a photo of yourself first.")
        #expect(tryOnService.callCount == 0)
    }

    @Test func photoValidationFailureSurfacesWithoutGenerating() async throws {
        defer { UserPortraitStorage.delete() }
        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        repository.savedItems = [top, bottom]

        let tryOnService = ControllableTryOnRenderService()
        let viewModel = ManualPairingViewModel(
            repository: repository,
            validationService: MockPersonPhotoValidationService(errorToThrow: .notFullBody),
            tryOnService: tryOnService
        )
        viewModel.savePortrait(Data([0x01]))
        viewModel.selectTop(top)
        viewModel.selectBottom(bottom)

        viewModel.generatePreview()
        try await waitUntil { viewModel.state != .validatingPhoto }

        guard case .failed(let message) = viewModel.state else {
            Issue.record("Expected .failed, got \(viewModel.state)")
            return
        }
        #expect(message == PersonPhotoValidationError.notFullBody.errorDescription)
        #expect(tryOnService.callCount == 0)
    }

    @Test func successfulGenerationReachesSuccessState() async throws {
        defer { UserPortraitStorage.delete() }
        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        repository.savedItems = [top, bottom]

        let tryOnService = ControllableTryOnRenderService()
        let viewModel = ManualPairingViewModel(
            repository: repository,
            validationService: MockPersonPhotoValidationService(),
            tryOnService: tryOnService
        )
        viewModel.savePortrait(Data([0x01]))
        viewModel.selectTop(top)
        viewModel.selectBottom(bottom)

        viewModel.generatePreview()
        try await waitUntil { viewModel.state != .validatingPhoto && viewModel.state != .preparingImages }

        guard case .success(let imageURL) = viewModel.state else {
            Issue.record("Expected .success, got \(viewModel.state)")
            return
        }
        #expect(imageURL == tryOnService.resultImageURL)
        #expect(tryOnService.callCount == 1)
    }

    @Test func reselectingMidGenerationIgnoresTheStaleResult() async throws {
        defer { UserPortraitStorage.delete() }
        let repository = InMemoryWardrobeRepository()
        let top1 = makeItem(slot: .top)
        let top2 = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        repository.savedItems = [top1, top2, bottom]

        let tryOnService = ControllableTryOnRenderService()
        tryOnService.stepDelayNanoseconds = 200_000_000 // long enough to reselect mid-flight
        let viewModel = ManualPairingViewModel(
            repository: repository,
            validationService: MockPersonPhotoValidationService(),
            tryOnService: tryOnService
        )
        viewModel.savePortrait(Data([0x01]))
        viewModel.selectTop(top1)
        viewModel.selectBottom(bottom)

        viewModel.generatePreview()
        try await waitUntil { viewModel.state != .validatingPhoto && viewModel.state != .preparingImages }

        // Reselect before the first generation's delayed result lands.
        viewModel.selectTop(top2)

        // Let the original (now-cancelled) generation's delay fully elapse.
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(viewModel.state == .idle)
        #expect(viewModel.selectedTop?.id == top2.id)
    }

    @Test func saveOutfitRequiresAGeneratedPreview() async throws {
        // No preview generated (state is still `.idle`) — nothing to save,
        // since there's no image to persist. Mirrors the UI, where the
        // "Save this outfit?" prompt only ever appears from `.success`.
        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        repository.savedItems = [top, bottom]

        let viewModel = ManualPairingViewModel(repository: repository)
        viewModel.selectTop(top)
        viewModel.selectBottom(bottom)

        await viewModel.saveOutfit()

        #expect(viewModel.didSaveOutfit == false)
        #expect(repository.recordedPairFeedback.isEmpty)
        #expect(repository.savedCombinations.isEmpty)
    }

    @Test func saveOutfitFromSuccessPersistsFeedbackAndTheGeneratedImage() async throws {
        defer { UserPortraitStorage.delete() }
        let repository = InMemoryWardrobeRepository()
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        repository.savedItems = [top, bottom]

        let tryOnService = ControllableTryOnRenderService()
        let photoLibrarySaver = ControllablePhotoLibrarySaver()
        let viewModel = ManualPairingViewModel(
            repository: repository,
            validationService: MockPersonPhotoValidationService(),
            tryOnService: tryOnService,
            photoLibrarySaver: photoLibrarySaver
        )
        viewModel.savePortrait(Data([0x01]))
        viewModel.selectTop(top)
        viewModel.selectBottom(bottom)

        viewModel.generatePreview()
        try await waitUntil { viewModel.state != .validatingPhoto && viewModel.state != .preparingImages }
        guard case .success = viewModel.state else {
            Issue.record("Expected .success, got \(viewModel.state)")
            return
        }

        await viewModel.saveOutfit()
        defer { repository.savedCombinations.forEach { ImageStorage.delete($0.imageAssetName) } }

        #expect(viewModel.didSaveOutfit == true)
        #expect(repository.recordedPairFeedback.count == 1)
        #expect(repository.recordedPairFeedback.first?.likedTogether == true)
        #expect(repository.recordedOutfitFeedback.count == 1)
        #expect(repository.savedCombinations.count == 1)
        #expect(repository.savedCombinations.first?.origin == "pairing")
        #expect(repository.savedCombinations.first?.topItemID == top.id)
        #expect(repository.savedCombinations.first?.bottomItemID == bottom.id)
        #expect(photoLibrarySaver.saveCallCount == 1)
    }

    @Test func discardPreviewResetsWithoutPersisting() throws {
        let repository = InMemoryWardrobeRepository()
        let viewModel = ManualPairingViewModel(repository: repository)

        viewModel.discardPreview()

        #expect(viewModel.state == .idle)
        #expect(repository.recordedPairFeedback.isEmpty)
        #expect(repository.recordedOutfitFeedback.isEmpty)
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

private func makeItem(slot: Slot, isGhostElement: Bool = false) -> WardrobeItem {
    WardrobeItem(
        slot: slot,
        formalityScore: 2.0,
        colorProfile: ColorProfile(primaryHex: "#000000", secondaryHex: nil, category: .neutral),
        pattern: .solid,
        seasonality: [.summer],
        fabricWeight: .light,
        imageAssetName: isGhostElement ? "ghost_placeholder" : "\(UUID().uuidString).png",
        isGhostElement: isGhostElement
    )
}

// MARK: - Test doubles

@MainActor
private final class InMemoryWardrobeRepository: WardrobeRepository {
    var savedItems: [WardrobeItem] = []
    private(set) var recordedPairFeedback: [(itemAID: UUID, itemBID: UUID, likedTogether: Bool)] = []
    private(set) var recordedOutfitFeedback: [(outfitID: UUID, likedOverall: Bool)] = []
    var savedCombinations: [SavedCombination] = []

    func fetchInventory() throws -> [WardrobeItem] { savedItems }
    func save(_ item: WardrobeItem) throws { savedItems.append(item) }
    func delete(_ item: WardrobeItem) throws { savedItems.removeAll { $0.id == item.id } }
    func fetchFeedbackHistory() throws -> FeedbackHistory { FeedbackHistory() }

    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {
        recordedOutfitFeedback.append((outfitID, likedOverall))
    }
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {}
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {
        recordedPairFeedback.append((itemAID, itemBID, likedTogether))
    }
    func recordItemRating(itemID: UUID, fit: FitRating, comfort: Int, confidence: Int, wearAgain: Bool) throws {}
    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] { [] }

    func fetchSavedCombinations() throws -> [SavedCombination] { savedCombinations }
    func saveCombination(_ combination: SavedCombination) throws { savedCombinations.append(combination) }
    func deleteCombination(_ combination: SavedCombination) throws {
        savedCombinations.removeAll { $0.id == combination.id }
    }
}

/// Fires exactly one `.submitting` -> (delay) -> `.succeeded` cycle per
/// call, so tests can control timing without touching the network. Writes
/// real bytes to a local temp file (mirroring how the real render service's
/// `handleImageString` behaves) so `saveOutfit()`'s `Data(contentsOf:)` read
/// never has to touch the network.
private final class ControllableTryOnRenderService: TryOnRenderService {
    private(set) var callCount = 0
    var stepDelayNanoseconds: UInt64 = 10_000_000
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
        callCount += 1
        onUpdate(.submitting(stage: .rendering))
        try? await Task.sleep(nanoseconds: stepDelayNanoseconds)
        guard !Task.isCancelled else { return }
        onUpdate(.succeeded(imageURL: resultImageURL))
    }
}

private final class ControllablePhotoLibrarySaver: PhotoLibrarySaver {
    private(set) var saveCallCount = 0

    func save(imageData: Data) async throws {
        saveCallCount += 1
    }
}
