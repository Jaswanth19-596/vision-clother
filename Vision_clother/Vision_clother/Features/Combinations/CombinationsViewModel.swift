//
//  CombinationsViewModel.swift
//  Vision_clother
//
//  Tab 4: Combinations — every "Save this outfit?" the user has confirmed
//  from either Manual Pairing or Daily Assistant's try-on flow. See
//  Models/SavedCombination.swift for the persisted record and
//  Data/WardrobeRepository.swift for the query/save/delete methods.
//

import Foundation
import Observation

@Observable
@MainActor
final class CombinationsViewModel {
    private(set) var combinations: [SavedCombination] = []

    private let repository: WardrobeRepository

    init(repository: WardrobeRepository) {
        self.repository = repository
        loadCombinations()
    }

    func loadCombinations() {
        combinations = (try? repository.fetchSavedCombinations()) ?? []
    }

    func delete(_ combination: SavedCombination) {
        try? repository.deleteCombination(combination)
        loadCombinations()
    }

    /// Resolves `combination.topItemID`/`bottomItemID`/`footwearItemID`/
    /// `outerwearItemID` back to real `WardrobeItem`s for
    /// `RateCombinationView` — including its Favorite/Weakest Item picker,
    /// which needs every real slot in the outfit, not just top/bottom. An id
    /// can be missing (deleted since save, or `nil` for a Manual Pairing
    /// save that never selected footwear/outerwear) — those are silently
    /// skipped rather than surfaced as an error, since `SavedCombination`
    /// denormalizes labels/image precisely so it stays browsable even after
    /// a source item is gone.
    func resolveItems(for combination: SavedCombination) -> [WardrobeItem] {
        guard let inventory = try? repository.fetchInventory() else { return [] }
        let itemsByID = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0) })
        let ids = [combination.topItemID, combination.bottomItemID, combination.footwearItemID, combination.outerwearItemID].compactMap { $0 }
        return ids.compactMap { itemsByID[$0] }
    }
}
