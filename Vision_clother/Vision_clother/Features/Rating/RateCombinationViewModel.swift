//
//  RateCombinationViewModel.swift
//  Vision_clother
//
//  Combination Rating (Stylist Intelligence Engine Phase 1): collects the
//  dimension-based Level 1 (Overall Experience) + Level 2 (Fashion
//  Evaluation) question set for a whole saved outfit, plus a Favorite/
//  Weakest Item pick, persisting via `WardrobeRepository.recordOutfitRating`
//  keyed to a durable `SavedCombination.id`. Drives the first step of
//  `Features/Rating/RateCombinationView.swift`.
//
//  Deliberately does not conform to `RatingQuestionsViewModel`
//  (`Features/Rating/RateItemViewModel.swift`) — its question set no longer
//  matches the item-level Fit/Comfort/Confidence/Wear-again form, so it gets
//  its own dedicated view rather than forcing a shared shape.
//

import Foundation
import Observation

@Observable
@MainActor
final class RateCombinationViewModel {
    let outfitID: UUID
    /// Real (non-ghost) items resolved from the saved outfit — backs the
    /// Favorite/Weakest Item pickers.
    let items: [WardrobeItem]

    // Level 1 — Overall Experience
    var overallSatisfaction: Int = 3
    var wearAgain: WearAgainAnswer = .maybe
    var confidence: Int = 3
    var comfort: Int = 3

    // Level 2 — Fashion Evaluation
    var occasionMatch: Int = 3
    var styleMatch: Int = 3
    var colorHarmony: Int = 3
    var silhouette: Int = 3
    var weatherSuitability: Int = 3
    var practicality: Int = 3

    // Level 4/5 — Favorite / Weakest Item
    var favoriteItemID: UUID?
    var weakestItemID: UUID?

    // Level 3 — "What would you change?" checklist
    var selectedChangeReasons: Set<OutfitChangeReason> = []

    private(set) var state: RatingSaveState = .idle

    private let repository: WardrobeRepository

    init(outfitID: UUID, items: [WardrobeItem], repository: WardrobeRepository) {
        self.outfitID = outfitID
        self.items = items
        self.repository = repository
    }

    /// Selecting the same item as both Favorite and Weakest doesn't make
    /// sense — picking one clears the other.
    func selectFavorite(_ itemID: UUID?) {
        favoriteItemID = itemID
        if itemID != nil, weakestItemID == itemID {
            weakestItemID = nil
        }
    }

    func selectWeakest(_ itemID: UUID?) {
        weakestItemID = itemID
        if itemID != nil, favoriteItemID == itemID {
            favoriteItemID = nil
        }
    }

    /// "Too formal" and "Too casual" describe opposite directions on the
    /// same formality dimension — selecting one clears the other, mirroring
    /// `selectFavorite`/`selectWeakest`'s mutual-exclusion pattern.
    func toggleChangeReason(_ reason: OutfitChangeReason) {
        if selectedChangeReasons.contains(reason) {
            selectedChangeReasons.remove(reason)
            return
        }
        selectedChangeReasons.insert(reason)
        switch reason {
        case .tooFormal: selectedChangeReasons.remove(.tooCasual)
        case .tooCasual: selectedChangeReasons.remove(.tooFormal)
        default: break
        }
    }

    func submit() async {
        AppLog.info(.viewModel, "RateCombinationViewModel.submit: outfitID=\(outfitID)")
        state = .saving
        do {
            let submission = OutfitRatingSubmission(
                overallSatisfaction: overallSatisfaction,
                wearAgain: wearAgain,
                confidence: confidence,
                comfort: comfort,
                occasionMatch: occasionMatch,
                styleMatch: styleMatch,
                colorHarmony: colorHarmony,
                silhouette: silhouette,
                weatherSuitability: weatherSuitability,
                practicality: practicality,
                favoriteItemID: favoriteItemID,
                weakestItemID: weakestItemID,
                changeReasons: selectedChangeReasons
            )
            try repository.recordOutfitRating(outfitID: outfitID, submission: submission)
            state = .saved
        } catch {
            AppLog.error(.viewModel, "RateCombinationViewModel.submit: failed outfitID=\(outfitID) — \(String(describing: error))")
            state = .failed("Couldn't save that rating. Try again.")
        }
    }
}
