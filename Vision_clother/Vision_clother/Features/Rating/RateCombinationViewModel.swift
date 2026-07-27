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
import os

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

    /// Item-Level Feedback (2026-07-27): per-garment chips the user tapped,
    /// keyed by `WardrobeItem.id`. Optional by design — the whole-look swipe
    /// alone is still a complete, submittable rating, and every garment left
    /// untouched simply writes nothing.
    var selectedChipIDs: [UUID: Set<String>] = [:]

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
            persistItemChips(outfitSentiment: sentiment)
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
            guard let result = try? await chemistryService.inferChemistry(items: catalogEntries, sentiment: sentiment, comment: commentText) else {
                AppLog.error(.viewModel, "RateCombinationViewModel.submit: chemistry inference failed outfitID=\(outfitID) — sentiment/comment already saved")
                return
            }
            try? repository.recordCombinationSwipeFeedback(outfitID: outfitID, sentiment: sentiment, comment: commentText, chemistry: result.metadata)

            // Closing the loop on free text (2026-07-27): "great outfit but the
            // shirt is loose" becomes a note on that shirt, from the same call
            // that was already reading the comment — no extra request, no extra
            // cost. Written as `.inferred` so `Features/Closet` shows it as a
            // machine reading of the comment and one tap from correction,
            // which is the mitigation for the model attributing a complaint to
            // the wrong garment.
            for note in result.itemNotes {
                try? repository.addItemNote(
                    itemID: note.itemID,
                    text: note.text,
                    severity: note.severity,
                    source: .inferred,
                    context: note.context
                )
            }
            if !result.itemNotes.isEmpty {
                MLLog.logger.notice(
                    "[AI-Stylist-ML] inferred item notes: outfit=\(outfitID, privacy: .public) count=\(result.itemNotes.count, privacy: .public)"
                )
            }
        }
    }

    /// Writes the tapped chips to their two destinations — taste to
    /// `ItemRating` (generalizes, decays), defects to `ItemNote` (attaches to
    /// this garment). Best-effort per item: one garment's write failing must
    /// not lose the others or the whole-look sentiment already committed
    /// above, which is the signal that matters most.
    private func persistItemChips(outfitSentiment: SwipeSentiment) {
        guard !selectedChipIDs.isEmpty else { return }

        for item in items {
            guard let chipIDs = selectedChipIDs[item.id], !chipIDs.isEmpty else { continue }
            let chips = ItemFeedbackChipCatalog.chips(for: item.slot).filter { chipIDs.contains($0.id) }
            guard !chips.isEmpty else { continue }

            let resolution = ItemFeedbackChipCatalog.resolve(
                chips: chips,
                outfitSentiment: outfitSentiment,
                itemPattern: item.pattern
            )

            if let rating = resolution.rating {
                try? repository.recordItemRating(
                    itemID: item.id,
                    fit: rating.fit,
                    comfort: rating.comfort,
                    colorLike: rating.colorLike,
                    patternLike: rating.patternLike,
                    formalityFit: rating.formalityFit,
                    styleIdentity: rating.styleIdentity,
                    wearAgain: rating.wearAgain
                )
            }
            for note in resolution.notes {
                try? repository.addItemNote(
                    itemID: item.id,
                    text: note.text,
                    severity: note.severity,
                    source: .chip,
                    context: note.context
                )
            }
            MLLog.logger.notice(
                "[AI-Stylist-ML] item chips: outfit=\(self.outfitID, privacy: .public) item=\(item.id, privacy: .public) slot=\(item.slot.rawValue, privacy: .public) chips=\(chips.count, privacy: .public) rating=\(resolution.rating != nil, privacy: .public) notes=\(resolution.notes.count, privacy: .public)"
            )
        }
    }
}
