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
}
