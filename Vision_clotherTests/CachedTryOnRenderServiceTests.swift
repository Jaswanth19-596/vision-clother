//
//  CachedTryOnRenderServiceTests.swift
//  Vision_clotherTests
//
//  Covers `Services/CachedTryOnRenderService.swift` — the decorator that
//  reuses a previously-saved try-on render instead of paying for a fresh AI
//  generation when the requested item set and base portrait both match an
//  existing `SavedCombination`.
//

import Foundation
import Testing
@testable import Vision_clother

@MainActor
struct CachedTryOnRenderServiceTests {

    @Test func cacheHitReusesTheSavedImageWithoutCallingTheUnderlyingService() async throws {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let portraitData = Data([0x01, 0x02, 0x03])
        let fingerprint = ImageStorage.fingerprint(portraitData)

        let assetName = try ImageStorage.save(Data([0xAA]))
        defer { ImageStorage.delete(assetName) }

        let repository = FakeSavedCombinationRepository(savedCombinations: [
            SavedCombination(
                imageAssetName: assetName,
                itemIDsBySlot: [.top: top.id, .bottom: bottom.id],
                labelsBySlot: [.top: top.displayLabel, .bottom: bottom.displayLabel],
                origin: "pairing",
                basePortraitFingerprint: fingerprint
            )
        ])
        let underlying = RecordingTryOnRenderService()
        let sut = CachedTryOnRenderService(repository: repository, underlying: underlying)

        var observedStates: [TryOnState] = []
        await sut.renderTryOn(baseImageData: portraitData, items: [top, bottom]) { observedStates.append($0) }

        #expect(underlying.callCount == 0)
        #expect(observedStates.count == 1)
        guard case .succeeded(let imageURL) = observedStates.first else {
            Issue.record("Expected a single .succeeded state, got \(observedStates)")
            return
        }
        #expect(imageURL == ImageStorage.url(for: assetName))
    }

    @Test func differentItemSetIsACacheMissAndDelegatesToTheUnderlyingService() async throws {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let otherBottom = makeItem(slot: .bottom)
        let portraitData = Data([0x01, 0x02, 0x03])

        let assetName = try ImageStorage.save(Data([0xAA]))
        defer { ImageStorage.delete(assetName) }

        let repository = FakeSavedCombinationRepository(savedCombinations: [
            SavedCombination(
                imageAssetName: assetName,
                itemIDsBySlot: [.top: top.id, .bottom: bottom.id],
                labelsBySlot: [.top: top.displayLabel, .bottom: bottom.displayLabel],
                origin: "pairing",
                basePortraitFingerprint: ImageStorage.fingerprint(portraitData)
            )
        ])
        let underlying = RecordingTryOnRenderService()
        let sut = CachedTryOnRenderService(repository: repository, underlying: underlying)

        await sut.renderTryOn(baseImageData: portraitData, items: [top, otherBottom]) { _ in }

        #expect(underlying.callCount == 1)
    }

    @Test func matchingItemSetButDifferentPortraitIsACacheMiss() async throws {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let oldPortraitData = Data([0x01])
        let newPortraitData = Data([0x02])

        let assetName = try ImageStorage.save(Data([0xAA]))
        defer { ImageStorage.delete(assetName) }

        let repository = FakeSavedCombinationRepository(savedCombinations: [
            SavedCombination(
                imageAssetName: assetName,
                itemIDsBySlot: [.top: top.id, .bottom: bottom.id],
                labelsBySlot: [.top: top.displayLabel, .bottom: bottom.displayLabel],
                origin: "pairing",
                basePortraitFingerprint: ImageStorage.fingerprint(oldPortraitData)
            )
        ])
        let underlying = RecordingTryOnRenderService()
        let sut = CachedTryOnRenderService(repository: repository, underlying: underlying)

        await sut.renderTryOn(baseImageData: newPortraitData, items: [top, bottom]) { _ in }

        #expect(underlying.callCount == 1)
    }

    @Test func matchingRowWithAMissingImageFileFallsBackToTheUnderlyingService() async throws {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let portraitData = Data([0x01])

        // Never actually written to disk — simulates a dangling reference.
        let danglingAssetName = "\(UUID().uuidString).png"

        let repository = FakeSavedCombinationRepository(savedCombinations: [
            SavedCombination(
                imageAssetName: danglingAssetName,
                itemIDsBySlot: [.top: top.id, .bottom: bottom.id],
                labelsBySlot: [.top: top.displayLabel, .bottom: bottom.displayLabel],
                origin: "pairing",
                basePortraitFingerprint: ImageStorage.fingerprint(portraitData)
            )
        ])
        let underlying = RecordingTryOnRenderService()
        let sut = CachedTryOnRenderService(repository: repository, underlying: underlying)

        await sut.renderTryOn(baseImageData: portraitData, items: [top, bottom]) { _ in }

        #expect(underlying.callCount == 1)
    }

    @Test func noSavedCombinationsIsACacheMiss() async throws {
        let top = makeItem(slot: .top)
        let bottom = makeItem(slot: .bottom)
        let repository = FakeSavedCombinationRepository(savedCombinations: [])
        let underlying = RecordingTryOnRenderService()
        let sut = CachedTryOnRenderService(repository: repository, underlying: underlying)

        await sut.renderTryOn(baseImageData: Data([0x01]), items: [top, bottom]) { _ in }

        #expect(underlying.callCount == 1)
    }
}

// MARK: - Test doubles

private func makeItem(slot: Slot) -> WardrobeItem {
    WardrobeItem(
        slot: slot,
        formalityScore: 2.0,
        colorProfile: ColorProfile(primaryHex: "#000000", secondaryHex: nil, category: .neutral),
        pattern: .solid,
        seasonality: [.summer],
        fabricWeight: .light,
        imageAssetName: "\(UUID().uuidString).png",
        isGhostElement: false
    )
}

private final class RecordingTryOnRenderService: TryOnRenderService {
    private(set) var callCount = 0

    func renderTryOn(
        baseImageData: Data,
        items: [WardrobeItem],
        onUpdate: @escaping (TryOnState) -> Void
    ) async {
        callCount += 1
        onUpdate(.succeeded(imageURL: URL(string: "https://example.com/fresh-render.png")!))
    }
}

/// Only `fetchSavedCombinations()` is exercised by
/// `CachedTryOnRenderService` — every other `WardrobeRepository` requirement
/// is a stub, matching this test file's narrow scope.
@MainActor
private final class FakeSavedCombinationRepository: WardrobeRepository {
    var savedCombinations: [SavedCombination]

    init(savedCombinations: [SavedCombination]) {
        self.savedCombinations = savedCombinations
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
