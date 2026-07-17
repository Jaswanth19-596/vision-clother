//
//  EntitlementLimits.swift
//  Vision_clother
//
//  Guest-first quota plan: item-count caps per `Slot`, single source of
//  truth for both the client-side pre-check (`Features/Closet/AddItemViewModel.swift`,
//  `Features/JobQueue/JobQueueStore.swift`) and the mirrored server-side
//  backstop (`backend/firestore.rules`'s `itemCap` function — keep the two
//  numbers in sync by hand, since rules can't import Swift). Recommendation/
//  try-on monthly caps live server-side only
//  (`backend/functions/src/middleware/quota.ts`'s `TIER_LIMITS`) — they're
//  enforced by the proxy, not pre-checked client-side.
//

import Foundation

enum EntitlementLimits {
    /// `Slot.isRequired` (top/bottom/footwear) is the "core" split (higher
    /// cap); every optional slot is an "accessory" slot — reuses the same
    /// per-slot property rather than re-listing the three core slots by hand
    /// (Domain/CLAUDE.md: per-slot behavior belongs on `Slot` itself).
    static func itemCap(for slot: Slot, isAnonymous: Bool) -> Int {
        switch (slot.isRequired, isAnonymous) {
        case (true, true): return 5
        case (true, false): return 10
        case (false, true): return 2
        case (false, false): return 4
        }
    }

    /// Display-only mirror of `backend/functions/src/middleware/quota.ts`'s
    /// `TIER_LIMITS` — never used to enforce anything client-side (the proxy
    /// is the sole enforcer), only to render "X/20 this month" in
    /// `AccountSectionView`. Keep in sync with `quota.ts` by hand.
    static func recommendationLimit(isAnonymous: Bool) -> Int {
        isAnonymous ? 20 : 100
    }

    /// See `recommendationLimit(isAnonymous:)`'s doc comment.
    static func tryOnLimit(isAnonymous: Bool) -> Int {
        isAnonymous ? 0 : 10
    }
}
