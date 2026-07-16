//
//  RecommendationImpressionEvent.swift
//  Vision_clother
//
//  Impression/Selection Event Capture (Stylist Intelligence Engine ADR,
//  deferred item closed 2026-07-15): the recommendation pipeline already logs
//  ML drift (`[AI-Stylist-ML]`, see `Domain/MLLog.swift`) but never recorded
//  which of several shown candidate outfits the user actually acted on vs.
//  ignored. One row is inserted per candidate the moment a round of outfits
//  is shown (`DailyAssistantViewModel.sendTurn`); `selectedAt` is filled in
//  later if the user acts on that specific candidate (`startTryOn`). Nothing
//  reads this yet — same posture as `OutfitRecommendationValidator.RejectionReason`,
//  which exists purely so a future investigation has data instead of nothing.
//
//  Event-sourced, append-only — mirrors `Models/SwipeDiscovery.swift`'s
//  `SwipeEvent` shape rather than `Models/FeedbackEvent.swift`'s tables, since
//  there's no durable `SavedCombination.id` to key against yet at impression
//  time (an ignored candidate is never persisted as a `SavedCombination`).
//

import Foundation
import SwiftData

@Model
final class RecommendationImpressionEvent {
    /// Same value as the in-memory `OutfitCombination.id` at the moment it
    /// was shown — stable for the lifetime of that value in
    /// `DailyAssistantViewModel.rounds`, so `recordSelection` can look this
    /// row back up by the same id `startTryOn` receives.
    @Attribute(.unique) var id: UUID
    /// `DailyAssistantViewModel.ConversationRound.id` — groups every
    /// candidate shown together in the same round.
    var roundID: UUID
    /// Index in the sorted `outfits` array at resolution time, 0 = strongest
    /// (recommendation responses are already sorted strongest-to-weakest).
    var rank: Int
    /// Denormalized snapshot of what was shown, for audit — not required for
    /// scoring, since `id` already correlates a later selection.
    var itemIDsBySlot: [Slot: UUID]
    var shownAt: Date
    /// `nil` until the user acts on this specific candidate.
    var selectedAt: Date?

    init(
        id: UUID,
        roundID: UUID,
        rank: Int,
        itemIDsBySlot: [Slot: UUID],
        shownAt: Date = .now,
        selectedAt: Date? = nil
    ) {
        self.id = id
        self.roundID = roundID
        self.rank = rank
        self.itemIDsBySlot = itemIDsBySlot
        self.shownAt = shownAt
        self.selectedAt = selectedAt
    }
}
