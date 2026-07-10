//
//  RateItemViewModel.swift
//  Vision_clother
//
//  Item Rating & Preference Learning: collects a multi-question rating for
//  one garment (fit, comfort, confidence, wear-again) and persists it via
//  `WardrobeRepository.recordItemRating`. Mirrors `AddItemViewModel`'s
//  save-state shape (Features/CLAUDE.md: explicit state enums, not bare
//  `async throws`).
//

import Foundation
import Observation

@Observable
@MainActor
final class RateItemViewModel {
    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }

    let item: WardrobeItem

    var fit: FitRating = .justRight
    var comfort: Int = 3
    var confidence: Int = 3
    var wearAgain: Bool = true

    private(set) var state: SaveState = .idle

    private let repository: WardrobeRepository

    init(item: WardrobeItem, repository: WardrobeRepository) {
        self.item = item
        self.repository = repository
    }

    func submit() async {
        state = .saving
        do {
            try repository.recordItemRating(
                itemID: item.id,
                fit: fit,
                comfort: comfort,
                confidence: confidence,
                wearAgain: wearAgain
            )
            state = .saved
        } catch {
            state = .failed("Couldn't save that rating. Try again.")
        }
    }
}
