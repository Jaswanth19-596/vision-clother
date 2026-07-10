//
//  AddItemViewModelTests.swift
//  Vision_clotherTests
//

import Foundation
import Testing
@testable import Vision_clother

@MainActor
struct AddItemViewModelTests {

    @Test func initialSetupIsIdle() async {
        let repo = MockWardrobeRepository()
        let vm = AddItemViewModel(repository: repo)
        #expect(vm.state == .idle)
        #expect(!vm.didSave)
    }

    @Test func startManualEntrySeedsPropertiesCorrectly() async {
        let repo = MockWardrobeRepository()
        let vm = AddItemViewModel(repository: repo)

        vm.startManualEntry(defaultSlot: .bottom)

        #expect(vm.state == .editingMetadata)
        #expect(vm.slot == .bottom)
        #expect(vm.formalityScore == 3.0)
        #expect(vm.pattern == .solid)
        #expect(vm.primaryHex == "#FFFFFF")
        #expect(vm.isolatedImageData == nil)
    }

    @Test func saveManuallyEnteredItemPersistsToRepository() async {
        let repo = MockWardrobeRepository()
        let vm = AddItemViewModel(repository: repo)

        vm.startManualEntry(defaultSlot: .footwear)
        vm.formalityScore = 4.5
        vm.primaryHex = "#FF0000"
        vm.pattern = .striped
        vm.fabricWeight = .heavy

        await vm.saveItem()

        #expect(vm.didSave)
        #expect(repo.savedItems.count == 1)
        
        let saved = repo.savedItems.first
        #expect(saved?.slot == .footwear)
        #expect(saved?.formalityScore == 4.5)
        #expect(saved?.colorProfile.primaryHex == "#FF0000")
        #expect(saved?.pattern == .striped)
        #expect(saved?.fabricWeight == .heavy)
        #expect(saved?.imageAssetName == nil)
    }

    @Test func ingestSetsStateToEditingAndPopulatesTags() async {
        let repo = MockWardrobeRepository()
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
        let vm = AddItemViewModel(
            repository: repo,
            backgroundIsolationService: MockBackgroundIsolationService(),
            visionMetadataService: mockVision
        )

        let dummyData = Data([1, 2, 3])
        await vm.ingest(rawImageData: dummyData)

        #expect(vm.state == .editingMetadata)
        #expect(vm.slot == .outerwear)
        #expect(vm.formalityScore == 2.5)
        #expect(vm.primaryHex == "#00FF00")
        #expect(vm.colorCategory == .vibrant)
        #expect(vm.undertone == .warm)
        #expect(vm.pattern == .plaid)
        #expect(vm.seasonality == [.winter])
        #expect(vm.fabricWeight == .medium)
        #expect(vm.itemDescription == "Olive field jacket with brass buttons.")
        #expect(vm.styleTags == ["utility", "outdoorsy"])
        #expect(vm.isolatedImageData == dummyData)
    }

    @Test func savedItemPersistsDescriptionUndertoneAndStyleTags() async {
        let repo = MockWardrobeRepository()
        let vm = AddItemViewModel(repository: repo)

        vm.startManualEntry(defaultSlot: .top)
        vm.itemDescription = "Cream linen popover shirt."
        vm.undertone = .neutral
        vm.styleTags = ["resort", "linen"]

        await vm.saveItem()

        let saved = repo.savedItems.first
        #expect(saved?.itemDescription == "Cream linen popover shirt.")
        #expect(saved?.colorProfile.undertone == .neutral)
        #expect(saved?.styleTags == ["resort", "linen"])
    }

    @Test func emptyDescriptionPersistsAsNilNotAnEmptyString() async {
        let repo = MockWardrobeRepository()
        let vm = AddItemViewModel(repository: repo)

        vm.startManualEntry(defaultSlot: .top)
        // itemDescription left at its default "" (no vision tagging pass).

        await vm.saveItem()

        #expect(repo.savedItems.first?.itemDescription == nil)
    }
}

@MainActor
private final class MockWardrobeRepository: WardrobeRepository {
    var savedItems: [WardrobeItem] = []

    func fetchInventory() throws -> [WardrobeItem] {
        savedItems
    }

    func save(_ item: WardrobeItem) throws {
        savedItems.append(item)
    }

    func delete(_ item: WardrobeItem) throws {
        savedItems.removeAll { $0.id == item.id }
    }

    func fetchFeedbackHistory() throws -> FeedbackHistory {
        FeedbackHistory()
    }

    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {}
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {}
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {}
    func recordItemRating(itemID: UUID, fit: FitRating, comfort: Int, confidence: Int, wearAgain: Bool) throws {}
    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] { [] }

    func fetchSavedCombinations() throws -> [SavedCombination] { [] }
    func saveCombination(_ combination: SavedCombination) throws {}
    func deleteCombination(_ combination: SavedCombination) throws {}

    func fetchUserProfile() throws -> UserStyleProfile? { nil }
    func saveUserProfile(_ wire: UserStyleProfileWire) throws {}
}
