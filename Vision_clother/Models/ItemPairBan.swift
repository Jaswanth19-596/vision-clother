//
//  ItemPairBan.swift
//  Vision_clother
//
//  Anti-Repetition: the permanent "never recommend these two together"
//  hard veto (as opposed to `PairFeedback.likedTogether`, which is a soft
//  signal feeding `Domain/PairCompatibilityScoring.swift`, not a block).
//  Enforced two ways: `Domain/StylistBrain.swift` tells the recommendation
//  LLM about every row here so it ideally never proposes the pair, and
//  `Domain/OutfitRecommendationValidator.swift` deterministically rejects any
//  outfit that slips through with both items present — a promise to the
//  user, not a stylistic nudge, so it can't depend on the LLM alone.
//
//  No expiry — permanent until removed via `removePairBan(id:)`. Synced
//  across devices like every other user-authored preference row
//  (`PairFeedback`, `WornLogEntry`) — see `Data/Sync/FirestoreDTOs.swift`'s
//  `ItemPairBanDTO`, `SyncEntityType.itemPairBan`.
//

import Foundation
import SwiftData

@Model
final class ItemPairBan {
    @Attribute(.unique) var id: UUID
    /// Order-independent — normalized in `init`, never at call sites, so a
    /// ban for (A, B) can never be persisted as (B, A) due to a call-site
    /// mismatch (which would make the validator's lookup silently miss it).
    /// Same convention as `PairFeedback.itemAID`/`itemBID`.
    var itemAID: UUID
    var itemBID: UUID
    var createdAt: Date

    init(itemA: UUID, itemB: UUID, id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
        if itemA.uuidString < itemB.uuidString {
            self.itemAID = itemA
            self.itemBID = itemB
        } else {
            self.itemAID = itemB
            self.itemBID = itemA
        }
    }
}
