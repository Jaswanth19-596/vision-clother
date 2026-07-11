//
//  AddItemViewModelTests.swift
//  Vision_clotherTests
//
//  Covers the "Enter Details Manually" path only — camera/photo-library
//  ingestion now runs through `Features/JobQueue/JobQueueStore.swift` (see
//  JobQueueStoreTests.swift).
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
        #expect(vm.editor.slot == .bottom)
        #expect(vm.editor.formalityScore == 3.0)
        #expect(vm.editor.pattern == .solid)
        #expect(vm.editor.primaryHex == "#FFFFFF")
    }

    @Test func saveManuallyEnteredItemPersistsToRepository() async {
        let repo = MockWardrobeRepository()
        let vm = AddItemViewModel(repository: repo)

        vm.startManualEntry(defaultSlot: .footwear)
        vm.editor.formalityScore = 4.5
        vm.editor.primaryHex = "#FF0000"
        vm.editor.pattern = .striped
        vm.editor.fabricWeight = .heavy

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

    @Test func savedItemPersistsDescriptionUndertoneAndStyleTags() async {
        let repo = MockWardrobeRepository()
        let vm = AddItemViewModel(repository: repo)

        vm.startManualEntry(defaultSlot: .top)
        vm.editor.itemDescription = "Cream linen popover shirt."
        vm.editor.undertone = .neutral
        vm.editor.styleTags = ["resort", "linen"]

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
final class MockWardrobeRepository: WardrobeRepository {
    var savedItems: [WardrobeItem] = []

    func fetchInventory() throws -> [WardrobeItem] {
        savedItems
    }

    func save(_ item: WardrobeItem) throws {
        savedItems.append(item)
    }

    func update(_ item: WardrobeItem) throws {}

    func delete(_ item: WardrobeItem) throws {
        savedItems.removeAll { $0.id == item.id }
    }

    func fetchFeedbackHistory() throws -> FeedbackHistory {
        FeedbackHistory()
    }

    func recordOutfitFeedback(outfitID: UUID, likedOverall: Bool) throws {}
    func recordItemFeedback(itemID: UUID, likedFit: Bool) throws {}
    func recordPairFeedback(itemAID: UUID, itemBID: UUID, likedTogether: Bool) throws {}
    func recordItemRating(itemID: UUID, fit: FitRating, comfort: Int, confidence: Int, wearAgain: Bool, versatility: Int, frequency: Int, styleIdentity: Int, qualityPerception: Int) throws {}
    func fetchItemRatings(for itemID: UUID) throws -> [ItemRating] { [] }
    func recordOutfitRating(outfitID: UUID, submission: OutfitRatingSubmission) throws {}
    func fetchOutfitFeedback(for outfitID: UUID) throws -> [OutfitFeedback] { [] }

    var savedCombinations: [SavedCombination] = []
    func fetchSavedCombinations() throws -> [SavedCombination] { savedCombinations }
    func saveCombination(_ combination: SavedCombination) throws { savedCombinations.append(combination) }
    func deleteCombination(_ combination: SavedCombination) throws {
        savedCombinations.removeAll { $0.id == combination.id }
    }

    func fetchUserProfile() throws -> UserStyleProfile? { nil }
    func saveUserProfile(_ wire: UserStyleProfileWire) throws {}
}
