//
//  ItemRatingScoring.swift
//  Vision_clother
//
//  Per-item, closet-UI-facing 0-100 rating score, aggregated from every
//  feedback source that references the item. Pure, no I/O — reuses
//  `PairCompatibilityScoring.itemPreference` (the same Bayesian-shrinkage
//  math the recommendation engine already trusts) rather than inventing a
//  second formula.
//

import Foundation

enum ItemRatingScoring {
    /// Returns a 0-100 rating for `itemID` aggregated from
    /// `history.itemFeedback` (already folds in `ItemRating`, `ItemFeedback`,
    /// and `OutfitFeedback.favoriteItemID`/`weakestItemID` — see
    /// `Data/WardrobeRepository.swift`'s `fetchFeedbackHistory()`) plus
    /// `history.pairFeedback` entries where this item is either side of the
    /// pair (Manual Pairing's "liked together" signal, which is keyed by
    /// item pairs rather than single items).
    ///
    /// Returns `nil` when the item has no feedback from any source —
    /// `itemPreference`'s neutral 0.5 default is a scoring-engine
    /// convenience, not a real rating, so callers should render a
    /// "Not yet rated" placeholder rather than treating `nil` as 0.
    static func score(for itemID: UUID, history: FeedbackHistory) -> Int? {
        var likes = 0.0
        var total = 0.0

        if let counts = history.itemFeedback[itemID] {
            likes += counts.likes
            total += counts.total
        }
        for (key, counts) in history.pairFeedback where key.a == itemID || key.b == itemID {
            likes += counts.likes
            total += counts.total
        }

        guard total > 0 else { return nil }

        let preference = PairCompatibilityScoring.itemPreference(
            likeCount: likes,
            dislikeCount: total - likes
        )
        return Int((preference * 100).rounded())
    }
}
