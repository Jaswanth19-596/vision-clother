//
//  CreditPack.swift
//  Vision_clother
//
//  Display-only mirror of the backend's server-authoritative consumable
//  credit catalog (`backend/functions/src/iap/products.ts`'s
//  `PRODUCT_GRANTS`) — the same "keep in sync by hand" posture as
//  `EntitlementLimits` vs `quota.ts`'s `TIER_LIMITS`. The client uses this
//  to know which product IDs to fetch from StoreKit and what credit amounts
//  to show next to each price; the actual grant amount is always decided by
//  the backend from the verified transaction's productId, so drift here can
//  only ever mislabel a button, never change what a purchase grants.
//
//  Pure Domain type: no StoreKit, no I/O — unit-tested in
//  `Vision_clotherTests/CreditCatalogTests.swift`.
//

import Foundation

/// The two metered features purchased credits can top up — mirrors
/// `quota.ts`'s `QuotaFeature` / `products.ts`'s `CreditType` raw values.
enum CreditType: String, CaseIterable {
    case recommendation
    case tryOn
}

struct CreditPack: Equatable {
    /// StoreKit product identifier — must match the `.storekit` config now
    /// and the App Store Connect product record at launch.
    let productID: String
    let creditType: CreditType
    /// Credits granted, mirroring `PRODUCT_GRANTS` — display only.
    let amount: Int
}

enum CreditCatalog {
    static let all: [CreditPack] = [
        CreditPack(productID: "com.visionclother.credits.recs50", creditType: .recommendation, amount: 50),
        CreditPack(productID: "com.visionclother.credits.recs200", creditType: .recommendation, amount: 200),
        CreditPack(productID: "com.visionclother.credits.tryon10", creditType: .tryOn, amount: 10),
        CreditPack(productID: "com.visionclother.credits.tryon40", creditType: .tryOn, amount: 40),
    ]

    static var allProductIDs: [String] { all.map(\.productID) }

    static func pack(forProductID id: String) -> CreditPack? {
        all.first { $0.productID == id }
    }

    static func packs(for creditType: CreditType) -> [CreditPack] {
        all.filter { $0.creditType == creditType }
    }
}
