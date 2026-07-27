//
//  RateCombinationViewModel.swift
//  Vision_clother
//
//  Swipe + Comment Combination Feedback (2026-07-27): replaces the manual
//  Level 1/2/3 dimension-based form with a single swipe (love/like/dislike/
//  hate, reusing `SwipeGestureResolver` from
//  `Features/SwipeDiscovery/SwipeDiscoveryViewModel.swift`) plus an optional
//  free-text comment, persisting via
//  `WardrobeRepository.recordCombinationSwipeFeedback` keyed to a durable
//  `SavedCombination.id`. Drives `Features/Rating/RateCombinationView.swift`,
//  now a single screen (the per-item follow-up step that used to sequence
//  after this one has been removed from this flow).
//

import Foundation
import Observation

/// Save/submit lifecycle for the combination-feedback flow. Moved here
/// 2026-07-27 from the now-deleted `RateItemViewModel.swift` (the per-item
/// rating step this type used to be shared with was removed from
/// `RateCombinationView` entirely, not just replaced).
enum RatingSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed(String)
}

@Observable
@MainActor
final class RateCombinationViewModel {
    let outfitID: UUID
    /// Real (non-ghost) items resolved from the saved outfit — sent (as a
    /// text-only catalog projection, no images) to `chemistryService` so it
    /// can reason about the specific garments in this combination.
    let items: [WardrobeItem]

    var sentiment: SwipeSentiment?
    var comment: String = ""

    private(set) var state: RatingSaveState = .idle

    private let repository: WardrobeRepository
    private let chemistryService: CombinationChemistryInferenceService

    init(
        outfitID: UUID,
        items: [WardrobeItem],
        repository: WardrobeRepository,
        chemistryService: CombinationChemistryInferenceService
    ) {
        self.outfitID = outfitID
        self.items = items
        self.repository = repository
        self.chemistryService = chemistryService
    }

    /// Saves the sentiment + comment immediately (a fast, local-only write),
    /// then infers the richer relational chemistry in the background and
    /// updates the same row once it resolves. A slow or failed chemistry call
    /// must never block the user's swipe from registering, and must never be
    /// lost either — the initial save always lands even if inference never
    /// completes.
    func submit() async {
        guard let sentiment else { return }
        AppLog.info(.viewModel, "RateCombinationViewModel.submit: outfitID=\(outfitID) sentiment=\(sentiment.rawValue)")
        state = .saving
        let commentText = comment.isEmpty ? nil : comment

        do {
            try repository.recordCombinationSwipeFeedback(outfitID: outfitID, sentiment: sentiment, comment: commentText, chemistry: nil)
            state = .saved
        } catch {
            AppLog.error(.viewModel, "RateCombinationViewModel.submit: failed outfitID=\(outfitID) — \(String(describing: error))")
            state = .failed("Couldn't save that. Try again.")
            return
        }

        // Fire-and-forget: `submit()` has already returned control to the
        // caller by the time this resolves, so the UI never waits on it.
        let outfitID = self.outfitID
        let items = self.items
        let repository = self.repository
        let chemistryService = self.chemistryService
        Task {
            let catalogEntries = WardrobeCatalogBuilder.build(from: items).entries
            guard let chemistry = try? await chemistryService.inferChemistry(items: catalogEntries, sentiment: sentiment, comment: commentText) else {
                AppLog.error(.viewModel, "RateCombinationViewModel.submit: chemistry inference failed outfitID=\(outfitID) — sentiment/comment already saved")
                return
            }
            try? repository.recordCombinationSwipeFeedback(outfitID: outfitID, sentiment: sentiment, comment: commentText, chemistry: chemistry)
        }
    }
}
