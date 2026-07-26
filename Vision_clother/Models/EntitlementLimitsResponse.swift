//
//  EntitlementLimitsResponse.swift
//  Vision_clother
//
//  Wire type for `backend/functions/src/routes/entitlementLimits.ts`'s
//  response — the caller's tier resolved into concrete numbers, computed
//  server-side from `backend/functions/src/pricing.config.ts` (the same
//  config `middleware/creditGate.ts` enforces against). Replaces the old
//  `Domain/EntitlementLimits.swift`, which hardcoded a duplicate tier→number
//  table in the client — see `Data/UsageTracker.swift`'s doc comment and
//  docs/timeline.md for why that was removed. The route also returns the live
//  credit fields (`creditsRemaining`, `creditAllocation`, `operationCosts`,
//  `operationCaps`, `billingCycleStart`, `autoReset`) that `UsageTracker`
//  drives its credit-wallet display from. `itemCap` is keyed by
//  `Slot.rawValue`, matching `users/{uid}/meta/itemCounts`'s field naming.
//  `tier` is the server's `tier_id` vocabulary: `GUEST`/`FREE`/`PRO`.
//

import Foundation

struct EntitlementLimitsResponse: Codable, Equatable {
    var tier: String
    var recommendationLimit: Int
    var tryOnLimit: Int
    var itemCap: [String: Int]
    var creditsRemaining: Int?
    var creditAllocation: Int?
    var operationCosts: [String: Int]?
    var operationCaps: [String: Int]?
    var billingCycleStart: Double?
    var autoReset: Bool?

    enum CodingKeys: String, CodingKey {
        case tier
        case recommendationLimit
        case tryOnLimit
        case itemCap
        case creditsRemaining
        case creditAllocation
        case operationCosts
        case operationCaps
        case billingCycleStart
        case autoReset
    }

    init(
        tier: String,
        recommendationLimit: Int,
        tryOnLimit: Int,
        itemCap: [String: Int],
        creditsRemaining: Int? = nil,
        creditAllocation: Int? = nil,
        operationCosts: [String: Int]? = nil,
        operationCaps: [String: Int]? = nil,
        billingCycleStart: Double? = nil,
        autoReset: Bool? = nil
    ) {
        self.tier = tier
        self.recommendationLimit = recommendationLimit
        self.tryOnLimit = tryOnLimit
        self.itemCap = itemCap
        self.creditsRemaining = creditsRemaining
        self.creditAllocation = creditAllocation
        self.operationCosts = operationCosts
        self.operationCaps = operationCaps
        self.billingCycleStart = billingCycleStart
        self.autoReset = autoReset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tier = try container.decode(String.self, forKey: .tier)
        itemCap = try container.decodeIfPresent([String: Int].self, forKey: .itemCap) ?? [:]
        creditsRemaining = try container.decodeIfPresent(Int.self, forKey: .creditsRemaining)
        creditAllocation = try container.decodeIfPresent(Int.self, forKey: .creditAllocation)
        operationCosts = try container.decodeIfPresent([String: Int].self, forKey: .operationCosts)
        operationCaps = try container.decodeIfPresent([String: Int].self, forKey: .operationCaps)
        billingCycleStart = try container.decodeIfPresent(Double.self, forKey: .billingCycleStart)
        autoReset = try container.decodeIfPresent(Bool.self, forKey: .autoReset)

        let decodedRecLimit = try container.decodeIfPresent(Int.self, forKey: .recommendationLimit)
        let decodedTryOnLimit = try container.decodeIfPresent(Int.self, forKey: .tryOnLimit)

        if let decodedRecLimit {
            recommendationLimit = decodedRecLimit
        } else if let alloc = creditAllocation {
            // A 0 cost means recommendations are unmetered — `-1` ("unlimited"),
            // never an integer divide-by-zero (which traps). Matches the
            // backend's own sentinel in `routes/entitlementLimits.ts`.
            let recCost = operationCosts?["RECOMMENDATION"] ?? 1
            recommendationLimit = recCost > 0 ? alloc / recCost : -1
        } else {
            recommendationLimit = 20
        }

        if let decodedTryOnLimit {
            tryOnLimit = decodedTryOnLimit
        } else if let alloc = creditAllocation {
            let tryOnCost = operationCosts?["IMAGE_GEN"] ?? 10
            tryOnLimit = tryOnCost > 0 ? alloc / tryOnCost : -1
        } else {
            tryOnLimit = 0
        }
    }

    /// Used before the first successful fetch (cold launch, or every fetch
    /// so far has failed) — the most restrictive real tier's numbers, never
    /// a made-up "unlimited" placeholder. Mirrors the GUEST tier in
    /// `backend/functions/src/pricing.config.ts`'s `DEFAULT_TIER_CONFIGS`
    /// (`creditAllocation: 20`, `hardCaps.IMAGE_GEN: 0`) and
    /// `DEFAULT_OPERATION_COSTS`; if those ever drift from this literal the
    /// only consequence is a briefly-too-conservative pre-check/display until
    /// the next successful fetch corrects it — this value never enforces
    /// anything itself (see `Data/UsageTracker.swift`'s doc comment). The
    /// credit fields are populated so `UsageTracker`'s wallet-derived counts
    /// (`creditsRemaining ÷ cost`) resolve to guest headroom pre-fetch rather
    /// than a spurious zero.
    static let conservativeDefault = EntitlementLimitsResponse(
        tier: "GUEST",
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
        ],
        creditsRemaining: 20,
        creditAllocation: 20,
        operationCosts: ["RECOMMENDATION": 0, "IMAGE_GEN": 5, "UPLOAD": 0],
        operationCaps: ["IMAGE_GEN": 0],
        autoReset: false
    )
}
