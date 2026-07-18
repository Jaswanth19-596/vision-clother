//
//  EntitlementLimitsResponse.swift
//  Vision_clother
//
//  Wire type for `backend/functions/src/routes/entitlementLimits.ts`'s
//  response — the caller's tier resolved into concrete numbers, computed
//  server-side from `backend/functions/src/entitlementLimits.ts` (the same
//  module `middleware/quota.ts` enforces against). Replaces the old
//  `Domain/EntitlementLimits.swift`, which hardcoded a duplicate tier→number
//  table in the client — see `Data/UsageTracker.swift`'s doc comment and
//  docs/timeline.md for why that was removed. `itemCap` is keyed by
//  `Slot.rawValue`, matching `users/{uid}/meta/itemCounts`'s field naming.
//

import Foundation

struct EntitlementLimitsResponse: Codable, Equatable {
    var tier: String
    var recommendationLimit: Int
    var tryOnLimit: Int
    var itemCap: [String: Int]

    enum CodingKeys: String, CodingKey {
        case tier
        case recommendationLimit
        case tryOnLimit
        case itemCap
    }

    /// Used before the first successful fetch (cold launch, or every fetch
    /// so far has failed) — the most restrictive real tier's numbers, never
    /// a made-up "unlimited" placeholder. Mirrors the guest tier in
    /// `backend/functions/src/entitlementLimits.ts`'s `TIER_LIMITS`/
    /// `ITEM_CAP_LIMITS`; if those ever drift from this literal the only
    /// consequence is a briefly-too-conservative pre-check/display until
    /// the next successful fetch corrects it — this value never enforces
    /// anything itself (see `Data/UsageTracker.swift`'s doc comment).
    static let conservativeDefault = EntitlementLimitsResponse(
        tier: "guest",
        recommendationLimit: 20,
        tryOnLimit: 0,
        itemCap: [
            Slot.top.rawValue: 5,
            Slot.bottom.rawValue: 5,
            Slot.footwear.rawValue: 5,
            Slot.outerwear.rawValue: 2,
            Slot.headwear.rawValue: 2,
            Slot.accessory.rawValue: 2,
            Slot.bag.rawValue: 2,
        ]
    )
}
