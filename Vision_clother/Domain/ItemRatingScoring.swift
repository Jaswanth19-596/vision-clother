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
    /// An item with no feedback from any source naturally resolves to
    /// `itemPreference`'s neutral 0.5 prior (50) — a freshly uploaded item
    /// is exactly as recommendable as any other until real feedback shifts
    /// it, both for the Closet UI badge and the LLM catalog's `user_rating`.
    static func score(for itemID: UUID, history: FeedbackHistory) -> Int {
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

        let preference = PairCompatibilityScoring.itemPreference(
            likeCount: likes,
            dislikeCount: total - likes
        )
        return Int((preference * 100).rounded())
    }

    /// Batch form for scoring every item in a closet/grid against the same
    /// `history` in one pass — `score(for:history:)` above rescans all of
    /// `history.pairFeedback` per call, which is O(items × pairFeedback) when
    /// called once per rendered cell (`ClosetView`'s grid); this folds
    /// `pairFeedback` onto each referenced item id once, up front, so scoring
    /// every item afterward is an O(1) dictionary lookup each. Produces the
    /// exact same values as calling `score(for:history:)` per item.
    static func scores(for itemIDs: some Sequence<UUID>, history: FeedbackHistory) -> [UUID: Int] {
        var pairFolded: [UUID: (likes: Double, total: Double)] = [:]
        for (key, counts) in history.pairFeedback {
            for itemID in [key.a, key.b] {
                var entry = pairFolded[itemID] ?? (likes: 0, total: 0)
                entry.likes += counts.likes
                entry.total += counts.total
                pairFolded[itemID] = entry
            }
        }

        var result: [UUID: Int] = [:]
        for itemID in itemIDs {
            var likes = 0.0
            var total = 0.0
            if let counts = history.itemFeedback[itemID] {
                likes += counts.likes
                total += counts.total
            }
            if let counts = pairFolded[itemID] {
                likes += counts.likes
                total += counts.total
            }
            let preference = PairCompatibilityScoring.itemPreference(
                likeCount: likes,
                dislikeCount: total - likes
            )
            result[itemID] = Int((preference * 100).rounded())
        }
        return result
    }
}
